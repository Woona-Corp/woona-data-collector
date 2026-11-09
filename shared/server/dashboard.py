"""Label Studio-authenticated recording catalog and existing reference uploads."""

import html
import http.client
import json
import os
import stat
import threading
import time
import uuid
from collections import Counter, defaultdict
from datetime import date, datetime
from pathlib import Path
from typing import Literal
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request as UrlRequest, urlopen
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse
from sqlalchemy import text
from starlette.concurrency import run_in_threadpool

from server.eligibility import activity_exclusion_reasons
from server.sync_status import recording_status, stored_file_observation
from server.label_sync import active_project, file_url, request_json

router = APIRouter(prefix="/dashboard", tags=["dashboard"])
KINDS = ("activity",)
VIDEO_KINDS = KINDS
LABEL_SUMMARY_TTL_SECONDS = 15
LABEL_REFRESH_SECONDS = 5
LABEL_DETAIL_LIMIT = 20
LABEL_TASK_LIMIT = 10_000
LABEL_RESPONSE_LIMIT = 2 * 1024 * 1024
LABEL_REFRESH_BYTES = 16 * 1024 * 1024
_label_summary_lock = threading.Lock()
_label_summary_cache: tuple[tuple[str | None, str], float, tuple[list[dict], dict, dict], str] | None = None


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
            SELECT r.id, r.started_at, r.ended_at, r.source, r.session_label,
                   r.dog_id, d.account_id, r.ingest_status, r.capture_status,
                   r.questionnaire_validation_state, r.session_questionnaire, r.capture_error_code,
                   r.capture_error_message,r.server_verified_at,r.receipt_sha256,r.server_updated_at,
                   (SELECT alignment FROM recording_sync WHERE recording_id=r.id) AS alignment,
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
        if source_id not in app_records:
            started_at = row["started_at"].astimezone(ZoneInfo("UTC"))
            ended_at = row["ended_at"].astimezone(ZoneInfo("UTC")) if row["ended_at"] else None
            duration = (ended_at - started_at).total_seconds() if ended_at else None
            app_records[source_id] = {
                "source_id": source_id, "origin": "Woona", "dog": row["number_or_name"],
                "dog_id": str(row["dog_id"]), "account_id": row["account_id"],
                "account_name": row["account_id"],
                "date": started_at.date().isoformat(), "files": [],
                "started_at": started_at.isoformat(),
                "ended_at": ended_at.isoformat() if ended_at else None,
                "duration_seconds": duration if duration is not None and duration >= 0 else None,
                "source": row["source"], "session_label": row["session_label"],
                "recording_id": str(row["id"]), "session_kind": row["session_questionnaire"].get("sessionKind", "activity"),
                "ingest_status": row["ingest_status"], "capture_status": row["capture_status"],
                "capture_error_code": row["capture_error_code"],
                "capture_error_message": row["capture_error_message"],
                "_recording": row, "_artifacts": [], "_file_observations": {},
                "profile": {"version_id": str(row["profile_id"]), "state": row["profile_state"],
                            "answers": row["profile_questionnaire"]},
                "session_questionnaire": {"state": row["questionnaire_validation_state"],
                                          "answers": row["session_questionnaire"]},
            }
        record = app_records[source_id]
        if row["artifact_type"]:
            record['_artifacts'].append({**row, 'id': row['artifact_id']})
            relative = row["server_relative_path"]
            observation = (stored_file_observation(row, STORAGE_ROOT)
                           if row["storage_status"] == "available" else None)
            if observation is not None:
                record['_file_observations'][row['artifact_id']] = observation
            record["files"].append({"id": str(row["artifact_id"]), "name": row["file_name"], "relative": "woona/" +
                                    (relative or ""),
                                    "size": row["expected_size_bytes"],
                                    "type": row["artifact_type"],
                                    "reference_metadata": row["reference_metadata"],
                                    "storage_status": row['storage_status'],
                                    "uploaded_bytes": row['stored_size_bytes'],
                                    "error_code": row['error_code'], "error_message": row['error_message'],
                                    "last_progress_at_utc": row['upload_updated_at'].isoformat(),
                                    "available": observation[0] if observation is not None else False})
    for record in app_records.values():
        record['server_status'] = recording_status(record.pop('_recording'), record.pop('_artifacts'), STORAGE_ROOT,
                                                   file_observations=record.pop('_file_observations'))
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
        labeled_tasks = [bool(task and task["labeled"]) for task in record["tasks"].values()]
        record["annotated_any"] = any(labeled_tasks)
        record["annotated_all"] = all(labeled_tasks)
        labeling = record.get('server_status', {}).get('labeling')
        record["exclusion_reasons"] = (labeling['exclusionReasons'] if labeling is not None else
            activity_exclusion_reasons(
                record['ingest_status'], record.get('capture_status'), record.get('capture_error_code'),
                (record.get('session_questionnaire') or {}).get('answers') or {},
                {f.get('type') for f in files}))
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
    records.sort(key=lambda r: (r.get("started_at") or r["date"], r["source_id"]), reverse=True)
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


def clear_label_summary_cache() -> None:
    global _label_summary_cache
    with _label_summary_lock:
        _label_summary_cache = None


def load_label_summary() -> tuple[list[dict], dict, dict, dict]:
    """One bounded, short-lived LS snapshot, never a cache of file integrity.

    Complete list annotations avoid an N-request detail walk. Older providers
    get a bounded fallback; an incomplete snapshot is unavailable, not zero.
    """
    global _label_summary_cache
    key = (os.environ.get('LABEL_STUDIO_URL'), os.environ.get('LABEL_PROJECT_ID', '21'))
    now = time.monotonic()
    cached = _label_summary_cache
    if cached is not None and cached[0] == key and now - cached[1] < LABEL_SUMMARY_TTL_SECONDS:
        return (*cached[2], {'available': True, 'checkedAtUtc': cached[3],
                            'ageSeconds': max(0, int(now - cached[1])), 'cached': True})
    if not _label_summary_lock.acquire(blocking=False):
        raise RuntimeError('Label Studio summary refresh is already in progress')
    try:
        # Another caller may have published while this caller acquired the lock.
        now = time.monotonic()
        cached = _label_summary_cache
        if cached is not None and cached[0] == key and now - cached[1] < LABEL_SUMMARY_TTL_SECONDS:
            return (*cached[2], {'available': True, 'checkedAtUtc': cached[3],
                                'ageSeconds': max(0, int(now - cached[1])), 'cached': True})
        deadline = now + LABEL_REFRESH_SECONDS
        remaining_bytes = LABEL_REFRESH_BYTES
        requests = 0

        def consume_bytes(count):
            nonlocal remaining_bytes
            remaining_bytes -= count
            if remaining_bytes < 0:
                raise RuntimeError('Label Studio summary byte budget exhausted')

        def fetch(method, path):
            nonlocal requests
            remaining = deadline - time.monotonic()
            if remaining <= 0 or requests >= 128 or remaining_bytes <= 0:
                raise RuntimeError('Label Studio whole-refresh budget exhausted')
            requests += 1
            value = request_json(method, path, timeout=min(3.0, remaining),
                                 maximum_bytes=min(LABEL_RESPONSE_LIMIT, remaining_bytes),
                                 deadline=deadline, consume_bytes=consume_bytes)
            # Retain the decoded-object guard too; aggregate accounting above is
            # raw bytes consumed before parsing, including whitespace/escapes.
            size = len(json.dumps(value, ensure_ascii=False).encode())
            if size > LABEL_RESPONSE_LIMIT:
                raise RuntimeError('Label Studio summary byte budget exhausted')
            return value

        project = active_project(fetch=fetch)
        project = {name: project[name] for name in ('id', 'title', 'timeline_name', 'labels')}
        tasks, labeled, seen = [], {}, set()
        page, details = 1, 0
        while True:
            body = fetch('GET', '/api/tasks?' + urlencode({'project': project['id'], 'fields': 'all',
                                                          'page': page, 'page_size': 100}))
            if isinstance(body, list):
                if page != 1:
                    raise RuntimeError('Label Studio pagination changed format')
                batch, total, more = body, len(body), False
            elif isinstance(body, dict):
                batch = body.get('results', body.get('tasks', []))
                total, more = body.get('total', body.get('count')), bool(body.get('next'))
                if total is not None and (type(total) is not int or total < 0):
                    raise RuntimeError('Invalid Label Studio task total')
            else:
                raise RuntimeError('Invalid Label Studio task-list response')
            if not isinstance(batch, list):
                raise RuntimeError('Invalid Label Studio task page')
            if len(tasks) + len(batch) > LABEL_TASK_LIMIT or (total is not None and total > LABEL_TASK_LIMIT):
                raise RuntimeError('Label Studio task summary exceeds its bounded capacity')
            if not batch and (more or (total is not None and total > len(tasks))):
                raise RuntimeError('Label Studio pagination stopped before the complete snapshot')
            for item in batch:
                if not isinstance(item, dict) or not isinstance(item.get('data', {}), dict):
                    raise RuntimeError('Invalid Label Studio task')
                task_id = item['id']
                source_id = item.get('data', {}).get('source_id')
                if type(task_id) not in (int, str) or (source_id is not None and not isinstance(source_id, str)):
                    raise RuntimeError('Invalid Label Studio task identity')
                if task_id in seen:
                    raise RuntimeError('Label Studio pagination repeated task IDs')
                seen.add(task_id)
                task = {'id': task_id, 'data': {'source_id': source_id},
                        'is_labeled': bool(item.get('is_labeled'))}
                tasks.append(task)
                if task['is_labeled']:
                    full = item
                    if 'annotations' not in full:
                        if details >= LABEL_DETAIL_LIMIT:
                            raise RuntimeError('Label Studio did not supply a complete bounded annotation summary')
                        details += 1
                        full = fetch('GET', f'/api/tasks/{task_id}')
                    if not isinstance(full, dict) or not isinstance(full.get('annotations'), list):
                        raise RuntimeError('Labeled task has no complete annotation summary')
                    # Validate nested external shapes before summarize indexes them.
                    # Retain only the fields consumed by it, not arbitrary task payloads.
                    annotations = []
                    for annotation in full['annotations']:
                        if not isinstance(annotation, dict) or not isinstance(annotation.get('result', []), list):
                            raise RuntimeError('Invalid Label Studio annotation')
                        results = []
                        for result in annotation.get('result', []):
                            if not isinstance(result, dict):
                                raise RuntimeError('Invalid Label Studio annotation result')
                            if result.get('from_name') != project['timeline_name']:
                                continue
                            value = result.get('value', {})
                            labels = value.get('timelinelabels', []) if isinstance(value, dict) else None
                            if not isinstance(labels, list) or any(not isinstance(label, str) for label in labels):
                                raise RuntimeError('Invalid Label Studio timeline labels')
                            results.append({'from_name': result['from_name'], 'value': {'timelinelabels': labels}})
                        annotations.append({'was_cancelled': annotation.get('was_cancelled'), 'result': results})
                    labeled[('activity', task_id)] = {'annotations': annotations}
            if not more and (total is None or len(tasks) >= total):
                break
            page += 1
        checked_at = datetime.now(ZoneInfo('UTC')).isoformat(timespec='seconds')
        summary = ([project], {'activity': tasks}, labeled)
        _label_summary_cache = (key, time.monotonic(), summary, checked_at)
        return (*summary, {'available': True, 'checkedAtUtc': checked_at, 'ageSeconds': 0, 'cached': False})
    finally:
        _label_summary_lock.release()


