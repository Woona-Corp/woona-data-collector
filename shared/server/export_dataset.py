"""Export labeled activity recordings with canonical IDs and explicit time units."""
import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

from server.label_sync import app_tasks, request_json, annotation_frame_rate as frame_rate
from server.alignment import verified_alignment, sensor_intervals


def segments(task, project):
    root = ElementTree.fromstring(project['label_config'])
    control = root.find('.//TimelineLabels'); video = root.find('.//Video')
    labels = {node.get('value') for node in control.findall('Label')}
    fps = frame_rate(project, task)
    result = []
    for annotation in task.get('annotations', []):
        if annotation.get('was_cancelled'):
            continue
        for region in annotation.get('result', []):
            if region.get('type') != 'timelinelabels':
                continue
            if region.get('from_name') != control.get('name') or region.get('to_name') != video.get('name'):
                raise ValueError('Annotation control does not match project')
            selected = region['value'].get('timelinelabels', [])
            if not selected or not set(selected) <= labels:
                raise ValueError('Unknown or empty annotation labels')
            for span in region['value']['ranges']:
                start, end = span['start'], span['end']
                if type(start) is not int or type(end) is not int or not 1 <= start <= end:
                    raise ValueError('Invalid inclusive, one-based frame range')
                # Label Studio's converter uses labels[start - 1:end]. Preserve every label.
                result.append({'annotation_id': annotation['id'], 'region_id': region['id'],
                               'start_frame': start, 'end_frame_inclusive': end,
                               'start_seconds': (start - 1) / fps, 'end_seconds_exclusive': end / fps,
                               'labels': selected, 'time_basis': 'video', 'quantization_seconds': 1 / fps})
    return result


def build_dataset(canonical, tasks, inventory, project, mode='video'):
    canonical = {t['data']['recording_id']: t for t in canonical}
    task_map = {}
    for task in tasks:
        rid = task['data'].get('recording_id')
        if rid in task_map:
            raise ValueError('Duplicate Label Studio recording ID')
        task_map[rid] = task
    records, excluded = [], []
    for rid, row in sorted(inventory.items()):
        candidate, task = canonical.get(rid), task_map.get(rid)
        reasons = []
        if row['ingest_status'] != 'complete': reasons.append('upload_incomplete')
        if row['capture_status'] != 'completed': reasons.append('capture_not_completed')
        if not candidate: reasons.append('not_complete_v2_activity_recording')
        if not task: reasons.append('no_annotation_task')
        if task and task.get('meta', {}).get('dataset_admission', {}).get('status') == 'excluded':
            reasons.append('explicitly_excluded')
        sync = row['sync']
        proof = verified_alignment(sync, row['artifacts'])
        if mode == 'ble' and not proof:
            reasons.append('verified_video_ble_calibration_required')
        if reasons:
            excluded.append({'recording_id': rid, 'reasons': reasons}); continue
        spans = segments(task, project)
        if not spans:
            excluded.append({'recording_id': rid, 'reasons': ['no_completed_labels']}); continue
        data, meta = candidate['data'], candidate['meta']
        for key in ['recording_id', 'dog_id', 'dog_profile_version_id']:
            if task['data'].get(key) != data[key]:
                raise ValueError('Label Studio identity mismatch: ' + rid)
        for key in ['dog_questionnaire', 'session_questionnaire']:
            if task['meta'].get(key) != meta[key]:
                raise ValueError('Label Studio questionnaire mismatch: ' + rid)
        if task['data'].get('video') != data['video']:
            raise ValueError('Label Studio video mismatch: ' + rid)
        if task.get('meta', {}).get('video_presentation') != meta.get('video_presentation'):
            raise ValueError('Label Studio video presentation mismatch: ' + rid)
        files = row['artifacts']
        required = {'packet', 'packet_timeline', 'raw', 'diagnostic', 'sync', 'video'}
        if not required <= {a['artifact_type'] for a in files if a['storage_status'] == 'available'}:
            raise ValueError('Required files unavailable: ' + rid)
        quality = (sync.get('alignment') or {}).get('data_quality') or task['meta'].get('data_quality')
        if quality:
            packet = next(a for a in files if a['artifact_type'] == 'packet')
            timeline = next(a for a in files if a['artifact_type'] == 'packet_timeline')
            if not quality or quality.get('packet_sha256') != packet['sha256'] or quality.get('timeline_sha256') != timeline['sha256']:
                raise ValueError('BLE quality report missing or bound to other bytes: ' + rid)
        records.append({'recording_id': rid, 'dog_id': data['dog_id'], 'dog_profile_version_id': data['dog_profile_version_id'],
                        'split_group': data['dog_id'], 'dog_questionnaire': meta['dog_questionnaire'],
                        'session_questionnaire': meta['session_questionnaire'], 'sync': sync,
                        'recording_started_at_utc': row.get('started_at'), 'timezone': row.get('timezone'),
                        'label_task_id': task['id'], 'annotation_frame_rate': frame_rate(project, task),
                        'segments': spans, 'artifacts': files, 'data_quality': quality})
        records[-1]['alignment'] = proof
        if meta.get('video_presentation'):
            records[-1]['video_presentation'] = dict(meta['video_presentation'])
            records[-1]['video_presentation']['download_url'] = data['video']
        if mode == 'ble':
            for span in records[-1]['segments']:
                span['sensor_intervals'] = sensor_intervals(span,proof)
    video_hashes = [a['sha256'] for r in records for a in r['artifacts'] if a['artifact_type'] == 'video']
    if len(video_hashes) != len(set(video_hashes)):
        raise ValueError('Duplicate video bytes across selected recordings; review provenance')
    return {'schema_version': 2, 'created_at_utc': datetime.now(timezone.utc).isoformat(), 'mode': mode,
            'identity_policy': 'canonical recording_id; pinned dog_profile_version_id; split by dog_id',
            'label_config': project['label_config'], 'label_config_sha256': hashlib.sha256(project['label_config'].encode()).hexdigest(),
            'interval_convention': 'one-based inclusive frames; zero-based half-open seconds',
            'records': records, 'excluded': excluded}


