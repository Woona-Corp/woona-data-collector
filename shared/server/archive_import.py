"""Reviewed import of complete native Share ZIPs into existing exact-UUID animals.

Dry-run is the default. Original archives are kept outside canonical storage. The
import never changes a current profile, account, dog revision, annotation or an
existing recording. Unknown hardware calibration stays NULL in PostgreSQL.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import errno
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import stat
import uuid
import zipfile
import zlib

from sqlalchemy import text

FILE_TYPES = {'packets.bin': ('packet', 'application/octet-stream'),
    'packet_timeline.bin': ('packet_timeline', 'application/octet-stream'),
    'raw_fragments.binlog': ('raw', 'application/octet-stream'),
    'diagnostics.log': ('diagnostic', 'text/plain'), 'sync.json': ('sync', 'application/json'),
    'video.mp4': ('video', 'video/mp4'), 'channel.csv': ('csv', 'text/csv')}
IMPORT_DEVICE = uuid.uuid5(uuid.NAMESPACE_URL, 'woona:reviewed-native-archive-import:v1')
MAX_METADATA = 2 * 1024 * 1024


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('Required original UTC timestamp missing')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Original timestamp lacks timezone')
    return parsed.astimezone(timezone.utc)


def integer(mapping, key):
    value = mapping.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError('Required original monotonic value missing: ' + key)
    return value


def inspect_archive(archive: Path, *, expected_sha256: str, recording_id: str, dog_id: str,
                    source_id: str, staging: Path, reserve_bytes: int = 2 * 1024**3) -> dict:
    recording_id, dog_id = str(uuid.UUID(recording_id)), str(uuid.UUID(dog_id))
    if file_hash(archive) != expected_sha256:
        raise ValueError('Original archive SHA-256 mismatch')
    with zipfile.ZipFile(archive) as bundle:
        infos = bundle.infolist()
        names = [item.filename for item in infos]
        if len(names) != len(set(names)) or any(name not in {*FILE_TYPES, 'manifest.json'} for name in names):
            raise ValueError('Archive contains duplicate, unsafe or unsupported entries')
        if any(stat.S_ISLNK(item.external_attr >> 16) or item.is_dir() for item in infos):
            raise ValueError('Archive contains directory or symlink entries')
        if 'manifest.json' not in names or 'sync.json' not in names:
            raise ValueError('Archive must contain manifest and original sync')
        for name in ('manifest.json', 'sync.json'):
            if bundle.getinfo(name).file_size > MAX_METADATA:
                raise ValueError('Archive metadata is too large')
        manifest = json.loads(bundle.read('manifest.json'))
        sync = json.loads(bundle.read('sync.json'))
        record, profile = manifest['recording'], manifest['profile']
        if str(uuid.UUID(record['id'])) != recording_id or sync.get('recordingId') != recording_id:
            raise ValueError('Recording identity differs from reviewed mapping')
        if str(uuid.UUID(profile['id'])) != dog_id or sync.get('profileId') != dog_id:
            raise ValueError('Source profile UUID must exactly equal the reviewed existing animal UUID')
        if sync != manifest.get('synchronization'):
            raise ValueError('Original sync differs from manifest synchronization')
        if profile['questionnaire'] != sync.get('dogQuestionnaire'):
            raise ValueError('Original animal questionnaire snapshots disagree')
        original_session = sync.get('sessionQuestionnaire') or {}
        exported_session = record['questionnaire']
        completion_fields = sorted(key for key in set(original_session) | set(exported_session)
                                   if original_session.get(key) != exported_session.get(key))
        if set(completion_fields) - {'endTime', 'durationMinutes'}:
            raise ValueError('Session questionnaire changes require review; only final completion fields are automatic')
        if record.get('source') not in ('live', 'replay') or record.get('status') not in ('completed', 'failed', 'interrupted'):
            raise ValueError('Original capture status/source is absent or unsupported')
        declared = manifest.get('files', [])
        sizes = {row['name']: row['size'] for row in declared}
        if len(sizes) != len(declared) or set(sizes) != set(names) - {'manifest.json'}:
            raise ValueError('Archive entries differ from original manifest file list')
        if any(bundle.getinfo(name).file_size != size for name, size in sizes.items()):
            raise ValueError('Archive entry size differs from original manifest')
        sensor = sync.get('sensor') or {}
        anchor = timestamp(sensor.get('absoluteUtc'))
        clock = sensor.get('monotonicClock')
        if clock not in ('android.elapsedRealtimeNanos', 'ios.CMClock.hostTime'):
            raise ValueError('Original monotonic clock is unknown')
        first = integer(sensor, 'monotonicTimeNs')
        last = integer(sync, 'lastSensorPacketMonotonicNs')
        if last < first:
            raise ValueError('Original sensor interval is reversed')
        if abs(int(anchor.timestamp() * 1000) - integer(sensor, 'wallClockEpochMillis')) > 1:
            raise ValueError('Original UTC and wall-clock anchor disagree')
        integer(sensor, 'samplingUncertaintyNs')
        start = timestamp(sync.get('selectedSessionStartUtc'))
        if record.get('timezone') != sync.get('timezone'):
            raise ValueError('Original timezone metadata disagrees')
        video = sync.get('video') or {}
        if video:
            video_first = integer(video, 'firstFrameMonotonicNs')
            if video.get('offsetFromSensorNs') != video_first - first:
                raise ValueError('Original video/sensor offset disagrees with source clocks')
        # Reserve room for all expanded bytes and a 2 GiB floor. Never delete source data.
        staging.mkdir(parents=True, exist_ok=True)
        needed = sum(item.file_size for item in infos)
        if shutil.disk_usage(staging).free < needed + reserve_bytes:
            raise OSError('Insufficient space for verified extraction; original archive preserved')
        destination = staging / recording_id
        destination.mkdir(exist_ok=True)
        artifacts = []
        for name in sizes:
            info = bundle.getinfo(name)
            target = destination / name
            digest, crc, count = hashlib.sha256(), 0, 0
            # A prior interrupted extraction is verified again, never trusted by size alone.
            if target.exists():
                source = target.open('rb')
                output = None
            else:
                source = bundle.open(info)
                output = target.with_suffix(target.suffix + '.part').open('wb')
            try:
                for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
                    count += len(chunk)
                    digest.update(chunk)
                    crc = zlib.crc32(chunk, crc)
                    if output is not None:
                        output.write(chunk)
                if output is not None:
                    output.flush()
                    os.fsync(output.fileno())
            finally:
                source.close()
                if output is not None:
                    output.close()
            if count != info.file_size or crc & 0xffffffff != info.CRC:
                raise ValueError('Extracted file CRC/size mismatch; sources preserved: ' + name)
            if output is not None:
                target.with_suffix(target.suffix + '.part').rename(target)
            kind, mime = FILE_TYPES[name]
            artifacts.append({'id': str(uuid.uuid5(uuid.UUID(recording_id), 'archive-file:' + name)),
                'type': kind, 'fileName': name, 'mimeType': mime, 'sizeBytes': count,
                'sha256': digest.hexdigest(), 'stagedPath': str(target)})
        diagnostics = next((item for item in artifacts if item['type'] == 'diagnostic'), None)
        quality = {'status': 'not_audited'}
        if diagnostics:
            rejected, final_lost, max_lost = 0, None, 0
            with Path(diagnostics['stagedPath']).open(encoding='utf-8', errors='replace') as log:
                for line in log:
                    rejected += '\tREJECTED\t' in line
                    values = re.findall(r'\blost=(\d+)', line)
                    if values:
                        final_lost = int(values[-1])
                        max_lost = max(max_lost, final_lost)
            quality = {'status': 'warnings' if rejected or max_lost else 'diagnostics_checked',
                'diagnostic_sha256': diagnostics['sha256'], 'rejected_log_events': rejected,
                'reported_lost_final': final_lost, 'reported_lost_max': max_lost,
                'counter_loss_is_verified': False,
                'reason': 'Counters in diagnostic logs are observations, not proof of continuous valid sensor data'}
        return {'schemaVersion': 1, 'recordingId': recording_id, 'dogId': dog_id,
            'sourceId': source_id, 'archiveSha256': expected_sha256,
            'manifestSha256': hashlib.sha256(bundle.read('manifest.json')).hexdigest(),
            'manifest': manifest, 'sync': sync, 'startedAtUtc': start.isoformat(),
            'anchorAtUtc': anchor.isoformat(), 'artifacts': artifacts, 'captureQuality': quality,
            'completionFieldsFinalizedAfterCapture': completion_fields,
            'unknowns': ['original_capture_device_not_exported', 'recording_end_timestamp_not_exported',
                         'hardware_calibration_not_measured']}


def validate_questionnaires(plan):
    from server.questionnaires import validate_sheet
    for kind, value in [('dog', plan['manifest']['profile']['questionnaire']),
                        ('session', plan['manifest']['recording']['questionnaire'])]:
        if value.get('schemaVersion') != 2:
            raise ValueError('Only fully validated V2 questionnaires can be imported by this tool')
        validate_sheet(kind, value)
    if plan['manifest']['profile']['questionnaire'].get('animalId') != plan['manifest']['recording']['questionnaire'].get('animalId'):
        raise ValueError('Original dog and session external identity disagree')


def preflight(connection, plan):
    recording_id, dog_id = uuid.UUID(plan['recordingId']), uuid.UUID(plan['dogId'])
    dog = connection.execute(text('SELECT id,revision,account_id FROM dogs WHERE id=:id FOR SHARE'), {'id': dog_id}).mappings().first()
    if dog is None:
        raise ValueError('Reviewed animal UUID does not exist; this tool never creates animals')
    source_profile_id = uuid.UUID(plan['manifest']['profile']['id'])
    if source_profile_id != dog_id:
        review = plan.get('identityReview') or {}
        if (plan.get('sourceKind') != 'native_directory'
                or review.get('sourceProfileId') != str(source_profile_id)
                or review.get('dogId') != str(dog_id)
                or review.get('recordingId') != str(recording_id)
                or review.get('expectedManifestSha256') != plan.get('manifestSha256')
                or not str(review.get('reason', '')).strip()):
            raise ValueError('Different source profile requires an explicit hash-bound identity review')
        if connection.execute(text('SELECT 1 FROM dogs WHERE id=:id'), {'id': source_profile_id}).first():
            raise ValueError('Source profile belongs to another existing animal; do not merge animals')
        if connection.execute(text("SELECT 1 FROM retired_entities WHERE kind='dog' AND id_sha256=:hash"),
                {'hash': hashlib.sha256(str(source_profile_id).encode()).hexdigest()}).first():
            raise ValueError('Source animal was deliberately retired')
    retired = connection.execute(text("SELECT count(*) FROM retired_entities WHERE (kind='recording' AND id_sha256=:recording) OR (kind='dog' AND id_sha256=:dog)"), {'recording': hashlib.sha256(str(recording_id).encode()).hexdigest(), 'dog': hashlib.sha256(str(dog_id).encode()).hexdigest()}).scalar_one()
    if retired:
        raise ValueError('Recording was deliberately retired; recovery needs a separate review')
    old = connection.execute(text('SELECT id,dog_id,ingest_status FROM recordings WHERE id=:id'), {'id': recording_id}).mappings().first()
    if old is not None:
        known = [dict(row) for row in connection.execute(text('SELECT id,artifact_type,file_name,sha256,expected_size_bytes,storage_status FROM artifacts WHERE recording_id=:id ORDER BY id'), {'id': recording_id}).mappings()]
        expected = sorted((a['id'], a['type'], a['fileName'], a['sha256'], a['sizeBytes']) for a in plan['artifacts'])
        actual = sorted((str(a['id']), a['artifact_type'], a['file_name'], a['sha256'], a['expected_size_bytes']) for a in known)
        if old['dog_id'] != dog_id or old['ingest_status'] != 'complete' or expected != actual or any(a['storage_status'] != 'available' for a in known):
            raise ValueError('Existing recording differs from import plan; nothing overwritten')
        return {'state': 'already_imported', 'dogRevision': dog['revision']}
    external_id = plan['manifest']['profile']['questionnaire']['animalId'].strip().casefold()
    owner = connection.execute(text("SELECT dog_id FROM dog_external_ids WHERE namespace='woona' AND external_id=:id"), {'id': external_id}).scalar_one_or_none()
    if owner is not None and owner != dog_id:
        raise ValueError('Original animal ID is reserved by another animal; mapping requires operator review')
    if source_profile_id != dog_id and owner != dog_id:
        raise ValueError('Reviewed mapping requires the existing canonical external animal ID')
    return {'state': 'ready', 'dogRevision': dog['revision']}


def apply_plan(engine, storage_root: Path, plan):
    if plan.get('sourceKind') == 'native_directory':
        from server.directory_import import verify_directory_plan
        verify_directory_plan(plan)
    validate_questionnaires(plan)
    storage_root = storage_root.resolve()
    for artifact in plan['artifacts']:
        path = Path(artifact['stagedPath'])
        if not path.is_file() or path.stat().st_size != artifact['sizeBytes'] or file_hash(path) != artifact['sha256']:
            raise ValueError('Verified staged file changed before commit')
    with engine.begin() as connection:
        connection.execute(text('SELECT pg_advisory_xact_lock(hashtextextended(:key,0))'), {'key': 'woona:archive:' + plan['recordingId']})
        state = preflight(connection, plan)
        if state['state'] == 'already_imported':
            return state
        if plan.get('sourceKind') == 'native_directory':
            required = sum(item['sizeBytes'] for item in plan['artifacts']) + 2 * 1024**3
            if shutil.disk_usage(storage_root).free < required:
                raise OSError('Insufficient space for independent canonical copies; original export preserved')
        nullable = connection.execute(text("SELECT is_nullable FROM information_schema.columns WHERE table_schema=current_schema() AND table_name='recording_sync' AND column_name='calibration_offset_ns'")).scalar_one()
        if nullable != 'YES':
            raise ValueError('Migration 0008 is required; unknown calibration cannot become a false zero')
        created = datetime.now(timezone.utc)
        record, profile, sync = plan['manifest']['recording'], plan['manifest']['profile'], plan['sync']
        sensor, video = sync['sensor'], sync.get('video') or {}
        dog_id, recording_id = uuid.UUID(plan['dogId']), uuid.UUID(plan['recordingId'])
        connection.execute(text("INSERT INTO client_devices(id,label,token_hash) VALUES(:id,:label,:hash) ON CONFLICT(id) DO NOTHING"),
            {'id': IMPORT_DEVICE, 'label': 'Reviewed archive import; original capture device not exported',
             'hash': hashlib.sha256(secrets.token_bytes(32)).hexdigest()})
        content_hash = hashlib.sha256(canonical(profile['questionnaire'])).hexdigest()
        profile_id = connection.execute(text('SELECT id FROM dog_profile_versions WHERE dog_id=:dog AND content_sha256=:hash'), {'dog': dog_id, 'hash': content_hash}).scalar_one_or_none()
        if profile_id is None:
            profile_id = uuid.uuid5(dog_id, 'archive-profile:' + content_hash)
            connection.execute(text("""INSERT INTO dog_profile_versions(id,dog_id,schema_version,validation_state,questionnaire,content_sha256,created_by_device_id,client_created_at,superseded_at)
                VALUES(:id,:dog,2,'complete',CAST(:answers AS jsonb),:hash,:device,:created,now())"""),
                {'id': profile_id, 'dog': dog_id, 'answers': canonical(profile['questionnaire']).decode(),
                 'hash': content_hash, 'device': IMPORT_DEVICE, 'created': created})
        # No UPDATE of dogs or current versions: these are historical capture snapshots.
        connection.execute(text("""INSERT INTO recordings(id,dog_id,dog_profile_version_id,capture_device_id,source,capture_status,ingest_status,
            started_at,ended_at,timezone,session_label,questionnaire_schema_version,questionnaire_validation_state,session_questionnaire,
            video_requested,app_version,client_created_at)
            VALUES(:id,:dog,:profile,:device,:source,:capture,'uploading',:started,NULL,:zone,:label,2,'complete',CAST(:answers AS jsonb),:video,'unknown',:created)"""),
            {'id': recording_id, 'dog': dog_id, 'profile': profile_id, 'device': IMPORT_DEVICE,
             'source': record['source'], 'capture': record['status'], 'started': timestamp(plan['startedAtUtc']),
             'zone': record['timezone'], 'label': record['sessionLabel'],
             'answers': canonical(record['questionnaire']).decode(), 'video': record['questionnaire']['videoRequested'], 'created': created})
        provenance = {'status': 'unverified', 'reason': 'hardware_calibration_not_measured',
            'original_capture_sync': sync,
            'archive_import': {'schema_version': 1, 'source_id': plan['sourceId'], 'archive_sha256': plan['archiveSha256'],
                'source_kind': plan.get('sourceKind', 'native_archive'),
                'source_inventory_sha256': plan.get('sourceInventorySha256'),
                'source_inventory': plan.get('sourceInventory'),
                'identity_review': plan.get('identityReview'), 'metadata_review': plan.get('metadataReview'),
                'manifest_sha256': plan['manifestSha256'], 'source_profile_id': profile['id'],
                'completion_fields_finalized_after_capture': plan.get('completionFieldsFinalizedAfterCapture', []),
                'source_recording_id': record['id'], 'source_manifest': plan['manifest'],
                'imported_at_utc': created.isoformat(), 'unknowns': plan['unknowns'],
                'calibration': {'measured': False, 'offset_ns': None, 'reason': 'not_measured_in_source'},
                'questionnaire_snapshot_created_by_importer': True,
                'capture_quality': plan.get('captureQuality', {'status': 'not_audited'})}}
        values = {'recording_id': recording_id, 'schema_version': 2, 'monotonic_clock': sensor['monotonicClock'],
            'session_zero_at_utc': timestamp(plan['anchorAtUtc']), 'session_zero_wall_clock_ms': sensor['wallClockEpochMillis'],
            'session_zero_monotonic_ns': sensor['monotonicTimeNs'], 'session_zero_uncertainty_ns': sensor['samplingUncertaintyNs'],
            'first_sensor_packet_monotonic_ns': sensor['monotonicTimeNs'], 'first_sensor_device_timer_ms': sync.get('firstSensorDeviceTimerMillis'),
            'last_sensor_packet_monotonic_ns': sync['lastSensorPacketMonotonicNs'], 'video_requested_monotonic_ns': video.get('requestedMonotonicNs'),
            'media_recorder_started_monotonic_ns': video.get('mediaRecorderStartedMonotonicNs'),
            'video_first_frame_monotonic_ns': video.get('firstFrameMonotonicNs'),
            'video_first_frame_camera_timestamp_ns': video.get('firstFrameCameraTimestampNs'),
            'video_first_frame_callback_monotonic_ns': video.get('firstFrameCallbackMonotonicNs'),
            'video_first_sample_pts_us': video.get('firstVideoSamplePtsUs'), 'video_offset_from_sensor_ns': video.get('offsetFromSensorNs'),
            'camera_timestamp_source': video.get('cameraTimestampSource'),
            'camera_clock_quality': 'hardware_monotonic' if video.get('cameraTimestampSource') == 'realtime' else 'unavailable',
            'sensor_clock_quality': 'first_packet_arrival',
            'overall_sync_quality': video.get('synchronizationQuality', 'unavailable'), 'calibration_offset_ns': None}
        columns = ','.join(values)
        parameters = ','.join(':' + key for key in values)
        connection.execute(text(f'INSERT INTO recording_sync({columns},alignment) VALUES({parameters},CAST(:provenance AS jsonb))'), {**values, 'provenance': canonical(provenance).decode()})
        receipt_rows = []
        for artifact in plan['artifacts']:
            artifact_id = uuid.UUID(artifact['id'])
            relative = Path('recordings') / str(dog_id) / timestamp(plan['startedAtUtc']).date().isoformat() / str(recording_id) / artifact['fileName']
            destination = (storage_root / relative).resolve()
            if storage_root not in destination.parents:
                raise ValueError('Canonical target escaped storage')
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                if destination.stat().st_size != artifact['sizeBytes'] or file_hash(destination) != artifact['sha256']:
                    raise ValueError('Canonical destination already exists with different bytes')
            else:
                # Original loose exports can be edited later. Canonical files
                # must own their bytes instead of sharing that mutable inode.
                copy_required = plan.get('sourceKind') == 'native_directory'
                if not copy_required:
                    try:
                        os.link(artifact['stagedPath'], destination)
                    except OSError as error:
                        if error.errno != errno.EXDEV:
                            raise
                        copy_required = True
                if copy_required:
                    partial = destination.with_suffix(destination.suffix + '.import-part')
                    if partial.is_symlink() or (partial.exists() and not partial.is_file()):
                        raise ValueError('Canonical temporary copy is unsafe; originals preserved')
                    if not partial.exists():
                        with Path(artifact['stagedPath']).open('rb') as source, partial.open('xb') as output:
                            shutil.copyfileobj(source, output, 4 * 1024 * 1024)
                            output.flush()
                            os.fsync(output.fileno())
                    if partial.stat().st_size != artifact['sizeBytes'] or file_hash(partial) != artifact['sha256']:
                        raise ValueError('Canonical copy failed integrity verification; sources preserved')
                    # Do not replace an externally-created immutable target.
                    os.link(partial, destination)
                    partial.unlink()
            directory_fd = os.open(destination.parent, os.O_RDONLY)
            try:os.fsync(directory_fd)
            finally:os.close(directory_fd)
            connection.execute(text("""INSERT INTO artifacts(id,recording_id,artifact_type,file_name,mime_type,expected_size_bytes,stored_size_bytes,sha256,
                storage_status,server_relative_path,client_created_at,verified_at)
                VALUES(:id,:recording,:type,:name,:mime,:size,:size,:hash,'available',:path,:created,now())"""),
                {'id': artifact_id, 'recording': recording_id, 'type': artifact['type'], 'name': artifact['fileName'],
                 'mime': artifact['mimeType'], 'size': artifact['sizeBytes'], 'hash': artifact['sha256'],
                 'path': relative.as_posix(), 'created': created})
            receipt_rows.append({'id': str(artifact_id), 'sha256': artifact['sha256'], 'size': artifact['sizeBytes']})
        receipt = hashlib.sha256(canonical(sorted(receipt_rows, key=lambda row: row['id']))).hexdigest()
        connection.execute(text("UPDATE recordings SET ingest_status='complete',server_verified_at=now(),receipt_sha256=:receipt WHERE id=:id"), {'receipt': receipt, 'id': recording_id})
        return {'state': 'imported', 'recordingId': plan['recordingId'], 'dogId': plan['dogId'],
                'dogRevision': state['dogRevision'], 'artifactCount': len(plan['artifacts']),
                'totalBytes': sum(row['sizeBytes'] for row in plan['artifacts']), 'receiptSha256': receipt}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--recording-id', required=True)
    parser.add_argument('--dog-id', required=True)
    parser.add_argument('--source-id', required=True)
    parser.add_argument('--staging', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    from server.app import engine, STORAGE_ROOT
    plan = inspect_archive(args.archive, expected_sha256=args.sha256, recording_id=args.recording_id,
        dog_id=args.dog_id, source_id=args.source_id, staging=args.staging)
    validate_questionnaires(plan)
    with engine.connect() as connection:
        state = preflight(connection, plan)
    print(json.dumps({'state': state['state'], 'mode': 'apply' if args.apply else 'dry_run',
        'recordingId': plan['recordingId'], 'dogId': plan['dogId'],
        'archiveSha256': plan['archiveSha256'], 'artifactCount': len(plan['artifacts']),
        'totalBytes': sum(row['sizeBytes'] for row in plan['artifacts']), 'unknowns': plan['unknowns']}), flush=True)
    if args.apply:
        print(json.dumps(apply_plan(engine, STORAGE_ROOT, plan)), flush=True)


if __name__ == '__main__':
    main()