def load_dashboard() -> dict:
    # Owner explicitly requires a fresh full physical-file pass on every request.
    records, extra = records_from_sources()
    try:
        projects, tasks, labeled, extra['label_service'] = load_label_summary()
    except (HTTPError, URLError, TimeoutError, OSError, http.client.HTTPException, ValueError, RuntimeError, KeyError) as error:
        # A labeling outage must not hide transfer/capture diagnostics or imply zero tasks.
        projects = [{'id': int(os.environ.get('LABEL_PROJECT_ID', '21')),
                     'title': 'Label Studio', 'timeline_name': '', 'labels': []}]
        tasks, labeled = {kind: [] for kind in KINDS}, {}
        extra['label_service'] = {'available': False, 'code': 'label_studio_unavailable',
            'message': 'Статусы задач Label Studio сейчас недоступны. Данные и статусы файлов показаны; отсутствие задач не подтверждено.',
            'retryable': True, 'errorType': type(error).__name__}
    return summarize(records, projects, tasks, labeled, extra)


def _catalog_escape(value) -> str:
    return html.escape(str(value) if value is not None else '', quote=True)


def _catalog_segment(value) -> str:
    # urlencode also encodes slashes and quotes; spaces in path segments are %20.
    return urlencode({'': str(value)})[1:].replace('+', '%20')


def _catalog_time(value) -> str:
    if not value:
        return 'Не указано'
    try:
        instant = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        if instant.tzinfo is None:
            instant = instant.replace(tzinfo=ZoneInfo('UTC'))
        return instant.astimezone(ZoneInfo('UTC')).strftime('%d.%m.%Y %H:%M:%S UTC')
    except ValueError:
        return str(value)


def _catalog_day(record) -> str:
    value = record.get('started_at') or record.get('date', '')
    try:
        instant = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
        if instant.tzinfo is not None:
            instant = instant.astimezone(ZoneInfo('UTC'))
        return instant.date().isoformat()
    except ValueError:
        return ''


def _catalog_duration(record) -> float | None:
    value = record.get('duration_seconds')
    # Unknown/negative/nonfinite metadata must not look like a zero-length capture.
    return value if type(value) in (int, float) and 0 <= value < float('inf') else None


def _catalog_duration_text(record) -> str:
    value = _catalog_duration(record)
    if value is None:
        return 'Длительность неизвестна'
    seconds = int(value)
    return f'{seconds // 3600:02}:{seconds // 60 % 60:02}:{seconds % 60:02}'


def _catalog_upload_problem(record) -> bool:
    transfer = record.get('server_status', {}).get('transfer', {})
    return (transfer.get('status') in ('integrity_problem', 'rejected') or bool(transfer.get('stalled'))
            or record.get('ingest_status') in ('corrupt', 'rejected')
            or any(item.get('errorCode') or item.get('storageStatus') in ('corrupt', 'missing', 'rejected')
                   for item in record.get('server_status', {}).get('artifacts', []))
            or any(f.get('error_code') or (f.get('storage_status') == 'available' and not f.get('available'))
                   for f in record.get('files', [])))


def _catalog_label_state(data, record) -> str:
    if not data.get('label_service', {}).get('available', True):
        return 'Статус Label Studio недоступен; наличие задачи не проверено'
    if record.get('session_kind') == 'heart':
        return 'Сердцебиение · хранение без разметки'
    if record.get('exclusion_reasons'):
        prefix = 'Есть разметка; сейчас не допущено: ' if record.get('annotated_any') else 'Не допущено: '
        return prefix + '; '.join(record['exclusion_reasons'])
    if record.get('annotated_all'):
        return 'Видео размечено'
    if record.get('annotated_any'):
        return 'Разметка в процессе'
    if any(record.get('tasks', {}).values()):
        return 'Ожидает разметки'
    return 'Ожидает импорта' if record.get('eligible') else 'Не допущено к разметке'


def _catalog_icon(name: str) -> str:
    """Small local UI glyphs; no remote assets, icon font or script dependency."""
    paths = {
        'search': '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
        'refresh': '<path d="M20 7v5h-5M4 17v-5h5M6 7a7 7 0 0 1 12-2l2 2M4 17l2 2a7 7 0 0 0 12-2"/>',
        'chevron': '<path d="m9 5 7 7-7 7"/>',
        'arrow-right': '<path d="M4 12h16m-6-6 6 6-6 6"/>',
        'arrow-left': '<path d="M20 12H4m6-6-6 6 6 6"/>',
        'list': '<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M8 9h8M8 13h8M8 17h5"/>',
        'film': '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m10 9 5 3-5 3z"/>',
        'clock': '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        'activity': '<path d="M2 12h5l3-8 4 16 3-8h5"/>',
        'upload': '<path d="M12 16V3m-5 5 5-5 5 5M4 16v4h16v-4"/>',
        'download': '<path d="M12 3v13m-5-5 5 5 5-5M4 17v4h16v-4"/>',
        'file': '<path d="M14 3H5v18h14V8zM14 3v5h5M8 13h8M8 17h5"/>',
        'folder': '<path d="M3 7V4h7l2 3h9v13H3z"/>',
        'filter': '<path d="M4 6h16M7 12h10M10 18h4"/>',
        'calendar': '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 3v4M17 3v4M3 10h18M7 14h2M15 14h2M7 18h2"/>',
        'external': '<path d="M14 3h7v7M21 3 11 13M10 5H4v15h15v-6"/>',
        'check': '<path d="m5 12 4 4L19 6"/>',
        'alert': '<path d="m12 3 10 18H2zM12 9v5M12 17v1"/>',
        'paw': '<ellipse cx="7" cy="7" rx="2" ry="3"/><ellipse cx="17" cy="7" rx="2" ry="3"/><ellipse cx="3.5" cy="12" rx="1.5" ry="2.5"/><ellipse cx="20.5" cy="12" rx="1.5" ry="2.5"/><path d="M7 16c1-5 9-5 10 0 3 7-3 3-5 3s-8 4-5-3z"/>',
        'help': '<circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 1 1 5 2c-2 1-2 1-2 3M12 17v1"/>',
    }
    return '<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths.get(name, paths['file']) + '</svg>'


def _catalog_url(params: dict, **overrides) -> str:
    values = {**params, **overrides}
    return '/dashboard?' + urlencode(values) + '#data-manager'


def _catalog_back_url(value: str) -> str:
    """Only a local catalog URL may become a return link, never an external URL."""
    try:
        parsed = urlsplit(value)
    except ValueError:
        return '/dashboard'
    if parsed.scheme or parsed.netloc or parsed.path != '/dashboard':
        return '/dashboard'
    return '/dashboard' + ('?' + parsed.query if parsed.query else '') + '#data-manager'


def _catalog_size(size) -> str:
    if type(size) not in (int, float) or not 0 <= size < float('inf'):
        return 'Размер неизвестен'
    for divisor, unit in ((1_000_000_000, 'ГБ'), (1_000_000, 'МБ'), (1_000, 'КБ')):
        if size >= divisor:
            return f'{size / divisor:.1f} {unit}'
    return f'{size:g} Б'


def _catalog_badge(label: str, tone: str = 'neutral', hint: str = '') -> str:
    return ('<span class="badge ' + _catalog_escape(tone) + '" title="' + _catalog_escape(hint) +
            '"><span class="badge-dot" aria-hidden="true"></span>' + _catalog_escape(label) + '</span>')


def _catalog_states(data: dict, record: dict) -> dict:
    """Compact labels for the same independent states on list and detail pages."""
    capture = record.get('capture_status') or ''
    capture_names = {'completed': ('Завершена', 'success'), 'recording': ('Идёт запись', 'info'),
                     'preparing': ('Подготовка', 'neutral'), 'interrupted': ('Прервана', 'danger'),
                     'failed': ('Ошибка', 'danger')}
    label, tone = capture_names.get(capture, ('Неизвестно', 'neutral'))
    error = record.get('capture_error_message') or record.get('capture_error_code') or ''
    if error:
        label, tone = 'Есть ошибка', 'danger'
    capture_html = _catalog_badge(label, tone, error)
    transfer = record.get('server_status', {}).get('transfer', {})
    transfer_names = {'verified': ('Подтверждена', 'success'), 'uploading': ('Загружается', 'info'),
                      'metadata_pending': ('Метаданные', 'neutral'), 'awaiting_verification': ('Проверка', 'warning'),
                      'integrity_problem': ('Ошибка файлов', 'danger'), 'rejected': ('Отклонена', 'danger')}
    label, tone = transfer_names.get(transfer.get('status'), ('Не подтверждена', 'neutral'))
    if not transfer and record.get('ingest_status') == 'uploading':
        label, tone = 'Загружается', 'info'
    if transfer.get('stalled'):
        label, tone = 'Нет прогресса', 'warning'
    if _catalog_upload_problem(record) and transfer.get('status') == 'verified':
        label, tone = 'Ошибка референса', 'warning'
    transfer_hint = ('Нет прогресса ≥15 минут; продолжите передачу на исходном устройстве' if transfer.get('stalled')
                     else 'Состояние передачи файлов; не результат съёмки')
    transfer_html = _catalog_badge(label, tone, transfer_hint)
    if not data.get('label_service', {}).get('available', True):
        label, tone = 'Неизвестно', 'neutral'
    elif record.get('session_kind') == 'heart':
        label, tone = 'Не требуется', 'neutral'
    elif record.get('annotated_any'):
        label, tone = 'Есть разметка', 'success'
    elif record.get('exclusion_reasons'):
        label, tone = 'Не допущена', 'neutral'
    elif any(record.get('tasks', {}).values()):
        label, tone = 'Ожидает', 'warning'
    else:
        label, tone = 'Нет задачи', 'neutral'
    return {'capture': capture_html, 'transfer': transfer_html,
            'label': _catalog_badge(label, tone, _catalog_label_state(data, record))}


def _catalog_capture(record) -> str:
    names = {'completed': 'Запись завершена', 'recording': 'Идёт запись', 'preparing': 'Подготовка',
             'failed': 'Ошибка записи', 'camera_failed': 'Ошибка камеры', 'interrupted': 'Запись прервана',
             'cancelled': 'Запись отменена', 'stopped': 'Запись остановлена'}
    status = record.get('capture_status')
    text = names.get(status, 'Состояние записи неизвестно')
    if record.get('capture_error_code') or record.get('capture_error_message'):
        text += ' · ' + (record.get('capture_error_message') or record['capture_error_code'])
    return _catalog_escape(text)