def export(output, mode='video'):
    from sqlalchemy import create_engine, text

    engine = create_engine(os.environ['DATABASE_URL'], isolation_level='REPEATABLE READ')
    with engine.connect() as connection:
        with connection.begin():
            connection.execute(text('SET TRANSACTION READ ONLY'))
            rows = connection.execute(text('SELECT r.id,r.ingest_status,r.capture_status,r.started_at,r.timezone,row_to_json(s) AS sync FROM recordings r JOIN recording_sync s ON s.recording_id=r.id')).mappings().all()
            inventory = {str(r['id']): {**dict(r), 'artifacts': []} for r in rows}
            for artifact in connection.execute(text('SELECT id,recording_id,artifact_type,file_name,expected_size_bytes,sha256,storage_status,server_relative_path FROM artifacts ORDER BY id')).mappings():
                item = dict(artifact); item['id'] = str(item['id']); item['recording_id'] = str(item['recording_id'])
                inventory[item['recording_id']]['artifacts'].append(item)
    engine.dispose()
    project_id = int(os.environ.get('LABEL_PROJECT_ID', '21'))
    project = request_json('GET', f'/api/projects/{project_id}/')
    tasks = request_json('GET', f'/api/projects/{project_id}/export?exportType=JSON&download_all_tasks=true')
    canonical = app_tasks(os.environ['DATABASE_URL'])
    result = build_dataset(canonical, tasks, inventory, project, mode)
    storage = Path(os.environ['WOONA_STORAGE_ROOT']).resolve()
    for row in result['records']:
        for artifact in row['artifacts']:
            if artifact['storage_status'] != 'available': continue
            path = (storage / artifact['server_relative_path']).resolve()
            if storage not in path.parents or not path.is_file() or path.stat().st_size != artifact['expected_size_bytes']:
                raise ValueError('File missing or wrong size: ' + artifact['id'])
            with path.open('rb') as stream:
                checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
            if checksum != artifact['sha256']:
                raise ValueError('Checksum mismatch: ' + artifact['id'])
            artifact['download_url'] = 'https://' + os.environ['LABEL_STUDIO_HOST_HEADER'] + '/v1/artifacts/' + artifact['id'] + '/content'
        presentation = row.get('video_presentation')
        if presentation:
            path = (storage / presentation['relative_path']).resolve()
            if not path.is_relative_to(storage / 'derived') or not path.is_file() or path.stat().st_size != presentation['size_bytes']:
                raise ValueError('Presentation file missing or wrong size')
            with path.open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != presentation['sha256']:
                    raise ValueError('Presentation checksum mismatch')
            presentation['download_url'] = 'https://' + os.environ['LABEL_STUDIO_HOST_HEADER'] + presentation['download_url']
    output.parent.mkdir(parents=True, exist_ok=True)
    pending = output.with_name(output.name + '.tmp')
    pending.write_text(json.dumps(result, ensure_ascii=False, indent=2, default=str)); pending.replace(output)
    print(json.dumps({'records': len(result['records']), 'excluded': len(result['excluded']), 'mode': mode}, ensure_ascii=False))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    parser.add_argument('--mode', choices=['video', 'ble'], default='video')
    arguments = parser.parse_args()
    export(arguments.output, arguments.mode)
