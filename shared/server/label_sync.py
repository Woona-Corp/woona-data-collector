"""Synchronize complete Woona recordings with the existing Label Studio project."""

import argparse
import fcntl
import hashlib
import html
import json
import logging
import math
import os
import time
from collections import defaultdict
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen
from xml.etree import ElementTree

from server.eligibility import activity_exclusion_reasons
from server.video_presentation import presentation_for_video

def file_url(relative: str) -> str:
    return "/data/local-files/?d=" + quote(relative, safe="/")


def annotation_frame_rate(project: dict, task: dict) -> float:
    node = ElementTree.fromstring(project['label_config']).find('.//Video')
    value = node.get('frameRate', node.get('framerate', '24'))
    value = task['data'][value[1:]] if value.startswith('$') else value
    fps = float(value)
    if not math.isfinite(fps) or fps <= 0:
        raise ValueError('Invalid annotation frame rate')
    frozen = task.get('meta', {}).get('annotation_coordinates', {}).get('frame_rate')
    if frozen is not None and float(frozen) != fps:
        raise ValueError('Annotation FPS changed; migrate existing ranges before export')
    return fps


def task(source_id: str, title: str, files: list[dict], *, source: str, dog: str, date: str) -> dict:
    links = "".join(
        f'<li><a href="{html.escape(file_url(item["relative"]), quote=True)}" target="_blank">'
        f'{html.escape(item["name"])}</a> ({item["size"]} bytes, SHA-256 {html.escape(item["sha256"])})</li>'
        for item in files
    )
    videos = [item for item in files if item["name"].lower().endswith(".mp4")]
    data = {"source_id": source_id, "html": f"<h3>{html.escape(title)}</h3><p>{html.escape(dog)} · {html.escape(date)}</p><ul>{links}</ul>"}
    if videos:
        data["video"] = file_url(videos[0]["relative"])
    return {"data": data, "meta": {"schema_version": 1, "source": source, "source_id": source_id,
                                     "dog": dog, "capture_date": date}}


def app_tasks(database_url: str) -> list[dict]:
    from sqlalchemy import create_engine, text

    engine = create_engine(database_url, pool_pre_ping=True)
    with engine.connect() as connection:
        rows = connection.execute(text("""
            SELECT r.id, r.started_at, r.dog_id, r.dog_profile_version_id,
                   r.ingest_status, r.capture_status, r.capture_error_code,
                   r.session_questionnaire, v.questionnaire AS dog_questionnaire,
                   d.number_or_name, rs.alignment, a.id AS artifact_id, a.artifact_type, a.file_name,
                   a.server_relative_path, a.expected_size_bytes, a.sha256
            FROM recordings r JOIN dogs d ON d.id=r.dog_id
            JOIN dog_profile_versions v ON v.id=r.dog_profile_version_id
            JOIN recording_sync rs ON rs.recording_id=r.id
            JOIN artifacts a ON a.recording_id=r.id
            WHERE r.ingest_status='complete' AND r.capture_status='completed' AND r.capture_error_code IS NULL AND a.storage_status='available'
              AND a.artifact_type NOT IN ('ecg','heart_rate','rr')
              AND a.file_name NOT IN ('polar_hr.csv','polar_ecg.csv')
            ORDER BY r.id, a.id
        """)).mappings().all()
    engine.dispose()
    groups = defaultdict(list)
    for row in rows:
        groups[str(row["id"])].append(row)
    result = []
    for recording_id, members in groups.items():
        first = members[0]
        questionnaire = first["session_questionnaire"]
        kinds = {row["artifact_type"] for row in members}
        if activity_exclusion_reasons(first['ingest_status'], first['capture_status'],
                                      first['capture_error_code'], questionnaire, kinds):
            continue
        files = [{"name": row["file_name"], "relative": "woona/" + row["server_relative_path"],
                  "size": row["expected_size_bytes"], "sha256": row["sha256"]} for row in members]
        result.append(task("woona:" + recording_id, "Woona recording " + recording_id, files,
                           source="woona-api-v1", dog=first["number_or_name"],
                            date=first["started_at"].date().isoformat()))
        result[-1]["data"].update({"recording_id": recording_id, "dog_id": str(first["dog_id"]),
                                  "dog_profile_version_id": str(first["dog_profile_version_id"]),
                                  "dog": first["number_or_name"], "session": questionnaire["sessionLabel"]})
        result[-1]["meta"].update({"dog_questionnaire": first["dog_questionnaire"], "session_questionnaire": questionnaire})
        video = next(row for row in members if row['artifact_type'] == 'video')
        presentation = presentation_for_video(recording_id, video['artifact_id'], video['sha256'])
        if presentation:
            result[-1]['data']['original_video'] = result[-1]['data']['video']
            result[-1]['data']['video'] = file_url('woona/' + presentation['relative_path'])
            result[-1]['meta']['video_presentation'] = presentation
        result[-1]['meta']['alignment'] = first['alignment']
        if first['alignment'] and first['alignment'].get('data_quality'):
            result[-1]['meta']['data_quality'] = first['alignment']['data_quality']
    return result


def request_json(method: str, path: str, payload=None):
    base = os.environ["LABEL_STUDIO_URL"].rstrip("/")
    data = json.dumps(payload).encode() if payload is not None else None
    request = Request(base + path, data=data, method=method, headers={
        "Host": os.environ["LABEL_STUDIO_HOST_HEADER"],
        "Authorization": "Token " + os.environ["LABEL_STUDIO_API_TOKEN"],
        "Content-Type": "application/json",
    })
    with urlopen(request, timeout=60) as response:
        body = response.read()
        return json.loads(body) if body else None