def _catalog_transfer(record) -> str:
    escape = _catalog_escape
    transfer = record.get('server_status', {}).get('transfer', {})
    names = {'metadata_pending': 'Ожидает метаданных', 'uploading': 'Загрузка не завершена — продолжите передачу с телефона',
             'awaiting_verification': 'Байты переданы; ожидается проверка', 'verified': 'Исходные файлы подтверждены',
             'integrity_problem': 'Проблема целостности — сохраните локальные оригиналы', 'rejected': 'Загрузка отклонена'}
    fallback = {'complete': 'Передача завершена; подтверждение файлов не показано',
                'uploading': 'Загрузка не завершена', 'pending': 'Ожидает передачи', 'verified': 'Файлы проверены'}
    result = escape(names.get(transfer.get('status'), fallback.get(record.get('ingest_status'), 'Состояние передачи неизвестно')))
    if transfer:
        result += (f'<div class="muted">{escape(transfer.get("uploadedBytes", 0))} / '
                   f'{escape(transfer.get("totalBytes", 0))} B · проверено файлов: '
                   f'{escape(transfer.get("verifiedFiles", 0))}/{escape(transfer.get("totalFiles", 0))}</div>')
    if transfer.get('stalled'):
        result += '<p class="warning">Нет прогресса ≥15 минут. Продолжите загрузку на исходном устройстве. Последний прогресс: ' + escape(_catalog_time(transfer.get('lastProgressAtUtc'))) + '</p>'
    warnings = record.get('server_status', {}).get('quality', {}).get('warnings', [])
    if warnings:
        names = {'packet_rejections_observed': 'Отброшенные пакеты в исходном журнале',
                 'reported_packet_loss_requires_validation': 'Счётчик потерь требует перепроверки',
                 'excluded_sensor_intervals': 'Исключённые интервалы датчиков', 'invalid_sensor_packets': 'Некорректные пакеты датчиков'}
        result += '<details><summary>Качество данных: есть замечания</summary><ul>' + ''.join(
            '<li>' + escape(names.get(item.get('code'), item.get('code'))) + ': ' + escape(item.get('count', 0)) + '</li>'
            for item in warnings) + '</ul></details>'
    return result


def _catalog_files(record) -> str:
    escape = _catalog_escape
    observations = {str(item.get('id')): item for item in record.get('server_status', {}).get('artifacts', [])}
    rows = []
    kinds = {'video': 'Видео', 'packet': 'BLE-пакеты', 'packet_timeline': 'Временные метки BLE',
             'raw': 'Исходные данные датчика', 'diagnostic': 'Диагностика', 'sync': 'Синхронизация',
             'ecg': 'Контрольная ЭКГ', 'heart_rate': 'Контрольная ЧСС', 'rr': 'RR-интервалы'}
    error_names = {'stored_file_missing': 'Файл не найден на сервере',
                   'stored_file_size_mismatch': 'Размер файла не совпадает с ожидаемым',
                   'stored_file_unreadable': 'Сервер не может прочитать файл',
                   'artifact_verification_missing': 'Проверка файла не подтверждена',
                   'hash_mismatch': 'Контрольная сумма не совпадает',
                   'upload_not_started': 'Передача файла ещё не началась',
                   'upload_interrupted': 'Передача файла прервана',
                   'upload_file_unreadable': 'Не удаётся прочитать незавершённую загрузку'}
    for item in record.get('files', []):
        observation = observations.get(str(item.get('id') or item.get('artifact_id')), {})
        if not observation:
            observation = next((o for o in observations.values() if o.get('fileName') == item.get('name')), {})
        name = escape(item.get('name', 'Файл'))
        available = bool(item.get('available'))
        action = '<span class="file-action muted">—</span>'
        if available:
            url = escape(file_url(item['relative']))
            action = '<a class="file-action icon-button" href="' + url + '" download aria-label="Скачать ' + name + '">' + _catalog_icon('download') + '</a>'
            name = '<a href="' + url + '">' + name + '</a>'
        state, tone = ('Доступен', 'success') if available else ('Недоступен', 'neutral')
        if not available and item.get('storage_status') in ('pending', 'uploading'):
            state, tone = 'Загружается', 'info'
        error = ' · '.join(dict.fromkeys(str(value) for value in (
            item.get('error_code'), item.get('error_message'), observation.get('errorCode'),
            observation.get('errorMessage')) if value))
        if error:
            state, tone = 'Требует проверки', 'warning'
        error_code = observation.get('errorCode') or item.get('error_code') or ''
        explanation = error_names.get(error_code, 'Проверьте передачу файла')
        rows.append('<li class="file-item"><span class="file-icon">' +
                    _catalog_icon('film' if item.get('type') == 'video' else 'file') + '</span>' +
                    '<div class="file-info"><div class="file-name">' + name + '</div>' +
                    '<span class="file-kind">' + escape(kinds.get(item.get('type'), 'Файл записи')) + '</span></div>' +
                    '<span class="file-size mono">' + escape(_catalog_size(item.get('size'))) + '</span>' +
                    '<span class="file-state">' + _catalog_badge(state, tone) + '</span>' + action +
                    ('<details class="file-error"><summary>' + escape(explanation) + '</summary><p>' +
                     escape(error) + '</p></details>' if error else '') + '</li>')
    return '<ul class="file-list">' + ''.join(rows) + '</ul>' if rows else '<p class="muted">Файлы не зарегистрированы</p>'


def _catalog_actions(data, record) -> str:
    escape = _catalog_escape
    links = []
    if data.get('label_service', {}).get('available', True):
        for kind, task in record.get('tasks', {}).items():
            if task is None or task.get('id') is None:
                continue
            category = data.get('categories', {}).get(kind, {})
            if category.get('project_id') is None:
                continue
            url = '/projects/' + _catalog_segment(category['project_id']) + '/data?' + urlencode({'task': task['id']})
            links.append('<a class="button primary" href="' + escape(url) + '" title="' +
                         escape(category.get('title', 'Label Studio')) + '">Открыть разметку ' + _catalog_icon('external') + '</a>')
    if record.get('recording_id'):
        url = '/dashboard/recordings/' + _catalog_segment(record['recording_id']) + '/references'
        links.append('<a class="button secondary" href="' + escape(url) + '">Добавить ЭКГ / ЧСС</a>' +
                     '<span class="connection-note">Это загрузка контрольного файла в запись.</span>')
    return '<div class="actions">' + ''.join(links) + '</div>'


def _catalog_diagnostics(data) -> str:
    escape = _catalog_escape
    service = data.get('label_service', {})
    rec = data.get('reconciliation', {})
    if service.get('available', True):
        text = (f'Сверка Label Studio: ожидают импорта {len(rec.get("eligible_missing_tasks", []))}; '
                f'дубли источников {len(rec.get("duplicate_task_sources", {}))}; '
                f'задачи без записи {len(rec.get("unknown_task_sources", []))}; '
                f'исключённые записи в LS {len(rec.get("ineligible_task_sources", []))}. ')
    else:
        text = service.get('message') or 'Label Studio недоступен. Наличие задач и разметки не проверено.'
    if service.get('checkedAtUtc'):
        text += (f' снимок Label Studio: {service["checkedAtUtc"]}, возраст {service.get("ageSeconds", "неизвестен")} с '
                 f'(кэш не более {LABEL_SUMMARY_TTL_SECONDS} с; файлы проверены заново).')
    text += (f' Загрузки без прогресса ≥15 минут: {rec.get("stalled_uploads", 0)}; '
             f'проблемы целостности: {rec.get("integrity_problems", 0)}. '
             'Сверка охватывает весь каталог, а не выбранные фильтры. '
             'Проверка не видит записи, которые ещё не отправлены с телефонов.')
    details = '<details class="service-details"><summary>Служебная сверка файлов и Label Studio</summary><p>' + escape(text) + '</p></details>'
    if not service.get('available', True):
        return '<aside class="notice warning" role="status">Статусы разметки недоступны. Наличие задач не проверено; записи и файлы доступны без фильтра по разметке.</aside>' + details
    return details


def _catalog_projects(data) -> str:
    escape = _catalog_escape
    content = '<p class="muted">Снимок Label Studio по всему проекту, независимо от фильтров каталога. Наличие аннотации не означает покрытие всех кадров.</p>'
    if not data.get('label_service', {}).get('available', True):
        content += '<p>Недоступно: количество задач и разметки сейчас не подтверждено.</p>'
    else:
        for category in data.get('categories', {}).values():
            url = '/projects/' + _catalog_segment(category['project_id']) + '/data'
            content += ('<h3><a href="' + escape(url) + '">' + escape(category['title']) + '</a></h3>' +
                        '<p>Есть разметка: ' + escape(category['labeled']) + ' / ' + escape(category['tasks']) + ' задач</p>')
            content += '<ul>' + ''.join(
                '<li>' + escape(label) + ': ' + escape(counts['records']) + ' записей / ' +
                escape(counts['segments']) + ' интервалов</li>'
                for label, counts in category.get('classes', {}).items()) + '</ul>'
    return '<section class="service-details"><details><summary>Разметка по классам — весь проект</summary>' + content + '</details></section>'


