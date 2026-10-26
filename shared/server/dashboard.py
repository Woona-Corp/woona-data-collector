"""Label Studio-authenticated recording overview and reference uploads."""

import html
import json
import os
import stat
import uuid
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path
from string import Template
from typing import Literal
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request as UrlRequest, urlopen
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from sqlalchemy import text

from server.eligibility import activity_exclusion_reasons
from server.sync_status import recording_status
from server.label_sync import active_project, file_url, paged, request_json

router = APIRouter(prefix="/dashboard", tags=["dashboard"])
KINDS = ("activity",)
VIDEO_KINDS = KINDS


def available_file(path: Path, expected_size: int) -> bool:
    try:
        info = path.stat()
        return stat.S_ISREG(info.st_mode) and info.st_size == expected_size
    except OSError:
        return False


def require_label_user(request: Request) -> None:
    cookie = request.headers.get("cookie", "")
    if not cookie:
        raise HTTPException(401, "Sign in to Label Studio first")
    url = os.environ.get("LABEL_STUDIO_URL", "http://label_studio:8080") + "/api/current-user/whoami"
    try:
        check = UrlRequest(url, headers={
            "Cookie": cookie,
            "Host": os.environ.get("LABEL_STUDIO_HOST_HEADER", "cool-trams.digital"),
        })
        with urlopen(check, timeout=5) as response:
            user = json.load(response)
    except HTTPError as error:
        raise HTTPException(401 if error.code in (401, 403) else 503, "Label Studio authentication failed") from error
    except (URLError, ValueError, TimeoutError) as error:
        raise HTTPException(503, "Label Studio authentication unavailable") from error
    if "projects.view" not in user.get("permissions", []):
        raise HTTPException(403, "Project access required")


def records_from_sources() -> tuple[list[dict], dict]:
    records = []

    # Reuse the API's existing PostgreSQL engine; one recording ID owns all artifacts and questionnaires.
    from server.app import STORAGE_ROOT, engine
    with engine.connect() as connection:
        rows = connection.execute(text("""
            SELECT r.id, r.started_at, r.ingest_status, r.capture_status,
                   r.questionnaire_validation_state, r.session_questionnaire, r.capture_error_code,
                   r.capture_error_message,r.server_verified_at,r.receipt_sha256,r.server_updated_at,
                   d.number_or_name, v.id AS profile_id, v.validation_state AS profile_state,
                   v.questionnaire AS profile_questionnaire,
                   a.artifact_type, a.file_name, a.expected_size_bytes,
                   a.id AS artifact_id,a.server_relative_path,a.storage_status,a.reference_metadata,
                   a.stored_size_bytes,a.sha256,a.verified_at,a.upload_updated_at,
                   a.error_code,a.error_message
            FROM recordings r JOIN dogs d ON d.id=r.dog_id
            JOIN dog_profile_versions v ON v.id=r.dog_profile_version_id
            LEFT JOIN artifacts a ON a.recording_id=r.id
            ORDER BY r.started_at DESC, a.id
        """)).mappings().all()
        survey_counts = {
            "dogs": connection.execute(text("SELECT count(*) FROM dogs")).scalar_one(),
            "profile_versions": connection.execute(text("SELECT count(*) FROM dog_profile_versions")).scalar_one(),
            "session_questionnaires": connection.execute(text(
                "SELECT count(*) FROM recordings WHERE questionnaire_validation_state='complete' AND session_questionnaire->>'schemaVersion'='2' AND (session_questionnaire->'plannedActivities') ?| ARRAY['Аллюр/движение','Активность']"
            )).scalar_one(),
        }
    app_records = {}
    for row in rows:
        source_id = "woona:" + str(row["id"])
        record = app_records.setdefault(source_id, {
            "source_id": source_id, "origin": "Woona", "dog": row["number_or_name"],
            "date": row["started_at"].date().isoformat(), "files": [],
            "recording_id": str(row["id"]), "session_kind": row["session_questionnaire"].get("sessionKind", "activity"),
            "ingest_status": row["ingest_status"], "capture_status": row["capture_status"],
            "capture_error_code": row["capture_error_code"],
            "capture_error_message": row["capture_error_message"],
            "_recording": row, "_artifacts": [],
            "profile": {"version_id": str(row["profile_id"]), "state": row["profile_state"],
                        "answers": row["profile_questionnaire"]},
            "session_questionnaire": {"state": row["questionnaire_validation_state"],
                                      "answers": row["session_questionnaire"]},
        })
        if row["artifact_type"]:
            record['_artifacts'].append({**row, 'id': row['artifact_id']})
            relative = row["server_relative_path"]
            path = (STORAGE_ROOT / relative).resolve() if relative else None
            record["files"].append({"name": row["file_name"], "relative": "woona/" +
                                    (relative or ""),
                                    "size": row["expected_size_bytes"],
                                    "type": row["artifact_type"],
                                    "reference_metadata": row["reference_metadata"],
                                    "storage_status": row['storage_status'],
                                    "uploaded_bytes": row['stored_size_bytes'],
                                    "error_code": row['error_code'], "error_message": row['error_message'],
                                    "last_progress_at_utc": row['upload_updated_at'].isoformat(),
                                    "available": row["storage_status"] == "available" and
                                    path is not None and STORAGE_ROOT in path.parents and
                                    available_file(path, row["expected_size_bytes"])})
    for record in app_records.values():
        record['server_status'] = recording_status(record.pop('_recording'), record.pop('_artifacts'), STORAGE_ROOT)
    records.extend(app_records.values())
    return records, {"drive_files": 0,
                     "drive_unindexed_files": 0,
                     **survey_counts}