def paged(path: str) -> list[dict]:
    results = []
    seen_ids = set()
    page = 1
    while True:
        separator = "&" if "?" in path else "?"
        body = request_json("GET", f"{path}{separator}{urlencode({'page': page, 'page_size': 100})}")
        if isinstance(body, list):
            if page != 1:
                raise RuntimeError(f"pagination response format changed: {path}")
            return body
        batch = body.get("results", body.get("tasks", []))
        total = body.get("total", body.get("count"))
        if total is not None and (not isinstance(total, int) or total < 0):
            raise RuntimeError(f"invalid pagination total: {path}")
        if not batch and (body.get('next') or (total is not None and total > len(results))):
            raise RuntimeError(f"pagination stopped early: {path}")
        page_ids = [item.get('id') for item in batch]
        if len(set(page_ids)) != len(page_ids) or seen_ids.intersection(page_ids):
            raise RuntimeError(f"pagination repeated task IDs: {path}")
        seen_ids.update(page_ids)
        results.extend(batch)
        if not body.get("next") and (total is None or len(results) >= total):
            return results
        page += 1


def ensure_storage(project: int) -> None:
    current = {item["path"] for item in request_json("GET", f"/api/storages/localfiles/?project={project}")}
    for name in ("woona",):
        path = "/label-studio/files/" + name
        if path not in current:
            request_json("POST", "/api/storages/localfiles/", {
                "project": project, "path": path, "title": name,
                "synchronizable": False, "use_blob_urls": True,
            })


def sync() -> dict[str, tuple[int, int]]:
    # ponytail: one shared container lock; use a database advisory lock if workers are replicated.
    with open("/tmp/woona-label-sync.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _sync_unlocked()


def _sync_unlocked() -> dict[str, tuple[int, int]]:
    project = active_project()
    project_id = project["id"]
    ensure_storage(project_id)
    expected = app_tasks(os.environ["DATABASE_URL"])
    current = {row["data"].get("source_id") for row in paged(f"/api/tasks?project={project_id}")}
    missing = [item for item in expected if item["data"]["source_id"] not in current]
    for item in missing:
        item['meta']['annotation_coordinates'] = {
            'frame_rate': annotation_frame_rate(project, item), 'frame_origin': 1, 'end_inclusive': True,
            'config_sha256': hashlib.sha256(project['label_config'].encode()).hexdigest(),
        }
    for offset in range(0, len(missing), 50):
        request_json("POST", f"/api/projects/{project_id}/import", missing[offset:offset + 50])
    rows = paged(f"/api/tasks?project={project_id}")
    by_source = {row['data'].get('source_id'): row for row in rows}
    for candidate in expected:
        current = by_source.get(candidate['data']['source_id'])
        if not current or not managed_task_patch(candidate, current):
            continue
        detail = request_json('GET', f"/api/tasks/{current['id']}/")
        update = managed_task_patch(candidate, detail)
        if update:
            request_json('PATCH', f"/api/tasks/{current['id']}/", update)
    actual = [row["data"].get("source_id") for row in rows]
    if not {item["data"]["source_id"] for item in expected}.issubset(actual):
        raise RuntimeError("import not verified")
    if len(actual) != len(set(actual)):
        raise RuntimeError("duplicate source IDs in labeling project")
    return {"activity": (len(expected), len(actual))}


def managed_task_patch(candidate: dict, current: dict) -> dict | None:
    """Refresh editable questionnaires, never annotations or frozen frame coordinates."""
    data, meta = dict(current.get('data', {})), dict(current.get('meta', {}))
    if candidate['data'].get('source_id') is not None and data.get('source_id') != candidate['data']['source_id']:
        raise RuntimeError('Task source identity conflicts with canonical recording')
    for key in ('recording_id', 'dog_id', 'dog_profile_version_id', 'dog', 'session'):
        if key in candidate['data']:
            if key in ('recording_id', 'dog_id', 'dog_profile_version_id') and data.get(key) not in (None, candidate['data'][key]):
                raise RuntimeError('Task identity conflicts with canonical recording')
            data[key] = candidate['data'][key]
    for key in ('schema_version', 'source', 'source_id', 'dog', 'capture_date',
                'dog_questionnaire', 'session_questionnaire', 'alignment', 'data_quality'):
        if key in candidate['meta']:
            meta[key] = candidate['meta'][key]
    presentation = candidate['meta'].get('video_presentation')
    if presentation:
        if data.get('video') not in (candidate['data']['original_video'], candidate['data']['video']):
            raise RuntimeError('Presentation change conflicts with current task video')
        data.update(original_video=candidate['data']['original_video'], video=candidate['data']['video'])
        meta['video_presentation'] = presentation
    if data == current.get('data', {}) and meta == current.get('meta', {}):
        return None
    return {'data': data, 'meta': meta}


def active_project() -> dict:
    """Use the user's project and read its labels; never create/reconfigure it."""
    project = request_json("GET", f'/api/projects/{int(os.environ.get("LABEL_PROJECT_ID", "21"))}/')
    root = ElementTree.fromstring(project["label_config"])
    timelines = root.findall(".//TimelineLabels")
    videos = root.findall(".//Video")
    if len(timelines) != 1 or len(videos) != 1 or videos[0].get("value") != "$video" or timelines[0].get("toName") != videos[0].get("name"):
        raise ValueError("Expected the existing single video timeline project")
    return {**project, "timeline_name": timelines[0].get("name"),
            "labels": [label.attrib["value"] for label in timelines[0].findall("Label")]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    while True:
        try:
            logging.info("Label Studio sync: %s", sync())
        except Exception:
            logging.exception("Label Studio sync failed")
            if args.once:
                raise
        if args.once:
            break
        time.sleep(60)