_CATALOG_WORKSPACE_CSS = r"""
/* Woona internal workspace — compact, content-first application UI. */
:root {
  color-scheme: light;
  --canvas: #fff;
  --surface: #fafafa;
  --line: #e9eaed;
  --ink: #17181c;
  --muted: #70747d;
  --accent: #e55d3c;
  --accent-hover: #c7482a;
  --accent-soft: #fff3ee;
  --green: #28734b;
  --green-bg: #edf7f0;
  --amber: #93620c;
  --amber-bg: #fff7e5;
  --red: #b33434;
  --red-bg: #fff0ef;
  --radius: 6px;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 13px;
  line-height: 1.5;
  font-variant-numeric: tabular-nums;
  color: var(--ink);
  background: var(--canvas);
}
*, *::before, *::after { box-sizing: border-box; }
body { margin: 0; }
button, input, select, textarea { font: inherit; color: inherit; }
button, summary, select { cursor: pointer; }
button { background: none; }
input, select, textarea { max-width: 100%; }
img, video { max-width: 100%; }
svg { flex-shrink: 0; }
a { color: var(--accent-hover); text-decoration: underline; text-underline-offset: 3px; }
a:hover { color: var(--accent-hover); }
button:disabled, input:disabled, select:disabled { opacity: .5; cursor: not-allowed; }
:where(a, button, input, select, textarea, summary, [tabindex]):focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 3px;
}
h1, h2, h3, p, dl { margin: 0; }
h1 { font-size: 25px; line-height: 1.28; font-weight: 650; letter-spacing: -.65px; }
h2 { font-size: 15px; line-height: 1.4; font-weight: 650; letter-spacing: -.2px; }
h3 { font-size: 13px; font-weight: 650; }
small { font-size: 11px; }
.muted, .subtitle, .cell-sub, .record-meta, .metric-note, .sort-note, .results-caption { color: var(--muted); }
.mono { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .92em; overflow-wrap: anywhere; }
.icon { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.7; vertical-align: middle; }
.sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; border: 0; }
.skip { position: fixed; top: 8px; left: 8px; z-index: 100; padding: 8px 12px; background: var(--ink); color: white; border-radius: var(--radius); transform: translateY(-160%); }
.skip:focus { transform: none; color: white; }
.app-layout { display: grid; grid-template-columns: 216px minmax(0, 1fr); min-height: 100dvh; }
.sidebar { position: fixed; inset: 0 auto 0 0; width: 216px; display: flex; flex-direction: column; overflow-y: auto; padding: 0 12px 12px; background: var(--surface); border-right: 1px solid var(--line); }
.sidebar-brand { min-height: 72px; display: flex; align-items: center; gap: 10px; padding: 12px; color: var(--ink); text-decoration: none; }
.brand-mark { display: inline-flex; align-items: center; justify-content: center; width: 28px; height: 28px; border-radius: 6px; color: white; background: var(--accent); font-size: 19px; font-weight: 750; letter-spacing: -1px; }
.brand-name { font-size: 19px; font-weight: 700; letter-spacing: -.6px; }
.sidebar-section { margin: 12px 0 20px; }
.nav-label { display: block; margin: 0 12px 8px; color: var(--muted); font-size: 10px; font-weight: 650; letter-spacing: .8px; text-transform: uppercase; }
.nav-item { display: flex; align-items: center; gap: 8px; min-height: 36px; padding: 8px 12px; margin: 2px 0; border-radius: var(--radius); color: #4e525a; text-decoration: none; overflow-wrap: anywhere; }
.nav-item:hover { background: #f0f0f1; color: var(--ink); }
.nav-item.active { color: #b43f25; background: var(--accent-soft); font-weight: 600; }
.nav-count { margin-left: auto; padding-left: 8px; font-size: 11px; color: var(--muted); }
.nav-item.active .nav-count { color: inherit; }
.sidebar-foot { margin-top: auto; padding: 16px 8px 0; border-top: 1px solid var(--line); font-size: 12px; color: var(--muted); }
.workspace { grid-column: 2; min-width: 0; }
.topbar { min-height: 56px; display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 8px 32px; border-bottom: 1px solid var(--line); }
.breadcrumb { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; min-width: 0; font-size: 12px; color: var(--muted); overflow-wrap: anywhere; }
.breadcrumb a { color: inherit; }
.breadcrumb [aria-current] { color: var(--ink); }
.topbar-actions, .heading-actions, .actions { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
.topbar-actions { flex-shrink: 0; font-size: 11px; color: var(--muted); }
.tools-menu { position: relative; }
.tools-menu > summary { cursor: pointer; list-style: none; }
.tools-menu > summary::-webkit-details-marker { display: none; }
.tools-menu[open] > summary { background: var(--surface); }
.tools-menu > nav { position: absolute; z-index: 30; right: 0; top: calc(100% + 8px); width: 220px; padding: 6px; border: 1px solid var(--line); border-radius: var(--radius); background: white; box-shadow: 0 6px 18px #15171a12; }
.tools-menu .nav-item { font-size: 12px; }
.page-content { padding: 24px 32px 32px; min-width: 0; }
.page-heading { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 24px; }
.heading-copy { min-width: 0; overflow-wrap: anywhere; }
.subtitle { margin-top: 4px; font-size: 12px; }
.detail-context { margin-top: 6px; font-size: 12px; color: var(--muted); overflow-wrap: anywhere; }
.button, .icon-button { display: inline-flex; align-items: center; justify-content: center; gap: 6px; min-height: 32px; padding: 6px 12px; border: 1px solid var(--line); border-radius: var(--radius); background: white; color: var(--ink); font-weight: 550; font-size: 12px; line-height: 18px; text-decoration: none; white-space: nowrap; }
.button:hover, .icon-button:hover { color: var(--ink); background: #f5f5f6; border-color: #d1d3d7; }
.button.primary { color: white; background: var(--accent-hover); border-color: var(--accent-hover); }
.button.primary:hover { background: #b03d23; border-color: #b03d23; }
.button.secondary { background: white; }
.icon-button { width: 32px; padding: 6px; flex-shrink: 0; }
.metrics { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); padding: 16px 0; margin-bottom: 12px; border-block: 1px solid var(--line); }
.metric { min-width: 0; padding: 0 20px; border-left: 1px solid var(--line); overflow-wrap: anywhere; }
.metric:first-child { border-left: 0; padding-left: 0; }
.metric:last-child { padding-right: 0; }
.metric > :is(dt, h3, span, .metric-label) { margin-bottom: 4px; color: var(--muted); font-size: 11px; font-weight: 500; }
.metric > :is(dd, strong, .metric-value) { display: block; margin: 0; font-size: 24px; font-weight: 600; line-height: 1.25; letter-spacing: -.6px; }
.metric > strong.metric-text { font-size: 14px; line-height: 30px; letter-spacing: 0; }
.metric-note { display: block; margin-top: 4px; font-size: 11px; }
.summary-notes { margin-bottom: 20px; color: var(--muted); font-size: 11px; }
.summary-notes p { max-width: 850px; margin-top: 8px; line-height: 1.6; }
.summary-notes summary { width: fit-content; }
.service-details p, .service-details ul { margin-top: 8px; }
.toolbar-actions { display: flex; align-items: center; gap: 8px; }
.panel { min-width: 0; border: 1px solid var(--line); border-radius: var(--radius); background: white; }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 16px; border-bottom: 1px solid var(--line); }
.tabs { display: flex; gap: 24px; min-width: 0; overflow-x: auto; border-bottom: 1px solid var(--line); padding: 0 16px; }
.tabs a { display: inline-flex; align-items: center; gap: 6px; flex-shrink: 0; min-height: 44px; padding: 10px 0; border-bottom: 2px solid transparent; color: var(--muted); font-size: 12px; font-weight: 550; text-decoration: none; }
.tabs a:hover { color: var(--ink); }
.tabs a[aria-current]:not([aria-current="false"]) { color: var(--ink); border-bottom-color: var(--accent); }
.tab-count { padding: 0 5px; border-radius: 4px; background: #f2f3f4; color: var(--muted); font-size: 10px; }
.toolbar { position: relative; display: flex; align-items: center; flex-wrap: wrap; gap: 8px; padding: 12px 16px; }
.search-field { display: flex; align-items: center; gap: 8px; flex: 1 1 220px; max-width: 360px; min-width: 0; min-height: 34px; padding: 6px 10px; border: 1px solid #dedfe3; border-radius: var(--radius); color: var(--muted); background: white; }
.search-field:focus-within { outline: 2px solid var(--accent); outline-offset: 2px; }
.search-field input { width: 100%; min-width: 0; padding: 0; border: 0; outline: none; background: transparent; font-size: 12px; }
.search-field input::placeholder { color: var(--muted); opacity: 1; }
.account-filter { min-width: 0; max-width: 220px; min-height: 34px; padding: 6px 28px 6px 10px; border: 1px solid #dedfe3; border-radius: var(--radius); background-color: white; font-size: 12px; }
.filter-menu { position: static; }
.filter-menu > summary { list-style: none; }
.filter-menu > summary::-webkit-details-marker { display: none; }
.filter-menu[open] > summary { border-color: var(--accent); }
.filter-panel { position: absolute; top: calc(100% - 4px); right: 16px; z-index: 20; width: 296px; max-width: calc(100vw - 32px); padding: 16px; border: 1px solid var(--line); border-radius: 8px; background: white; box-shadow: 0 8px 24px #17181c1a; }
.form-field { display: grid; gap: 4px; margin-bottom: 12px; font-size: 12px; }
.form-field label { font-weight: 550; }
.form-field :is(input:not([type="checkbox"]):not([type="radio"]), select, textarea) { width: 100%; min-width: 0; min-height: 32px; padding: 6px 8px; border: 1px solid #dedfe3; border-radius: 4px; background: white; }
.form-field :is(input[type="checkbox"], input[type="radio"]) { accent-color: var(--accent); }
.filter-actions { display: flex; justify-content: flex-end; gap: 8px; padding-top: 12px; border-top: 1px solid var(--line); }
.active-filters { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; padding: 0 16px 12px; }
.active-filters:empty { display: none; }
.filter-chip { display: inline-flex; align-items: center; gap: 6px; padding: 3px 8px; border: 1px solid var(--line); border-radius: 4px; background: var(--surface); color: #4e525a; font-size: 11px; }
.filter-chip button { display: inline-flex; padding: 0; border: 0; color: inherit; }
.sort-note { margin-left: auto; font-size: 11px; }
.table-scroll { width: 100%; min-width: 0; max-height: 65vh; overflow: auto; }
.records-table thead th { position: sticky; top: 0; z-index: 1; }
.records-table { width: 100%; table-layout: fixed; border-collapse: collapse; text-align: left; }
.records-table caption { padding: 8px 16px; text-align: left; font-size: 11px; color: var(--muted); }
.records-table th { padding: 9px 12px; border-block: 1px solid var(--line); background: var(--surface); color: var(--muted); font-size: 11px; font-weight: 550; }
.records-table th:first-child { width: 30%; padding-left: 16px; }
.records-table th:nth-child(2) { width: 14%; }
.records-table th:nth-child(3) { width: 10%; }
.records-table th:nth-child(4) { width: 12%; }
.records-table th:nth-child(5) { width: 16%; }
.records-table th:nth-child(6) { width: 14%; }
.records-table th:last-child { width: 4%; text-align: right; padding-right: 16px; }
.records-table td { height: 68px; padding: 10px 12px; border-bottom: 1px solid var(--line); vertical-align: middle; overflow-wrap: anywhere; }
.records-table tr:last-child td { border-bottom: 0; }
.record-row:hover { background: #fcfcfd; }
.record-row:focus-within { background: #fafafa; }
.records-table .identity-cell { padding-left: 16px; }
.record-identity { display: flex; align-items: center; gap: 10px; min-width: 0; }
.record-glyph { display: inline-flex; justify-content: center; align-items: center; width: 32px; height: 36px; flex: 0 0 32px; border: 1px solid var(--line); border-radius: 4px; color: #777c85; background: white; }
.record-identity > :not(.record-glyph) { min-width: 0; }
.record-name { color: var(--ink); font-size: 13px; font-weight: 600; overflow-wrap: anywhere; text-decoration: none; }
a.record-name:hover, .record-name a:hover { color: var(--accent-hover); text-decoration: underline; }
.record-name a { color: inherit; text-decoration: none; }
.record-meta { display: block; margin-top: 2px; font-size: 11px; }
.source-tag { display: inline-block; padding: 0 4px; border: 1px solid var(--line); border-radius: 3px; color: var(--muted); font-size: 10px; vertical-align: middle; }
.nav-item > span:not(.nav-count) { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.date-cell, .duration-cell { font-size: 12px; }
.cell-sub { display: block; font-size: 11px; margin-top: 2px; }
.status-cell { font-size: 11px; }
.open-cell { text-align: right; padding-right: 16px !important; }
.open-cell a:not(.icon-button) { font-size: 12px; }
.badge { display: inline-flex; align-items: center; gap: 5px; max-width: 100%; padding: 2px 6px; border-radius: 4px; font-size: 11px; line-height: 16px; font-weight: 550; overflow-wrap: anywhere; }
.badge.success { background: var(--green-bg); color: var(--green); }
.badge.warning { background: var(--amber-bg); color: var(--amber); }
.badge.danger { background: var(--red-bg); color: var(--red); }
.badge.info, .badge.neutral { background: #f0f1f3; color: #5a5e67; }
.badge-dot { width: 5px; height: 5px; border-radius: 50%; flex-shrink: 0; background: currentColor; }
.row-diagnostics { margin-top: 3px; font-size: 10px; color: var(--muted); }
.row-warning, .warning { color: var(--amber); }
.pagination { display: flex; align-items: center; flex-wrap: wrap; justify-content: space-between; gap: 12px; padding: 12px 16px; border-top: 1px solid var(--line); }
.pagination nav { display: flex; align-items: center; gap: 4px; }
.page-link { display: inline-flex; justify-content: center; align-items: center; min-width: 28px; min-height: 28px; padding: 4px 8px; border: 1px solid transparent; border-radius: 4px; color: var(--muted); text-decoration: none; font-size: 12px; }
.page-link:hover { border-color: var(--line); color: var(--ink); }
.page-link[aria-current]:not([aria-current="false"]) { border-color: var(--line); background: var(--surface); color: var(--ink); font-weight: 600; }
.results-caption { padding: 0 16px 10px; font-size: 11px; }
.empty-state { padding: 32px 16px; text-align: center; color: var(--muted); }
.empty-state h2 { margin: 8px 0 4px; color: var(--ink); }
.empty-state .button { margin-top: 12px; }
.empty-icon { display: inline-flex; padding: 8px; border: 1px solid var(--line); border-radius: 6px; }
.notice { display: block; padding: 10px 12px; margin: 12px 0; border: 1px solid var(--line); border-radius: var(--radius); background: var(--surface); font-size: 12px; overflow-wrap: anywhere; }
.notice.warning { background: var(--amber-bg); border-color: #eedcb4; color: #80570e; }
.service-details { margin-top: 16px; border-top: 1px solid var(--line); padding-top: 12px; color: var(--muted); font-size: 12px; }
.service-details summary, .technical summary { width: fit-content; font-weight: 550; color: #4e525a; text-decoration: underline; text-underline-offset: 3px; }
.service-details[open] summary, .technical[open] summary { margin-bottom: 12px; }
.project-summary { display: flex; justify-content: space-between; flex-wrap: wrap; gap: 8px 16px; padding: 12px 0; font-size: 12px; }
.project-classes { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; }
.footer { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-top: 24px; padding-top: 12px; border-top: 1px solid var(--line); color: var(--muted); font-size: 11px; }
.detail-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 16px; overflow-wrap: anywhere; }
.detail-header > :first-child { min-width: 0; }
.detail-meta-line { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 12px; margin-top: 8px; color: var(--muted); font-size: 12px; }
.status-strip { display: flex; flex-wrap: wrap; gap: 12px 24px; padding: 12px 0; border-block: 1px solid var(--line); }
.status-item { display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--muted); }
.section-nav { display: flex; gap: 24px; max-width: 100%; overflow-x: auto; padding: 0 2px; margin: 8px 0 20px; border-bottom: 1px solid var(--line); }
.section-nav a { flex: 0 0 auto; padding: 12px 0 10px; border-bottom: 2px solid transparent; color: var(--muted); text-decoration: none; font-size: 12px; }
.section-nav a:hover { color: var(--ink); }
.section-nav a[aria-current]:not([aria-current="false"]) { border-bottom-color: var(--accent); color: var(--ink); }
.detail-layout { display: grid; grid-template-columns: minmax(0, 1fr) 300px; align-items: start; gap: 24px; }
.detail-main, .detail-aside { min-width: 0; }
.detail-aside { border-left: 1px solid var(--line); padding-left: 24px; }
.detail-section { min-width: 0; margin-bottom: 24px; scroll-margin-top: 16px; }
.section-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
.section-heading > span, .section-heading > small { color: var(--muted); font-size: 11px; }
.video-panel { width: 100%; overflow: hidden; border-radius: var(--radius); background: #111214; }
.video-panel video { display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: contain; background: #111214; border: 0; }
.video-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; min-height: 144px; aspect-ratio: 16 / 9; padding: 24px; border: 1px dashed #d8dade; border-radius: var(--radius); background: var(--surface); color: var(--muted); text-align: center; font-size: 12px; }
.video-panel:has(.video-empty) { background: transparent; }
.video-empty strong { color: #4e525a; font-weight: 550; }
.video-caption { margin: 8px 0 20px; font-size: 11px; color: var(--muted); }
.video-caption .icon { width: 13px; height: 13px; margin-right: 4px; }
.metadata, .answers, .questionnaire dl, dl.questionnaire { display: grid; grid-template-columns: minmax(100px, 36%) minmax(0, 1fr); gap: 0 16px; font-size: 12px; }
:is(.metadata, .answers, .questionnaire dl, dl.questionnaire) > dt { margin: 0; padding: 8px 0; border-bottom: 1px solid var(--line); color: var(--muted); overflow-wrap: anywhere; }
:is(.metadata, .answers, .questionnaire dl, dl.questionnaire) > dd { min-width: 0; margin: 0; padding: 8px 0; border-bottom: 1px solid var(--line); overflow-wrap: anywhere; }
.detail-aside .metadata { grid-template-columns: minmax(80px, 42%) minmax(0, 1fr); gap: 0 12px; }
.file-list { list-style: none; margin: 0; padding: 0; border-block: 1px solid var(--line); }
.file-item { display: grid; grid-template-columns: 32px minmax(0, 1fr) auto auto 32px; align-items: center; gap: 8px 12px; min-width: 0; padding: 12px 0; border-bottom: 1px solid var(--line); }
.file-item:last-child { border-bottom: 0; }
.file-icon { display: inline-flex; align-items: center; justify-content: center; width: 32px; height: 36px; flex-shrink: 0; border: 1px solid var(--line); border-radius: 4px; color: var(--muted); }
.file-info { flex: 1; min-width: 0; }
.file-name { display: block; font-size: 12px; font-weight: 550; overflow-wrap: anywhere; }
.file-kind, .file-size { font-size: 11px; color: var(--muted); }
.file-kind + .file-size { margin-left: 8px; }
.file-state { flex-shrink: 0; font-size: 11px; color: var(--muted); }
.file-action { flex-shrink: 0; font-size: 12px; }
.file-error { grid-column: 2 / -1; color: var(--red); font-size: 11px; overflow-wrap: anywhere; }
.questionnaire { min-width: 0; }
.technical { padding-top: 12px; border-top: 1px solid var(--line); font-size: 12px; }
.technical pre { max-width: 100%; overflow-x: auto; padding: 12px; border: 1px solid var(--line); border-radius: 4px; background: var(--surface); font-size: 11px; }
.transfer-note, .connection-note { margin-top: 8px; font-size: 11px; color: var(--muted); overflow-wrap: anywhere; }
.progress { display: block; width: 100%; height: 4px; margin-top: 8px; overflow: hidden; border: 0; border-radius: 2px; background: #e9eaed; accent-color: #727781; }
.progress::-webkit-progress-bar { background: #e9eaed; }
.progress::-webkit-progress-value { background: #727781; }
.progress::-moz-progress-bar { background: #727781; }
.progress > span { display: block; height: 100%; background: #727781; }
.media-flags { display: inline-flex; align-items: center; gap: 5px; margin-left: 6px; vertical-align: middle; }
.media-flags .icon { width: 12px; height: 12px; }
.media-flag.available { color: #686e78; }
.media-flag.missing { color: #b7bbc2; }
.file-count { text-decoration: none; }
.file-count:hover { text-decoration: underline; }
@media (max-width: 1000px) {
  .app-layout { display: block; }
  .sidebar { display: none; }
  .workspace { width: 100%; }
}
@media (min-width: 761px) and (max-width: 1100px) {
  .page-content { padding: 24px; }
  .topbar { padding-inline: 24px; }
  .metric { padding-inline: 12px; }
  .records-table :is(th, td) { padding-inline: 8px; }
  .record-glyph { display: none; }
  .badge { padding-inline: 4px; }
  .detail-layout { grid-template-columns: minmax(0, 1fr) 260px; gap: 16px; }
  .detail-aside { padding-left: 16px; }
}
@media (max-width: 760px) {
  .app-layout { display: block; }
  .sidebar { display: none; }
  .workspace { width: 100%; }
  .topbar { min-height: 56px; padding: 8px 16px; gap: 8px; }
  .topbar-actions { gap: 6px; }
  .topbar-actions > .muted, .tools-label { display: none; }
  .breadcrumb { font-size: 11px; gap: 4px; }
  .page-content { padding: 20px 16px 24px; }
  .page-heading { gap: 12px; margin-bottom: 16px; }
  h1 { font-size: 25px; }
  .heading-actions { justify-content: flex-end; }
  .heading-actions .button { white-space: normal; text-align: center; }
  .subtitle { font-size: 11px; }
  .metrics { padding: 12px 0; margin-bottom: 8px; gap: 12px 0; grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .metric { padding-inline: 12px; }
  .metric:nth-child(4) { border-left: 0; padding-left: 0; }
  .metric > :is(dd, strong, .metric-value) { font-size: 21px; }
  .metric-note { font-size: 10px; }
  .summary-notes { margin-bottom: 16px; gap: 4px 12px; }
  .tabs { gap: 20px; padding-inline: 12px; }
  .toolbar { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 8px; padding: 12px; }
  .search-field { grid-column: 1 / -1; max-width: none; }
  .account-filter { grid-column: 1 / -1; max-width: none; width: 100%; }
  .filter-menu > summary { width: 100%; }
  .toolbar-actions { grid-column: 1 / -1; }
  .toolbar-actions .button { flex: 1; }
  .sort-note { display: none; }
  .filter-panel { right: 12px; max-width: calc(100% - 24px); }
  .active-filters { padding-inline: 12px; }
  .table-scroll { overflow: visible; max-height: none; }
  .records-table, .records-table tbody { display: block; width: 100%; }
  .records-table colgroup { display: none; }
  .records-table thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
  .records-table .record-row { position: relative; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px 12px; padding: 12px; border-top: 1px solid var(--line); }
  .records-table .record-row td { display: block; width: auto; min-width: 0; height: auto; padding: 0; border: 0; }
  .records-table .record-row td.identity-cell { grid-column: 1 / -1; padding: 0 40px 0 0; }
  .record-identity { gap: 8px; }
  .record-glyph { width: 28px; height: 32px; flex-basis: 28px; }
  .record-meta { font-size: 10px; margin-top: 0; }
  .record-name { font-size: 12px; }
  .records-table .record-row td.date-cell { grid-column: span 2; display: flex; align-items: baseline; gap: 6px; flex-wrap: wrap; font-size: 11px; }
  .date-cell .cell-sub { display: inline; margin: 0; }
  .records-table .record-row td.duration-cell { grid-column: 3; font-size: 11px; }
  .duration-cell .cell-sub { display: inline; margin-left: 4px; font-size: 10px; }
  .records-table .record-row td.status-cell { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; }
  .status-cell::before { content: attr(data-label); color: var(--muted); font-size: 10px; line-height: 1.3; }
  .status-cell .cell-sub { font-size: 10px; margin-top: 0; }
  .records-table .record-row td.open-cell { position: absolute; top: 12px; right: 12px; padding: 0 !important; }
  .badge { font-size: 10px; padding: 1px 5px; }
  .row-diagnostics { font-size: 10px; margin-top: 0; }
  .pagination { padding: 12px; gap: 8px; }
  .results-caption { font-size: 10px; }
  .panel-head { padding-inline: 12px; }
  .detail-header { flex-wrap: wrap; gap: 12px; }
  .detail-header .heading-actions { justify-content: flex-start; }
  .detail-meta-line { font-size: 11px; gap: 4px 8px; }
  .status-strip { gap: 8px 16px; }
  .status-item { gap: 6px; font-size: 10px; }
  .section-nav { gap: 20px; margin-bottom: 16px; }
  .detail-layout { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .detail-aside { border-left: 0; padding-left: 0; padding-top: 16px; border-top: 1px solid var(--line); }
  .detail-section { margin-bottom: 20px; }
  .file-item { grid-template-columns: 32px minmax(0, 1fr) 32px; gap: 8px; }
  .file-info { grid-column: 2; grid-row: 1; }
  .file-state { grid-column: 2; grid-row: 2; }
  .file-size { grid-column: 2; grid-row: 3; }
  .file-action { grid-column: 3; grid-row: 1; }
  .file-error { grid-column: 2 / -1; }
  .file-icon { grid-column: 1; grid-row: 1; }
  .metadata, .answers, .questionnaire dl, dl.questionnaire { grid-template-columns: minmax(80px, 38%) minmax(0, 1fr); gap: 0 12px; }
  .footer { margin-top: 20px; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { scroll-behavior: auto !important; animation: none !important; transition: none !important; }
}
@media (forced-colors: active) {
  .button, .badge, .filter-chip, .page-link[aria-current] { border: 1px solid ButtonText; }
  .badge-dot, .progress > span { background: CanvasText; }
  .nav-item.active { outline: 1px solid Highlight; }
}

.sidebar .account-navigation { flex: 1 1 auto; min-height: 80px; overflow-y: auto; }
.sidebar-foot summary { font-size: 12px; color: var(--muted); }
.sidebar-foot .nav-item { padding-inline: 0; font-size: 11px; }
.sidebar > .sidebar-section:not(.account-navigation), .sidebar-brand, .sidebar-foot { flex-shrink: 0; }
"""