def summarize(records: list[dict], projects: list[dict], tasks_by_kind: dict, annotation_tasks: dict,
              extra: dict) -> dict:
    task_maps = {kind: {t.get('data', {}).get('source_id'): t for t in tasks_by_kind[kind]} for kind in KINDS}
    category = {}
    for kind in KINDS:
        class_sources = defaultdict(set)
        class_segments = Counter()
        for task in tasks_by_kind[kind]:
            if not task.get("is_labeled"):
                continue
            full = annotation_tasks[(kind, task["id"])]
            for annotation in full.get("annotations", []):
                if annotation.get('was_cancelled'):
                    continue
                for result in annotation.get("result", []):
                    values = result.get("value", {})
                    labels = values.get("timelinelabels", [])
                    if result.get("from_name") != projects[0]["timeline_name"]:
                        continue
                    for label in labels:
                        class_sources[label].add(task.get('data', {}).get('source_id'))
                        class_segments[label] += 1
        project = projects[0]
        category[kind] = {"title": project["title"], "project_id": project["id"],
                          "tasks": len(tasks_by_kind[kind]),
                          "labeled": sum(bool(t.get("is_labeled")) for t in tasks_by_kind[kind]),
                          "classes": {label: {"records": len(class_sources[label]), "segments": class_segments[label]}
                                      for label in project["labels"]}}

    for record in records:
        files = [f for f in record["files"] if f["available"]]
        record["video"] = any(f.get("type") == "video" or f["name"].lower().endswith(".mp4") for f in files)
        record["ble"] = any(f.get("type") in ("packet", "packet_timeline", "raw", "imported_source")
                            or f["name"].lower().endswith((".bin", ".binlog")) for f in files)
        record["bytes"] = sum(f["size"] for f in files)
        record["reference_files"] = sum(f.get("type") in ("ecg", "heart_rate", "rr") or "annotat" in f["name"].lower() or "размет" in f["name"].lower()
                                        for f in files)
        record["tasks"] = {kind: {"id": task_maps[kind][record["source_id"]]["id"],
                                   "labeled": bool(task_maps[kind][record["source_id"]].get("is_labeled"))}
                           if record["source_id"] in task_maps[kind] else None for kind in KINDS}
        record["annotated_any"] = any(record["tasks"][kind] and record["tasks"][kind]["labeled"]
                                      for kind in VIDEO_KINDS)
        record["annotated_all"] = all(record["tasks"][kind] and record["tasks"][kind]["labeled"]
                                      for kind in VIDEO_KINDS)
        record["exclusion_reasons"] = activity_exclusion_reasons(
            record['ingest_status'], record.get('capture_status'), record.get('capture_error_code'),
            (record.get('session_questionnaire') or {}).get('answers') or {},
            {f.get('type') for f in files})
        record['eligible'] = not record['exclusion_reasons']

    source_ids = {record['source_id'] for record in records}
    eligible_ids = {record['source_id'] for record in records if record['eligible']}
    task_sources = defaultdict(list)
    for item in tasks_by_kind['activity']:
        task_sources[item.get('data', {}).get('source_id')].append(item['id'])
    service_available = extra.get('label_service', {}).get('available', True)
    reconciliation = {
        'status': 'checked' if service_available else 'unavailable',
        'eligible_missing_tasks': sorted(eligible_ids - set(task_sources)) if service_available else [],
        'unknown_task_sources': sorted(str(key) for key in set(task_sources) - source_ids),
        'ineligible_task_sources': sorted(str(key) for key in (set(task_sources) & source_ids) - eligible_ids),
        'duplicate_task_sources': {str(key): value for key, value in task_sources.items() if len(value) > 1},
        'stalled_uploads': sum(bool(record.get('server_status', {}).get('transfer', {}).get('stalled')) for record in records),
        'integrity_problems': sum(record.get('server_status', {}).get('transfer', {}).get('status') == 'integrity_problem' for record in records),
    }
    records.sort(key=lambda r: (r["date"], r["source_id"]), reverse=True)
    video_ble = [r for r in records if r["video"] and r["ble"] and r.get("session_kind") != "heart"]
    return {"updated_at": datetime.now(ZoneInfo("Europe/Moscow")).isoformat(timespec="seconds"),
            "totals": {"groups": len(records), "video_ble": len(video_ble),
                       "annotated_any": sum(r["annotated_any"] for r in video_ble),
                       "annotated_all": sum(r["annotated_all"] for r in video_ble),
                        "source_reviewed": category["activity"]["labeled"],
                       "files": sum(len(r["files"]) for r in records),
                       "available_files": sum(f["available"] for r in records for f in r["files"]),
                       "bytes": sum(r["bytes"] for r in records),
                        "pending_import": sum(r["eligible"] and not r["tasks"]["activity"] for r in records) if service_available else None,
                       **extra},
            "funnel": {
                "attempts": len(records),
                "capture_ok": sum(r.get('capture_status') == 'completed' and not r.get('capture_error_code') for r in records),
                "uploaded": sum(r['ingest_status'] == 'complete' for r in records),
                "eligible": sum(r['eligible'] for r in records),
                "in_label_studio": sum(bool(r['tasks']['activity']) for r in records) if service_available else None,
                "with_annotations": sum(bool(r['annotated_any']) for r in records) if service_available else None,
            },
            "ingest": dict(Counter(r["ingest_status"] for r in records)),
            "reconciliation": reconciliation,
            "label_service": extra.get('label_service', {'available': True}),
            "categories": category, "records": records}