def _catalog_shell(data, title, content, account='', params=None) -> str:
    escape = _catalog_escape
    params = dict(params or {})
    records = data.get('records', [])
    accounts = {}
    counts = {'': len(records), '__unassigned__': 0}
    for record in records:
        account_id = record.get('account_id')
        if account_id is None:
            counts['__unassigned__'] += 1
        else:
            key = str(account_id)
            accounts[key] = record.get('account_name') or 'Аккаунт без имени'
            counts[key] = counts.get(key, 0) + 1
    account_items = [('', 'Все аккаунты'), ('__unassigned__', 'Без аккаунта')]
    account_items += sorted(accounts.items(), key=lambda item: str(item[1]).casefold())
    account_links = ''.join(
        '<a class="nav-item' + (' active' if key and str(account) == key else '') + '" href="' +
        escape(_catalog_url(params, account=key, page=1)) + '" title="' + escape(name) + '"' +
        (' aria-current="page"' if key and str(account) == key else '') + '>' +
        _catalog_icon('folder') + '<span>' + escape(name) + '</span><span class="nav-count">' +
        escape(counts[key]) + '</span></a>' for key, name in account_items)
    catalog_url = _catalog_url(params, account='', status='all', page=1)
    project_url = '/projects/'
    for category in data.get('categories', {}).values():
        if category.get('project_id') is not None:
            project_url = '/projects/' + _catalog_segment(category['project_id']) + '/data'
            break
    is_catalog = title in ('Записи', 'Каталог записей')
    breadcrumb = '<a href="' + escape(catalog_url) + '">Записи</a>'
    if not is_catalog:
        breadcrumb += '<span aria-hidden="true">/</span><span aria-current="page">' + escape(title) + '</span>'
    tools = ''.join('<a class="nav-item" href="' + escape(url) + '">' +
                    _catalog_icon(icon) + '<span>' + label + '</span></a>'
                    for url, icon, label in (
                        ('/dashboard/data', 'file', 'Данные JSON'),
                        ('/db/woona/', 'folder', 'База Woona'),
                        ('/db/labels/', 'folder', 'База разметки'),
                        ('/files/', 'file', 'Файлы')))
    return (
        '<!doctype html><html lang="ru"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>' + escape(title) + ' · Woona</title><style>' + _CATALOG_WORKSPACE_CSS +
        '</style></head><body><a class="skip" href="#main">К содержимому</a>'
        '<div class="app-layout"><aside class="sidebar" aria-label="Навигация проекта">'
        '<a class="sidebar-brand" href="' + escape(catalog_url) + '">'
        '<span class="brand-mark" aria-hidden="true">W</span><span class="brand-name">Woona</span></a>'
        '<nav class="sidebar-section" aria-label="Данные проекта"><span class="nav-label">Данные проекта</span>'
        '<a class="nav-item' + (' active' if is_catalog and not account else '') + '" href="' +
        escape(catalog_url) + '">' + _catalog_icon('list') + '<span>Все записи</span>'
        '<span class="nav-count">' + escape(len(records)) + '</span></a>'
        '<a class="nav-item" href="' + escape(project_url) + '">' + _catalog_icon('activity') +
        '<span>Разметка</span></a></nav>'
        '<nav class="sidebar-section account-navigation" aria-label="Аккаунты">'
        '<span class="nav-label">Аккаунты</span>' + account_links + '</nav>'
        '<div class="sidebar-foot"><p class="connection-note">Доступ через Label Studio</p></div></aside>'
        '<div class="workspace"><header class="topbar"><nav class="breadcrumb" aria-label="Навигационная цепочка">' +
        breadcrumb + '</nav><div class="topbar-actions"><span class="muted">UTC</span>'
        '<details class="tools-menu"><summary class="button secondary" aria-label="Технические инструменты" title="Технические инструменты">' +
        _catalog_icon('list') + '<span class="tools-label">Инструменты</span></summary><nav aria-label="Технические инструменты">' + tools + '</nav></details>'
        '<a class="button secondary" href="' + escape(project_url) + '">Label Studio ' +
        _catalog_icon('external') + '</a></div></header><main class="page-content" id="main">' +
        content + '<footer class="footer"><span>Обновлено: ' + escape(_catalog_time(data.get('updated_at'))) +
        '</span><span>Время записей — UTC · Обновление вручную</span></footer>'
        '</main></div></div></body></html>')