def load_dashboard() -> dict:
    records, extra = records_from_sources()
    try:
        projects = [active_project()]
        tasks = {kind: paged(f'/api/tasks?project={projects[0]["id"]}') for kind in KINDS}
        labeled = {(kind, t["id"]): request_json("GET", f'/api/tasks/{t["id"]}')
                   for kind in KINDS for t in tasks[kind] if t.get("is_labeled")}
        extra['label_service'] = {'available': True}
    except (HTTPError, URLError, TimeoutError, ValueError, RuntimeError, KeyError) as error:
        # A labeling outage must not hide transfer/capture diagnostics or imply zero tasks.
        projects = [{'id': int(os.environ.get('LABEL_PROJECT_ID', '21')),
                     'title': 'Label Studio', 'timeline_name': '', 'labels': []}]
        tasks, labeled = {kind: [] for kind in KINDS}, {}
        extra['label_service'] = {'available': False, 'code': 'label_studio_unavailable',
            'message': 'Статусы задач Label Studio сейчас недоступны. Данные и статусы файлов показаны; отсутствие задач не подтверждено.',
            'retryable': True, 'errorType': type(error).__name__}
    return summarize(records, projects, tasks, labeled, extra)


def render(data: dict, query: str, status: str = "all", ble: str = "all", page: int = 1) -> str:
    escape = html.escape
    totals = data["totals"]
    app_records = sum(record["origin"] == "Woona" for record in data["records"])
    ratio = round(100 * totals["session_questionnaires"] / app_records) if app_records else 0
    cards = [
        ("Группы файлов", totals["groups"], "всего групп"),
        ("Видео + BLE", totals["video_ble"], "полные пары"),
        ("Размечено", totals["annotated_any"], "видеозаписей"),
        ("Готово к разметке", totals["video_ble"] - totals["annotated_all"], f'из {totals["video_ble"]}'),
    ]
    funnel = data['funnel']
    cards = [("Попытки записи", funnel['attempts'], "серверные записи; локальные очереди не учтены"),
             ("Записано без ошибок", funnel['capture_ok'], "успешный capture"),
             ("Передано полностью", funnel['uploaded'], "включая ошибочные capture"),
             ("Допущено к разметке", funnel['eligible'], "полный комплект и успешный capture"),
             ("В Label Studio", funnel['in_label_studio'] if funnel['in_label_studio'] is not None else 'Недоступно', "созданные задачи"),
             ("Есть разметка", funnel['with_annotations'] if funnel['with_annotations'] is not None else 'Недоступно', "не означает покрытие всех кадров")]
    card_html = "".join(f'<div class="metric"><span>{name}</span><div><strong>{value}</strong><small>{hint}</small></div></div>'
                        for name, value, hint in cards)
    card_html += (f'<div class="metric"><span>Анкеты собак / сессий</span><div><strong>{totals["profile_versions"]}'
                  f' <em>/ {totals["session_questionnaires"]}</em></strong><small>сессий: {totals["session_questionnaires"]}/{app_records}</small></div>'
                  f'<div class="meter"><i style="width:{ratio}%"></i></div></div>')

    reconciliation = data.get('reconciliation', {})
    if data.get('label_service', {}).get('available', True):
        diagnostics = ('Сверка Label Studio: ' +
            f"ожидают импорта {len(reconciliation.get('eligible_missing_tasks', []))}; " +
            f"дубли источников {len(reconciliation.get('duplicate_task_sources', {}))}; " +
            f"задачи без записи {len(reconciliation.get('unknown_task_sources', []))}; " +
            f"исключённые записи в LS {len(reconciliation.get('ineligible_task_sources', []))}. ")
    else:
        diagnostics = data['label_service']['message'] + ' '
    diagnostics += (f"Загрузки без прогресса ≥15 минут: {reconciliation.get('stalled_uploads', 0)}; " +
                    f"проблемы целостности: {reconciliation.get('integrity_problems', 0)}. " +
                    'Проверка не видит записи, которые ещё не отправлены с телефонов.')
    card_html += '<div class="metric" role="status">' + escape(diagnostics) + '</div>'

    colors = {"source": ("#0052cc", "#de350b", "#ffab00"),
              "activity": ("#4c9aff", "#6554c0", "#36b37e", "#ff8b00", "#ff5630"),
              "gait": ("#00875a", "#00b8d9", "#ffab00", "#bf2600"),
              "lameness": ("#5243aa", "#0052cc", "#ff8b00", "#ff5630", "#de350b")}
    labels = {"source": "Валидация", "activity": "Видеоразметка", "gait": "Кинематика", "lameness": "Диагностика"}
    category_rows = []
    for kind in KINDS:
        category = data["categories"][kind]
        percent = round(100 * category["labeled"] / category["tasks"]) if category["tasks"] else 0
        unit = "выборов" if kind == "source" else "интервалов"
        chips = "".join(f'<span class="class-chip"><i style="background:{color}"></i>{escape(name)}: '
                        f'<b>{stats["records"]} записей / {stats["segments"]} {unit}</b></span>'
                        for (name, stats), color in zip(category["classes"].items(), colors[kind] * 10))
        progress_label = (f'{category["labeled"]} / {category["tasks"]} <small>({percent}%)</small>'
                          if data.get('label_service', {}).get('available', True) else 'Статус недоступен')
        category_rows.append(
            f'<div class="project-row"><div class="project-main"><div class="project-title">'
            f'<a href="/projects/{category["project_id"]}/data">{escape(category["title"])}</a>'
            f'<span class="type-tag">{labels[kind]}</span></div><div class="chips">{chips}</div></div>'
            f'<div class="project-progress"><span>{progress_label}</span><div class="meter"><i style="width:{percent}%"></i></div></div></div>')

    def matches(record: dict) -> bool:
        if query.casefold() not in (record["source_id"] + " " + record["dog"] + " " + record["origin"]).casefold():
            return False
        if ble != "all" and record["ble"] != (ble == "present"):
            return False
        if status == "ready" and not (record['eligible'] and record["video"] and record["ble"] and
                                      all(record["tasks"][kind] for kind in VIDEO_KINDS) and
                                      not record["annotated_any"]):
            return False
        if status == "in_progress" and not (record["annotated_any"] and not record["annotated_all"]):
            return False
        if status == "complete" and not record["annotated_all"]:
            return False
        if status == "incomplete" and record["video"] and record["ble"]:
            return False
        return True

    filtered = [record for record in data["records"] if matches(record)]
    per_page = 25
    page_count = max(1, (len(filtered) + per_page - 1) // per_page)
    page = min(page, page_count)
    visible = filtered[(page - 1) * per_page:page * per_page]

    def page_url(number: int) -> str:
        return "/dashboard?" + urlencode({"q": query, "status": status, "ble": ble, "page": number}) + "#data-manager"

    rows = []
    for record in visible:
        source_id = record["source_id"]
        short_id = source_id.split(":", 1)[1][:12] + "…"
        files = "".join(f'<li><a href="{escape(file_url(item["relative"]), quote=True)}">'
                        f'{escape(item["name"])}</a> · {item["size"]:,} B · проверен</li>'
                        if item["available"] else f'<li>{escape(item["name"])} · '
                        f'{escape(item.get("storage_status", "unavailable"))} · '
                        f'{item.get("uploaded_bytes", 0):,} / {item["size"]:,} B'
                        f'{" · " + escape(item["error_code"]) if item.get("error_code") else ""}'
                        f'{" · " + escape(item["error_message"]) if item.get("error_message") else ""}</li>'
                        for item in record["files"])
        file_details = f'<details><summary>{len(record["files"])} файлов · {record["bytes"] / 1048576:.1f} MiB</summary>' \
                       f'<ul>{files}</ul></details>'
        if record["profile"]:
            answers = escape(json.dumps({"dog": record["profile"]["answers"],
                                         "session": record["session_questionnaire"]["answers"]},
                                        ensure_ascii=False, indent=2))
            questionnaire = (f'<span class="pill ok">● Анкеты доступны</span><details><summary>Посмотреть</summary>'
                             f'<div class="sub">Версия {escape(record["profile"]["version_id"])}</div>'
                             f'<pre>{answers}</pre></details>')
        else:
            questionnaire = '<span class="pill neutral">Нет анкеты Woona</span>'
        dots = "".join(f'<span class="progress-dot {"done" if record["tasks"][kind] and record["tasks"][kind]["labeled"] else ""}" '
                       f'title="{escape(data["categories"][kind]["title"], quote=True)}" '
                       f'aria-label="{escape(data["categories"][kind]["title"], quote=True)}: '
                       f'{"готово" if record["tasks"][kind] and record["tasks"][kind]["labeled"] else "не размечено"}"></span>'
                       for kind in KINDS)
        done = sum(bool(record["tasks"][kind] and record["tasks"][kind]["labeled"]) for kind in KINDS)
        next_kind = next((kind for kind in KINDS if record["tasks"][kind] and not record["tasks"][kind]["labeled"]),
                         next((kind for kind in KINDS if record["tasks"][kind]), None))
        action = (f'<a class="action" href="/projects/{data["categories"][next_kind]["project_id"]}/data?task='
                  f'{record["tasks"][next_kind]["id"]}">{"Открыть" if done == len(KINDS) else "Разметить"} ↗</a>') if next_kind else '—'
        state = ("Ожидает импорта" if not record["tasks"]["activity"] else
                 "Нет пары видео + BLE" if not (record["video"] and record["ble"]) else
                 "Видео размечено" if record["annotated_all"] else "В процессе" if record["annotated_any"] else
                 "Ожидает разметки")
        if not data.get('label_service', {}).get('available', True):
            state = 'Статус Label Studio недоступен; наличие задачи не проверено'
        if record.get('exclusion_reasons'):
            state = '; '.join(record['exclusion_reasons'])
        if record.get("session_kind") == "heart":
            state = "Сердцебиение · хранение без разметки"
            dots = ""
        if record.get("recording_id"):
            action += f'<br><a class="action" href="/dashboard/recordings/{record["recording_id"]}/references">Добавить ЭКГ / ЧСС</a>'
        transfer = record.get('server_status', {}).get('transfer')
        transfer_html = escape(record['ingest_status'])
        if transfer:
            state_names = {'metadata_pending': 'Ожидает метаданных', 'uploading': 'Загрузка не завершена',
                'awaiting_verification': 'Байты переданы; ожидается проверка', 'verified': 'Файлы и receipt подтверждены',
                'integrity_problem': 'Проблема целостности — сохраните локальные оригиналы', 'rejected': 'Загрузка отклонена'}
            transfer_html = (escape(state_names[transfer['status']]) + '<br>' +
                f"{transfer['uploadedBytes']:,} / {transfer['totalBytes']:,} B · проверено файлов: " +
                f"{transfer['verifiedFiles']}/{transfer['totalFiles']}" +
                (f"<br>Нет прогресса с {escape(transfer['lastProgressAtUtc'] or 'неизвестного времени')}" if transfer['stalled'] else ''))
        capture_message = record.get('capture_error_message')
        if capture_message:
            transfer_html += '<details><summary>Ошибка записи</summary><pre>' + escape(capture_message) + '</pre></details>'
        rows.append(f'<tr><td><code class="source-id" title="{escape(source_id, quote=True)}">{escape(short_id)}</code>'
                    f'<div class="sub">{escape(record["dog"])} · {escape(record["date"])} · {escape(record["origin"])}</div></td>'
                    f'<td><span class="pill {"ok" if record["video"] else "neutral"}">Видео: {"есть" if record["video"] else "нет"}</span> '
                    f'<span class="pill {"ok" if record["ble"] else "neutral"}">BLE: {"есть" if record["ble"] else "нет"}</span></td>'
                    f'<td>{file_details}<div class="sub">{transfer_html} · референсы: {record["reference_files"]}</div></td>'
                    f'<td><div class="dots">{dots}</div><span class="state">{escape(state)}'
                    f'{" (" + str(done) + "/" + str(len(KINDS)) + ")" if data.get("label_service", {}).get("available", True) else ""}</span></td>'
                    f'<td>{questionnaire}</td><td>{action}</td></tr>')

    selected = lambda value, current: ' selected' if value == current else ''
    status_options = "".join(f'<option value="{value}"{selected(value, status)}>{name}</option>' for value, name in (
        ("all", "Все статусы"), ("ready", "Готово к разметке"), ("in_progress", "В процессе"),
        ("complete", "Размечено"), ("incomplete", "Без пары видео + BLE")))
    ble_options = "".join(f'<option value="{value}"{selected(value, ble)}>{name}</option>' for value, name in (
        ("all", "BLE: все"), ("present", "BLE: есть"), ("absent", "BLE: нет")))
    page_links = "".join(f'<a class="page-link {"active" if number == page else ""}" href="{page_url(number)}">{number}</a>'
                         for number in range(max(1, page - 2), min(page_count, page + 2) + 1))
    pagination = (f'<span>Показано {((page - 1) * per_page + 1) if filtered else 0}–'
                  f'{min(page * per_page, len(filtered))} из {len(filtered)}</span><nav aria-label="Страницы">'
                  f'<a class="page-link" href="{page_url(max(1, page - 1))}">‹</a>{page_links}'
                  f'<a class="page-link" href="{page_url(min(page_count, page + 1))}">›</a></nav>')
    return Template('''<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="60"><title>Woona / Данные и разметка · Label Studio</title>
<style>
:root{font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#202124;background:#fff;font-size:13px}
*{box-sizing:border-box}body{margin:0}a{color:inherit;text-decoration:none}a:hover{color:#ff6442}button,input,select{font:inherit}button,select{cursor:pointer}
:focus-visible{outline:2px solid #ff6442;outline-offset:2px}.wrap{max-width:1600px;margin:auto;padding:0 24px}.mono,code,.metric strong,.project-progress,.pipeline,.pagination{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.topbar{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid #e5e7eb}.topbar-inner{min-height:52px;display:flex;align-items:center;gap:25px}.brand{display:flex;align-items:center;gap:10px;font-weight:600;white-space:nowrap}.mark{width:27px;height:27px;border-radius:5px;background:#ff6442;display:flex;align-items:center;justify-content:center;gap:2px}.mark i{width:5px;height:13px;background:white;border-radius:1px}.mark i+ i{height:8px;align-self:flex-end;margin-bottom:7px}.slash{color:#c3c7cc}.tabs{align-self:stretch;display:flex;gap:18px;align-items:stretch}.tabs a{display:flex;align-items:center;color:#6b7280;font-weight:600;white-space:nowrap}.tabs a.active{color:#202124;border-bottom:2px solid #ff6442}.top-spacer{flex:1}.sync{font:11px ui-monospace,monospace;color:#6b7280;white-space:nowrap}.sync i,.footer i{display:inline-block;width:7px;height:7px;background:#10a778;border-radius:50%;margin-right:6px}.top-action{white-space:nowrap;padding:7px 11px;border:1px solid #d5d9dd;border-radius:5px;font-weight:600}.top-action.primary{background:#ff6442;color:white;border-color:#ff6442}.top-action.primary:hover,.action:hover{background:#e04f30;color:white}
.summary{background:#fafafa;border-bottom:1px solid #e5e7eb}.metrics{display:grid;grid-template-columns:repeat(5,1fr);padding:18px 0}.metric{min-width:0;padding:4px 20px;border-left:1px solid #e5e7eb}.metric:first-child{padding-left:0;border-left:0}.metric>span{font-size:11px;text-transform:uppercase;letter-spacing:.04em;color:#6b7280;font-weight:700}.metric>div:not(.meter){display:flex;align-items:baseline;gap:10px;margin-top:9px}.metric strong{font-size:27px;line-height:1}.metric strong em{font-size:16px;color:#9ca3af;font-style:normal}.metric small{font-size:11px;color:#6b7280}.meter{height:5px;background:#eee;border-radius:3px;overflow:hidden}.meter i{display:block;height:100%;background:#ff6442}.metric>.meter{margin-top:11px}.metric>.meter i{background:#242424}
.notice{border-bottom:1px solid #e5e7eb}.notice-inner{display:flex;align-items:center;justify-content:space-between;gap:20px;padding-top:13px;padding-bottom:13px}.notice p{margin:0;color:#555e67;line-height:1.45}.notice b{color:#202124}.info{display:inline-grid;place-items:center;width:18px;height:18px;margin-right:9px;border:1px solid #d5d9dd;border-radius:4px;font-weight:700;color:#6b7280}.pipeline{display:flex;flex-wrap:wrap;gap:7px;background:#fafafa;border:1px solid #e5e7eb;border-radius:5px;padding:8px;color:#6b7280;font-size:11px;white-space:nowrap}.pipeline strong{color:#202124}
main{padding-top:24px!important;padding-bottom:28px!important}.panel{border:1px solid #e5e7eb;border-radius:6px;overflow:hidden;background:#fff;margin-bottom:24px}.panel-head{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:12px 16px;background:#fafafa;border-bottom:1px solid #e5e7eb}.panel-head h2{font-size:12px;letter-spacing:.06em;text-transform:uppercase;margin:0}.panel-head span{color:#8b9299;font-size:11px}.project-row{display:flex;align-items:center;justify-content:space-between;gap:24px;padding:13px 16px;border-bottom:1px solid #f0f1f2}.project-row:last-child{border-bottom:0}.project-row:hover,tr:hover{background:#fcfcfc}.project-main{min-width:0}.project-title{display:flex;align-items:center;gap:10px;font-weight:600}.type-tag,.class-chip{border:1px solid #e5e7eb;border-radius:4px;background:#fafafa}.type-tag{font-size:10px;text-transform:uppercase;color:#687078;font-weight:500;padding:2px 6px}.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:9px}.class-chip{display:inline-flex;align-items:center;gap:6px;padding:4px 7px;font-size:11px}.class-chip i{width:8px;height:8px;flex:none;border-radius:2px}.class-chip b{font-weight:400;color:#6b7280}.project-progress{width:170px;flex:none;text-align:right;font-size:12px}.project-progress small{color:#9ca3af}.project-progress .meter{margin-top:8px}
.toolbar{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:12px 14px;background:#fafafa;border-bottom:1px solid #e5e7eb}.toolbar form{display:flex;flex-wrap:wrap;align-items:center;gap:8px}.toolbar input,.toolbar select{height:32px;padding:5px 9px;border:1px solid #d5d9dd;border-radius:5px;background:white;color:#202124}.toolbar input{width:270px}.toolbar button{height:32px;padding:0 15px;border:0;border-radius:5px;background:#262626;color:white;font-weight:600}.toolbar-info{color:#6b7280;font:11px ui-monospace,monospace}.table-scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;min-width:1030px}th,td{text-align:left;padding:10px 13px;vertical-align:top;border-bottom:1px solid #ebedef}th{background:#f8f9fa;color:#667078;text-transform:uppercase;letter-spacing:.04em;font-size:11px;font-weight:600;white-space:nowrap}td{font-size:12px}tr:last-child td{border-bottom:0}.sub{color:#80878e;font-size:11px;margin-top:5px}.source-id{font-weight:700;white-space:nowrap}.pill{display:inline-block;border:1px solid;border-radius:5px;padding:3px 7px;font-size:11px;white-space:nowrap;margin:0 4px 4px 0}.pill.ok{background:#ecfdf5;color:#047857;border-color:#a7f3d0}.pill.neutral{background:#f8f9fa;color:#6b7280;border-color:#e5e7eb}.dots{display:flex;gap:6px;margin:3px 0 7px}.progress-dot{width:13px;height:13px;border:1px solid #d1d5db;background:#e5e7eb;border-radius:50%}.progress-dot.done{background:#10a778;border-color:#0f996d}.state{font-size:11px;color:#6b7280}.action{display:inline-block;padding:6px 9px;border-radius:5px;background:#ff6442;color:white;font-weight:600;white-space:nowrap}.action:hover{color:white}details{max-width:290px}summary{cursor:pointer;color:#374151}details ul{padding-left:16px;max-height:240px;overflow:auto;overflow-wrap:anywhere}details li{margin:5px 0}pre{white-space:pre-wrap;word-break:break-word;max-height:250px;overflow:auto;font-size:11px}.pagination{display:flex;align-items:center;justify-content:space-between;padding:12px 14px;color:#6b7280;font-size:11px;border-top:1px solid #e5e7eb}.pagination nav{display:flex;gap:4px}.page-link{display:inline-grid;place-items:center;min-width:28px;height:28px;border:1px solid #e5e7eb;border-radius:5px}.page-link.active{background:#ff6442;color:white;border-color:#ff6442}.empty{padding:24px;text-align:center;color:#6b7280}.footer{border-top:1px solid #e5e7eb;color:#6b7280;padding:17px 0;font:11px ui-monospace,monospace}
@media(max-width:1100px){.metrics{grid-template-columns:repeat(3,1fr);gap:12px 0}.metric:nth-child(4){border-left:0;padding-left:0}.sync{display:none}.notice-inner{align-items:flex-start;flex-direction:column}.topbar-inner{gap:15px}}@media(max-width:700px){.wrap{padding-left:14px;padding-right:14px}.topbar-inner{flex-wrap:wrap;padding-top:8px;padding-bottom:8px}.tabs{order:3;width:100%;height:34px;gap:16px}.metrics{grid-template-columns:repeat(2,1fr)}.metric:nth-child(odd){border-left:0;padding-left:0}.metric:nth-child(4){border-left:1px solid #e5e7eb;padding-left:20px}.project-row{align-items:stretch;flex-direction:column;gap:12px}.project-progress{width:100%;text-align:left}.toolbar input{width:min(270px,80vw)}.pipeline{white-space:normal}}
</style></head><body>
<header class="topbar"><div class="wrap topbar-inner"><a class="brand" href="/projects/"><span class="mark" aria-hidden="true"><i></i><i></i></span><span>Woona</span><span class="slash">/</span><span>данные и разметка</span></a><nav class="tabs" aria-label="Разделы"><a class="active" href="#data-manager">Данные (Data Manager)</a><a href="#annotation-projects">Проекты разметки</a></nav><div class="top-spacer"></div><span class="sync"><i></i>Обновлено: $updated · каждые 60 с</span><a class="top-action" href="/dashboard/data">JSON</a><a class="top-action primary" href="/projects/">Label Studio ↗</a></div></header>
<section class="summary"><div class="wrap metrics">$cards</div></section>
<section class="notice"><div class="wrap notice-inner"><p><span class="info">i</span><b>Активность и Аллюр — одна дорожка разметки.</b> Здесь показаны записи этого протокола из PostgreSQL. Прогресс считается по отправленным аннотациям существующего проекта; CSV-референсы не засчитываются.</p><div class="pipeline"><span>Файлов: <strong>$available / $files</strong></span><span>·</span><span>Объём: <strong>$gib GiB</strong></span><span>·</span><span>Ожидают импорта: <strong>$pending</strong></span></div></div></section>
<main class="wrap"><section class="panel" id="annotation-projects"><div class="panel-head"><h2>Категории разметки</h2><span>Размечено / задач</span></div>$projects</section>
<section class="panel" id="data-manager"><div class="toolbar"><form method="get" action="/dashboard"><input type="search" name="q" value="$query" maxlength="100" placeholder="Поиск по ID, собаке или источнику" aria-label="Поиск по ID, собаке или источнику"><select name="status" aria-label="Статус разметки">$status_options</select><select name="ble" aria-label="Наличие BLE">$ble_options</select><button type="submit">Найти</button></form><span class="toolbar-info">Найдено $found из $total групп</span></div>
<div class="table-scroll"><table><thead><tr><th>ID / группа</th><th>Видео / BLE</th><th>Файлы и хранилище</th><th>Прогресс разметки</th><th>Анкеты</th><th>Действие</th></tr></thead><tbody>$rows</tbody></table></div><div class="pagination">$pagination</div></section></main>
<footer class="footer"><div class="wrap"><i></i>Woona ML pipeline · актуальные данные PostgreSQL, файлов и Label Studio</div></footer></body></html>''').substitute(
        updated=escape(data["updated_at"]), cards=card_html, available=totals["available_files"],
        files=totals["files"], gib=f'{totals["bytes"] / 1073741824:.2f}',
        unindexed=totals["drive_unindexed_files"], pending=totals["pending_import"],
        projects="".join(category_rows), query=escape(query, quote=True),
        status_options=status_options, ble_options=ble_options, found=len(filtered), total=totals["groups"],
        rows="".join(rows) if rows else '<tr><td class="empty" colspan="6">По выбранным фильтрам записей нет</td></tr>',
        pagination=pagination)


@router.get("", response_class=HTMLResponse, dependencies=[Depends(require_label_user)])
def dashboard(q: str = Query("", max_length=100),
              status: Literal["all", "ready", "in_progress", "complete", "incomplete"] = "all",
              ble: Literal["all", "present", "absent"] = "all", page: int = Query(1, ge=1)):
    return HTMLResponse(render(load_dashboard(), q, status, ble, page), headers={"Cache-Control": "no-store"})


@router.get("/data", dependencies=[Depends(require_label_user)])
def dashboard_data():
    return JSONResponse(load_dashboard(), headers={"Cache-Control": "no-store"})


def require_upload_origin(request: Request) -> None:
    # Custom header + same-origin check prevent writes via another site's forms.
    origin = urlsplit(request.headers.get("origin", ""))
    if request.headers.get("x-woona-upload") != "1" or origin.netloc != request.headers.get("host") or origin.scheme not in ("http", "https"):
        raise HTTPException(403, "Upload requires a same-origin request")


def reference_owner(artifact_id: uuid.UUID) -> uuid.UUID:
    from server.app import artifact_row, engine, REFERENCE_TYPES
    with engine.connect() as connection:
        row = artifact_row(connection, artifact_id)
    if row is None or row["artifact_type"] not in REFERENCE_TYPES:
        raise HTTPException(404, "Reference artifact not found")
    return row["capture_device_id"]


@router.get("/recordings/{recording_id}/references", response_class=HTMLResponse, dependencies=[Depends(require_label_user)])
def reference_form(recording_id: uuid.UUID):
    from server.app import engine
    with engine.connect() as connection:
        recording = connection.execute(text("SELECT r.session_label,d.number_or_name FROM recordings r JOIN dogs d ON d.id=r.dog_id WHERE r.id=:id"), {"id": recording_id}).mappings().first()
    if recording is None:
        raise HTTPException(404, "Recording not found")
    heading = html.escape(recording["number_or_name"] + " → " + recording["session_label"])
    page = """<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Добавить контрольную запись</title><style>body{font:16px system-ui;max-width:720px;margin:40px auto;padding:16px}label{display:block;margin:16px 0}input,select,textarea,button{display:block;max-width:100%;padding:10px;font:inherit}output{display:block;white-space:pre-wrap}</style>
<a href="/dashboard">← Все сессии</a><h1>Добавить контрольную запись</h1><p>HEADING</p>
<p>Исходный файл сохраняется без преобразований в этой сессии. Временная привязка нужна для последующего сопоставления с ошейником. ЧСС без интервалов подходит только для сравнения среднего темпа.</p>
<form id="form"><label>Тип данных *<select name="type" required><option value="">Выберите тип</option><option value="ecg">ЭКГ</option><option value="heart_rate">ЧСС</option><option value="rr">Интервалы между ударами (Polar и др.)</option></select></label>
<label>Исходный файл *<input name="file" type="file" required></label>
<label>Устройство / источник *<input name="source" required maxlength="200"></label>
<label>Начало контрольной записи UTC *<input name="start" placeholder="2026-10-05T12:00:00Z" required></label>
<label>Окончание контрольной записи UTC *<input name="end" placeholder="2026-10-05T12:05:00Z" required></label>
<label>Поправка к UTC таргета, мс (добавляется к его меткам, если известна)<input name="offset" type="number" step="any"></label>
<label>Временная привязка / примечания<textarea name="notes" maxlength="2000"></textarea></label>
<button>Добавить файл</button><output id="status" aria-live="polite"></output></form>
<script>
const form = document.querySelector('#form'), status = document.querySelector('#status');
async function send(method, path, body, extra = {}) {
 const r = await fetch(path, {method, body, headers: {'X-Woona-Upload':'1', ...extra}});
 if (!r.ok) throw Error(await r.text());
 return r;
}
form.addEventListener('submit', async event => {
 event.preventDefault(); const button = form.querySelector('button'); button.disabled = true;
 try {
  const values = new FormData(form), file = values.get('file');
  // ponytail: Web Crypto hashes a whole file; use mobile streaming sync for files over 256 MiB.
  if (file.size > 256 * 1024 * 1024) throw Error('Для файлов больше 256 МиБ используйте загрузку из приложения.');
  if (!file.size) throw Error('Файл пуст.');
  status.textContent = 'Проверка файла…';
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', await file.arrayBuffer()))].map(x => x.toString(16).padStart(2,'0')).join('');
  const identity = `${file.name}:${hash}:${values.get('type')}:${values.get('source')}:${values.get('start')}:${values.get('end')}:${values.get('offset')}:${values.get('notes')}`;
  if (form.uploadIdentity !== identity) { form.uploadId = crypto.randomUUID(); form.uploadIdentity = identity; }
  const id = form.uploadId;
  const artifact = {id, type:values.get('type'), fileName:`reference-${id}-${file.name.slice(-180)}`, mimeType:'application/octet-stream', sizeBytes:file.size, sha256:hash, clientCreatedAtUtc:new Date().toISOString(),
    referenceMetadata:{source:values.get('source'), startedAtUtc:values.get('start'), endedAtUtc:values.get('end'), offsetFromRecordingMs:values.get('offset') === '' ? null : Number(values.get('offset')), notes:values.get('notes') || null}};
  await send('POST', '/dashboard/recordings/RECORDING/references', JSON.stringify(artifact), {'Content-Type':'application/json'});
  const path = `/dashboard/artifacts/${id}/content`, head = await send('HEAD', path);
  let offset = Number(head.headers.get('Upload-Offset'));
  while (offset < file.size) {
   const chunk = file.slice(offset, offset + 8 * 1024 * 1024);
   const result = await send('PATCH', path, chunk, {'Upload-Offset':String(offset), 'Content-Type':'application/offset+octet-stream'});
   offset = Number(result.headers.get('Upload-Offset'));
   status.textContent = `Загружено ${Math.round(100 * offset / file.size)}%`;
  }
  await send('POST', `/dashboard/artifacts/${id}/complete`, '{}', {'Content-Type':'application/json'});
  status.textContent = 'Файл сохранён. Можно вернуться к сессии или добавить следующий.';
  form.reset(); form.uploadIdentity = null;
 } catch (error) { status.textContent = `Не удалось загрузить: ${error.message}. Повторите отправку для продолжения.`; }
 finally { button.disabled = false; }
});
</script></html>"""
    return HTMLResponse(page.replace("HEADING", heading).replace("RECORDING", str(recording_id)), headers={"Cache-Control": "no-store"})


@router.post("/recordings/{recording_id}/references", dependencies=[Depends(require_label_user), Depends(require_upload_origin)])
async def dashboard_add_reference(recording_id: uuid.UUID, request: Request):
    from pydantic import ValidationError
    from server.app import ArtifactPayload, MAX_JSON_BYTES, add_reference, engine
    body = await request.body()
    if len(body) > MAX_JSON_BYTES:
        raise HTTPException(413, "Metadata too large")
    try:
        artifact = ArtifactPayload.model_validate_json(body)
    except ValidationError as error:
        raise HTTPException(422, "Invalid reference metadata") from error
    with engine.connect() as connection:
        owner = connection.execute(text("SELECT capture_device_id FROM recordings WHERE id=:id"), {"id": recording_id}).scalar_one_or_none()
    if owner is None:
        raise HTTPException(404, "Recording not found")
    return add_reference(recording_id, artifact, owner)


@router.head("/artifacts/{artifact_id}/content", dependencies=[Depends(require_label_user)])
def dashboard_reference_offset(artifact_id: uuid.UUID):
    from server.app import head_artifact
    return head_artifact(artifact_id, reference_owner(artifact_id))


@router.patch("/artifacts/{artifact_id}/content", status_code=204, dependencies=[Depends(require_label_user), Depends(require_upload_origin)])
async def dashboard_reference_chunk(artifact_id: uuid.UUID, request: Request):
    from server.app import patch_artifact
    offset = request.headers.get("upload-offset", "")
    if not offset.isdigit():
        raise HTTPException(422, "Upload-Offset required")
    return await patch_artifact(artifact_id, request, reference_owner(artifact_id), int(offset))


@router.post("/artifacts/{artifact_id}/complete", dependencies=[Depends(require_label_user), Depends(require_upload_origin)])
def dashboard_reference_complete(artifact_id: uuid.UUID):
    from server.app import complete_artifact
    return complete_artifact(artifact_id, reference_owner(artifact_id))