def render(data: dict, query: str, status: str = 'all', ble: str = 'all', page: int = 1,
           account: str = '', date_from: str = '', date_to: str = '') -> str:
    escape = _catalog_escape
    available = data.get('label_service', {}).get('available', True)

    def matches(record, selected_status=status):
        haystack = ' '.join(str(record.get(key) or '') for key in
                            ('dog', 'dog_id', 'account_name', 'account_id', 'source_id', 'recording_id', 'origin', 'session_label'))
        if query.casefold() not in haystack.casefold():
            return False
        if account == '__unassigned__' and record.get('account_id') is not None:
            return False
        if account and account != '__unassigned__' and str(record.get('account_id') or '') != account:
            return False
        day = _catalog_day(record)
        if (date_from and (not day or day < date_from)) or (date_to and (not day or day > date_to)):
            return False
        if ble != 'all' and bool(record.get('ble')) != (ble == 'present'):
            return False
        if selected_status == 'upload_problem' and not _catalog_upload_problem(record):
            return False
        if selected_status == 'no_video' and record.get('video'):
            return False
        if selected_status == 'incomplete' and record.get('video') and record.get('ble'):
            return False
        if selected_status == 'awaiting_annotation' and not (available and record.get('eligible') and not record.get('annotated_any')):
            return False
        if selected_status == 'ready' and not (
                available and record.get('eligible') and record.get('video') and record.get('ble')
                and not record.get('annotated_any') and all(record.get('tasks', {}).get(kind) for kind in VIDEO_KINDS)):
            return False
        if selected_status == 'in_progress' and not (available and record.get('annotated_any') and not record.get('annotated_all')):
            return False
        if selected_status == 'complete' and not (available and record.get('annotated_all')):
            return False
        return True

    filtered = [r for r in data['records'] if matches(r)]
    label_filter_unavailable = not available and status in ('ready', 'in_progress', 'complete', 'awaiting_annotation')
    live_durations = [duration for r in filtered if r.get('source') == 'live'
                      and (duration := _catalog_duration(r)) is not None]
    unknown_duration = sum(_catalog_duration(r) is None for r in filtered)
    replay = sum(r.get('source') == 'replay' for r in filtered)
    stats = [('Записи в выборке', len(filtered)), ('Часы сессий съёмки', f'{sum(live_durations) / 3600:.2f}'),
             ('Проблемы передачи', sum(_catalog_upload_problem(r) for r in filtered)),
             ('Передано полностью', sum(r.get('server_status', {}).get('transfer', {}).get('status') == 'verified' for r in filtered)),
             ('Есть разметка', sum(bool(r.get('annotated_any')) for r in filtered) if available else 'Недоступно')]
    if label_filter_unavailable:
        stats = [(name, 'Недоступно' if index in (0, 4) else '—') for index, (name, _) in enumerate(stats)]
    metrics = '<section aria-label="Сводка выбранных записей" class="metrics">' + ''.join(
        '<div class="metric"><span>' + name + '</span><strong' + (' class="metric-text"' if value == 'Недоступно' else '') + '>' + escape(value) + '</strong></div>'
        for name, value in stats) + '</section>'
    calculation_note = ('Выборку по статусу разметки нельзя определить, пока Label Studio недоступен. '
                        'Снимите фильтр разметки, чтобы посмотреть записи, видео и файлы.' if label_filter_unavailable else
                        f'Сводка только по выбранным записям. Часы — длительность по метаданным, не оценка качества видео или сигнала. '
                        f'Replay: {replay} (исключены из часов); длительность неизвестна: {unknown_duration}. '
                        'Неизвестный источник также исключён из часов. Есть разметка ≠ размечены все кадры.')
    metrics += ('<details class="summary-notes"><summary>Как рассчитана сводка</summary><p>' +
                calculation_note + '</p></details>')

    per_page = 25
    page_count = max(1, (len(filtered) + per_page - 1) // per_page)
    page = max(1, min(page, page_count))
    params = dict(q=query, status=status, ble=ble, account=account, date_from=date_from, date_to=date_to, page=page)
    statuses = [('all', 'Все записи'), ('upload_problem', 'Проблемы передачи'), ('no_video', 'Без видео'),
                ('awaiting_annotation', 'Ожидают разметки'), ('complete', 'Размечены')]
    legacy = [('ready', 'Готовы к разметке'), ('in_progress', 'Разметка в процессе'), ('incomplete', 'Без пары видео + BLE')]
    options = lambda items, current: ''.join(
        '<option value="' + escape(value) + '"' + (' selected' if value == current else '') + '>' +
        escape(name) + '</option>' for value, name in items)
    accounts = {}
    for record in data['records']:
        if record.get('account_id') is not None:
            accounts[str(record['account_id'])] = record.get('account_name') or 'Аккаунт без имени'
    account_items = [('', 'Все аккаунты'), ('__unassigned__', 'Без аккаунта')] + sorted(
        accounts.items(), key=lambda pair: str(pair[1]).casefold())
    if account and account not in dict(account_items):
        account_items.append((account, account))

    tabs = []
    for value, name in statuses:
        count = ('—' if not available and value in ('awaiting_annotation', 'complete') else
                 str(sum(matches(record, value) for record in data['records'])))
        unavailable = ' · недоступно' if count == '—' else ''
        tabs.append('<a href="' + escape(_catalog_url(params, status=value, page=1)) + '"' +
                    (' aria-current="page"' if value == status else '') + '>' + escape(name) +
                    ' <span class="tab-count">' + count + '</span>' + unavailable + '</a>')
    quick = '<nav class="tabs" aria-label="Быстрые фильтры">' + ''.join(tabs) + '</nav>'
    filters = ('<form class="toolbar" method="get" action="/dashboard#data-manager" aria-label="Фильтры записей">'
               '<label class="search-field"><span class="sr-only">Поиск</span>' + _catalog_icon('search') +
               '<input type="search" name="q" maxlength="100" placeholder="Кличка, аккаунт или UUID" value="' + escape(query) + '"></label>'
               '<label class="sr-only" for="catalog-account">Аккаунт</label><select class="account-filter" id="catalog-account" name="account">' + options(account_items, account) + '</select>'
               '<details class="filter-menu" name="catalog-filter"><summary class="button secondary">' + _catalog_icon('calendar') + 'Даты</summary><div class="filter-panel">'
               '<label class="form-field">С даты (UTC)<input type="date" name="date_from" value="' + escape(date_from) + '"></label>'
               '<label class="form-field">По дату включительно (UTC)<input type="date" name="date_to" value="' + escape(date_to) + '"></label>'
               '<button class="button primary" type="submit">Применить период</button></div></details>'
               '<details class="filter-menu" name="catalog-filter"><summary class="button secondary">' + _catalog_icon('filter') + 'Ещё фильтры</summary><div class="filter-panel">'
               '<label class="form-field">Статус<select name="status">' + options(statuses + legacy, status) + '</select></label>'
               '<label class="form-field">BLE<select name="ble">' + options([('all', 'Все'), ('present', 'Есть'), ('absent', 'Нет')], ble) + '</select></label>'
               '<button class="button primary" type="submit">Применить фильтры</button></div></details>'
               '<div class="toolbar-actions"><button class="button primary" type="submit">Применить</button>'
               '<a class="button secondary" href="/dashboard#data-manager">Сбросить</a></div><span class="sort-note">Сначала новые</span></form>')
    chips = []
    active = [('q', query, 'Поиск: ' + query, ''),
              ('account', account, 'Аккаунт: ' + str(dict(account_items).get(account, account)), ''),
              ('date_from', date_from, 'С: ' + date_from, ''), ('date_to', date_to, 'По: ' + date_to, ''),
              ('status', status if status != 'all' else '', dict(statuses + legacy).get(status, status), 'all'),
              ('ble', ble if ble != 'all' else '', 'BLE: ' + ('есть' if ble == 'present' else 'нет'), 'all')]
    for key, value, label, cleared in active:
        if value:
            chips.append('<a class="filter-chip" href="' + escape(_catalog_url(params, **{key: cleared, 'page': 1})) +
                         '" aria-label="' + escape('Убрать фильтр: ' + label) + '">' + escape(label) +
                         '<span aria-hidden="true"> ×</span></a>')
    active_filters = '<div class="active-filters" aria-label="Активные фильтры">' + ''.join(chips) + '</div>' if chips else ''

    rows = []
    for record in filtered[(page - 1) * per_page:page * per_page]:
        identity = record.get('recording_id')
        detail_url = ('/dashboard/recordings/' + _catalog_segment(identity) + '?' +
                      urlencode({'back': _catalog_url(params)})) if identity else None
        dog = str(record.get('dog') or 'Собака не указана')
        heading = ('<a class="record-name" href="' + escape(detail_url) + '">' + escape(dog) + '</a>' if detail_url else
                   '<span class="record-name">' + escape(dog) + '</span>')
        if record.get('source') == 'replay':
            heading += ' <span class="source-tag" title="Replay — повторное воспроизведение, не новая съёмка">Повтор</span>'
        if record.get('session_kind') == 'heart':
            heading += ' <span class="source-tag" title="Сессия сердцебиения">ЧСС</span>'
        flags = ''.join('<span class="media-flag ' + ('available' if record.get(key) else 'missing') + '">' +
                        _catalog_icon(icon) + '<span class="sr-only">' + label + ': ' +
                        ('есть' if record.get(key) else 'нет') + '</span></span>'
                        for key, icon, label in [('video', 'film', 'Видео'), ('ble', 'activity', 'BLE')])
        if record.get('profile'):
            flags += '<span class="media-flag" title="Анкеты доступны">' + _catalog_icon('file') + '<span class="sr-only">Анкеты доступны</span></span>'
        states = _catalog_states(data, record)
        files = record.get('files', [])
        file_count = str(sum(bool(item.get('available')) for item in files)) + '/' + str(len(files)) + ' файлов'
        errors = [str(item.get('errorCode') or '') for item in record.get('server_status', {}).get('artifacts', [])]
        errors += [str(item.get('error_code') or '') for item in files]
        file_hint = 'Доступные файлы на сервере. ' + '; '.join(error for error in errors if error)
        file_link = ('<a class="file-count cell-sub" title="' + escape(file_hint) + '" href="' + escape(detail_url + '#files') + '">' + file_count + '</a>' if detail_url else
                     '<span class="file-count cell-sub" title="' + escape(file_hint) + '">' + file_count + '</span>')
        started_text = _catalog_time(record.get('started_at') or record.get('date'))
        date_parts = started_text.removesuffix(' UTC').split(' ', 1)
        date_html = escape(date_parts[0]) + ('<span class="cell-sub">' + escape(date_parts[1]) + '</span>' if len(date_parts) > 1 else '')
        duration = escape(_catalog_duration_text(record)) if _catalog_duration(record) is not None else '<span title="Длительность неизвестна">—</span>'
        open_link = ('<a class="icon-button" href="' + escape(detail_url) + '" aria-label="' +
                     escape('Открыть запись ' + dog) + '" title="Открыть запись">' + _catalog_icon('chevron') + '</a>') if detail_url else ''
        rows.append('<tr class="record-row" data-record-id="' + escape(identity or record.get('source_id') or '') + '">'
                    '<td class="identity-cell" data-label="Собака / сессия"><div class="record-identity"><span class="record-glyph">' +
                    _catalog_icon('paw' if record.get('dog') else 'film') + '</span><div>' + heading + '<div class="record-meta">' +
                    escape(record.get('account_name') or 'Без аккаунта') + ' · ' + escape(record.get('session_label') or 'Сессия без названия') +
                    '<span class="media-flags">' + flags + '</span></div></div></div></td>'
                    '<td class="date-cell" data-label="Дата (UTC)" title="' + escape(started_text) + '">' + date_html + '</td>'
                    '<td class="duration-cell" data-label="Длительность">' + duration + '</td>'
                    '<td class="status-cell" data-label="Съёмка">' + states['capture'] + '</td>'
                    '<td class="status-cell" data-label="Передача">' + states['transfer'] + file_link + '</td>'
                    '<td class="status-cell" data-label="Разметка">' + states['label'] + '</td>'
                    '<td class="open-cell">' + open_link + '</td></tr>')
    table = ('<div class="table-scroll"><table class="records-table"><caption class="sr-only">'
             'Записи собак и сессий: дата UTC, длительность, состояния съёмки, передачи файлов и разметки</caption>'
             '<thead><tr>' + ''.join('<th scope="col">' + label + '</th>' for label in
                                    ['Собака / сессия', 'Дата (UTC)', 'Длительность', 'Съёмка', 'Передача', 'Разметка',
                                     '<span class="sr-only">Открыть запись</span>']) +
             '</tr></thead><tbody>' + ''.join(rows) + '</tbody></table></div>')
    if not filtered:
        recovery = '<a class="button secondary" href="/dashboard#data-manager">Сбросить фильтры</a>'
        if label_filter_unavailable:
            message = '<h2>Не удалось проверить разметку</h2><p>Label Studio недоступен. Это не означает, что задач или разметки нет.</p>'
            recovery = '<a class="button secondary" href="' + escape(_catalog_url(params, status='all', page=1)) + '">Показать все записи</a>'
        elif data['records']:
            message = '<h2>Записей не найдено</h2><p>Измените запрос или сбросьте фильтры.</p>'
        else:
            message = '<h2>Записей пока нет</h2><p>Здесь появятся сессии, отправленные с устройств.</p>'
            recovery = '<a class="button secondary" href="">Обновить вручную</a>'
        table = '<div class="empty-state"><span class="empty-icon">' + _catalog_icon('search' if data['records'] else 'folder') + '</span>' + message + recovery + '</div>'
    first = (page - 1) * per_page + 1 if filtered else 0
    page_links = []
    if page > 1:
        page_links.append('<a class="page-link" rel="prev" href="' + escape(_catalog_url(params, page=page - 1)) + '">' +
                          _catalog_icon('arrow-left') + 'Назад</a>')
    for number in sorted({1, page_count, *range(max(1, page - 2), min(page_count, page + 2) + 1)}):
        page_links.append('<a class="page-link" href="' + escape(_catalog_url(params, page=number)) + '"' +
                          (' aria-current="page"' if number == page else '') + '>' + str(number) + '</a>')
    if page < page_count:
        page_links.append('<a class="page-link" rel="next" href="' + escape(_catalog_url(params, page=page + 1)) + '">Далее' +
                          _catalog_icon('arrow-right') + '</a>')
    pagination = (f'<div class="pagination"><span>Показано {first}–{min(page * per_page, len(filtered))} из {len(filtered)}</span>'
                  '<nav aria-label="Страницы каталога">' + ''.join(page_links) + '</nav></div>')
    result_caption = ('Выборка по разметке сейчас недоступна' if label_filter_unavailable else
                      f'Найдено {len(filtered)} из {len(data["records"])} записей')
    content = ('<div class="page-heading"><div class="heading-copy"><h1>Записи</h1>'
               '<p class="subtitle">Видео, анкеты и исходные файлы</p></div>'
               '<a class="button secondary" href="">' + _catalog_icon('refresh') + 'Обновить вручную</a></div>' + metrics +
               '<section class="panel" id="data-manager">' + quick + filters + active_filters +
               '<p class="results-caption">' + result_caption + '</p>' + table + ('' if label_filter_unavailable else pagination) +
               '</section>' + _catalog_diagnostics(data) + _catalog_projects(data))
    return _catalog_shell(data, 'Записи', content, account=account, params=params)


def _catalog_answers(value, labels) -> str:
    escape = _catalog_escape
    if isinstance(value, dict):
        if set(value) == {'key', 'text'} and isinstance(value.get('text'), str):
            return escape(value['text'])
        return '<dl class="answers">' + ''.join('<dt>' + escape(labels.get(key, key)) + '</dt><dd>' + _catalog_answers(item, labels) + '</dd>' for key, item in value.items()) + '</dl>' if value else '<span class="muted">Нет ответов</span>'
    if isinstance(value, list):
        return '<ul>' + ''.join('<li>' + _catalog_answers(item, labels) + '</li>' for item in value) + '</ul>' if value else '<span class="muted">Не указано</span>'
    if value is None or value == '':
        return '<span class="muted">Не указано</span>'
    if isinstance(value, bool):
        return 'Да' if value else 'Нет'
    return escape(value)


def render_record_detail(data: dict, record: dict, back: str = '/dashboard') -> str:
    from server.questionnaires import DOG_COLUMNS, SESSION_COLUMNS

    escape = _catalog_escape
    labels = dict(DOG_COLUMNS + SESSION_COLUMNS)
    labels.update({'schemaVersion': 'Версия анкеты', 'videoRequested': 'Видео запрошено',
                   'sessionKind': 'Тип сессии', 'heartQuestionnaire': 'Анкета сердцебиения',
                   'referenceBpm': 'Контрольная ЧСС', 'bpm': 'ЧСС, уд/мин', 'measuredAtUtc': 'Время измерения (UTC)',
                   'source': 'Источник', 'device': 'Устройство', 'method': 'Метод', 'notes': 'Примечания',
                   'knownHeartCondition': 'Известные заболевания сердца',
                   'knownHeartConditionDetails': 'Заболевания сердца — подробности',
                   'heartRelevantMedication': 'Препараты, влияющие на сердцебиение',
                   'heartRelevantMedicationDetails': 'Препараты — подробности',
                   'preRecordingState': 'Состояние перед записью', 'actualActivity': 'Фактическая активность',
                   'acuteHeartRateFactors': 'Факторы, влияющие на ЧСС', 'referenceMethod': 'Способ контрольного измерения',
                   'referenceArtifact': 'Контрольный файл', 'key': 'Код ответа', 'text': 'Ответ'})
    title = record.get('dog') or 'Собака не указана'
    profile = record.get('profile') or {}
    session = record.get('session_questionnaire') or {}
    videos = [item for item in record.get('files', []) if item.get('available') and
              (item.get('type') == 'video' or str(item.get('name', '')).lower().endswith('.mp4'))]
    video_html = ''.join('<video controls preload="metadata" aria-label="Видео сессии" src="' + escape(file_url(item['relative'])) + '">Ваш браузер не поддерживает видео. <a href="' + escape(file_url(item['relative'])) + '">Скачать видео</a></video>' for item in videos)
    if not videos:
        video_html = ('<div class="video-empty">' + _catalog_icon('film') + '<h2>Видео недоступно</h2>' +
                      '<p>Файл ещё не передан или недоступен на сервере.</p><a href="#files">Проверить файлы записи</a></div>')
    states = _catalog_states(data, record)
    files = record.get('files', [])
    file_count = sum(bool(item.get('available')) for item in files)
    source_name = {'live': 'Съёмка', 'replay': 'Повторное воспроизведение (replay)'}.get(record.get('source') or '', 'Неизвестно')
    account_name = record.get('account_name') or 'Без аккаунта'
    duration_text = _catalog_duration_text(record)
    metadata = [('Аккаунт', account_name),
                ('Сессия', record.get('session_label') or 'Без названия'),
                ('Начало', _catalog_time(record.get('started_at') or record.get('date'))),
                ('Окончание', _catalog_time(record.get('ended_at'))),
                ('Длительность', duration_text), ('Источник', source_name),
                ('Доступные файлы', f'{file_count} из {len(files)}')]
    back_url = _catalog_back_url(back)
    content = ('<a class="detail-meta-line" href="' + escape(back_url) + '">' + _catalog_icon('arrow-left') +
               'К выборке записей</a><div class="page-heading detail-header"><div class="heading-copy"><h1>' + escape(title) +
               '</h1><p class="subtitle">' + escape(record.get('session_label') or 'Сессия без названия') + ' · ' +
               escape(_catalog_time(record.get('started_at') or record.get('date'))) + '</p><p class="detail-context">' +
               escape(account_name) + ' · ' + escape(duration_text) + ' · ' + escape(source_name) + '</p></div>' +
               '<div class="heading-actions"><a class="button secondary" href="">' + _catalog_icon('refresh') +
               'Обновить вручную</a></div></div>')
    if not data.get('label_service', {}).get('available', True):
        content += '<aside class="notice warning" role="status">Статусы разметки недоступны. Наличие задач не проверено.</aside>'
    content += '<div class="status-strip">' + ''.join(
        '<div class="status-item"><span>' + name + '</span>' + states[key] + '</div>'
        for key, name in (('capture', 'Съёмка'), ('transfer', 'Передача на сервер'), ('label', 'Разметка'))) + '</div>'
    content += ('<nav class="section-nav" aria-label="Разделы записи"><a href="#overview">Обзор</a>' +
                '<a href="#files">Файлы <span class="tab-count">' + str(len(files)) + '</span></a>' +
                '<a href="#dog-profile">Анкета собаки</a><a href="#session-profile">Анкета сессии</a>' +
                '<a href="#technical">Техническое</a></nav>')
    content += ('<div class="detail-layout" id="overview"><div class="detail-main"><section class="video-panel" aria-label="Видео сессии">' +
                video_html + '</section><p class="video-caption">' + _catalog_icon('help') +
                'Наличие файла не подтверждает качество видео, сигнала или синхронизации.</p>' +
                '<section class="detail-section" id="files"><div class="section-heading"><h2>Файлы сессии</h2>' +
                '<span class="muted">Доступно ' + str(file_count) + ' из ' + str(len(files)) + '</span></div>' +
                _catalog_files(record) + '</section></div><aside class="detail-aside"><section class="detail-section">' +
                '<h2>О записи</h2><dl class="metadata">' + ''.join('<dt>' + name + '</dt><dd>' + escape(value) + '</dd>'
                    for name, value in metadata) + '</dl>' + _catalog_actions(data, record) +
                '<details class="transfer-note"' + (' open' if _catalog_upload_problem(record) else '') +
                '><summary>Диагностика передачи</summary>' + _catalog_transfer(record) +
                '<p>' + _catalog_capture(record) + '</p><p>' + escape(_catalog_label_state(data, record)) + '</p></details>' +
                '<details class="summary-notes"><summary>О привязке аккаунта</summary>' +
                '<p>Аккаунт — текущая привязка карточки собаки, не подтверждение исторического отправителя записи.</p></details>' +
                '</section></aside></div><section class="detail-section questionnaire" id="dog-profile">' +
                '<div class="section-heading"><h2>Анкета собаки на момент записи</h2></div>' +
                '<p class="muted">Снимок профиля для этой записи, не текущая анкета собаки; текущие данные могут отличаться.</p>' +
                _catalog_answers(profile.get('answers') or {}, labels) + '</section>' +
                '<section class="detail-section questionnaire" id="session-profile"><div class="section-heading"><h2>Анкета сессии</h2></div>' +
                _catalog_answers(session.get('answers') or {}, labels) + '</section>')
    technical = {'UUID записи': record.get('recording_id'), 'UUID собаки': record.get('dog_id'),
                 'ID аккаунта': record.get('account_id'), 'ID источника': record.get('source_id'),
                 'Источник (live / replay)': record.get('source'), 'Состояние записи': record.get('capture_status'),
                 'Состояние приёма': record.get('ingest_status'), 'Серверная диагностика': record.get('server_status'),
                 'Задачи разметки': record.get('tasks'), 'Анкета собаки (JSON)': profile, 'Анкета сессии (JSON)': session}
    content += ('<section class="detail-section technical" id="technical"><details>' +
                '<summary>Технические сведения · UUID, состояния и исходные анкеты</summary><pre>' +
                escape(json.dumps(technical, ensure_ascii=False, indent=2)) + '</pre></details></section>' + _catalog_diagnostics(data))
    return _catalog_shell(data, title, content, account=record.get('account_id') or '__unassigned__')


@router.get("", response_class=HTMLResponse, dependencies=[Depends(require_label_user)])
def dashboard(q: str = Query("", max_length=100),
              status: Literal["all", "ready", "in_progress", "complete", "incomplete",
                              "upload_problem", "no_video", "awaiting_annotation"] = "all",
              ble: Literal["all", "present", "absent"] = "all", page: int = Query(1, ge=1),
              account: str = Query("", max_length=64),
              date_from: str = Query("", pattern=r"^(?:\d{4}-\d{2}-\d{2})?$"),
              date_to: str = Query("", pattern=r"^(?:\d{4}-\d{2}-\d{2})?$")):
    # HTML GET forms submit empty date inputs as empty strings, not omitted fields.
    try:
        start, end = (date.fromisoformat(value) if value else None for value in (date_from, date_to))
    except ValueError as error:
        raise HTTPException(422, "Укажите существующую дату в формате ГГГГ-ММ-ДД") from error
    if start and end and start > end:
        raise HTTPException(422, "Начало периода должно быть не позже окончания")
    return HTMLResponse(render(load_dashboard(), q, status, ble, page, account, date_from, date_to),
                        headers={"Cache-Control": "no-store"})


@router.get("/data", dependencies=[Depends(require_label_user)])
def dashboard_data():
    return JSONResponse(load_dashboard(), headers={"Cache-Control": "no-store"})


@router.get("/recordings/{recording_id}", response_class=HTMLResponse,
            dependencies=[Depends(require_label_user)])
def dashboard_recording(recording_id: uuid.UUID, back: str = Query('/dashboard', max_length=2048)):
    data = load_dashboard()
    record = next((item for item in data["records"] if item.get("recording_id") == str(recording_id)), None)
    if record is None:
        raise HTTPException(404, "Запись не найдена")
    return HTMLResponse(render_record_detail(data, record, back), headers={"Cache-Control": "no-store"})


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
    from server.app import ArtifactPayload, MAX_JSON_BYTES
    body = await request.body()
    if len(body) > MAX_JSON_BYTES:
        raise HTTPException(413, "Metadata too large")
    try:
        artifact = ArtifactPayload.model_validate_json(body)
    except ValidationError as error:
        raise HTTPException(422, "Invalid reference metadata") from error
    return await run_in_threadpool(add_dashboard_reference, recording_id, artifact)


def add_dashboard_reference(recording_id, artifact):
    # Keep all synchronous lookup/persistence on one worker, never the event loop.
    from server.app import add_reference, engine
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
    owner = await run_in_threadpool(reference_owner, artifact_id)
    return await patch_artifact(artifact_id, request, owner, int(offset))


@router.post("/artifacts/{artifact_id}/complete", dependencies=[Depends(require_label_user), Depends(require_upload_origin)])
def dashboard_reference_complete(artifact_id: uuid.UUID):
    from server.app import complete_artifact
    return complete_artifact(artifact_id, reference_owner(artifact_id))
