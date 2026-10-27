"""Inspect original loose native exports using an explicit, hash-bound review.

This is an operator tool, not a client endpoint. It preserves the original
manifest, sync file and capture bytes, including reviewed metadata differences.
It never infers capture completion or assigns a different animal automatically.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import uuid

from server.archive_import import FILE_TYPES, MAX_METADATA, canonical, file_hash, integer, timestamp


def differences(left, right, prefix=''):
    if isinstance(left, dict) and isinstance(right, dict):
        changed = set()
        for key in left.keys() | right.keys():
            path = prefix + '.' + key if prefix else key
            if key not in left or key not in right:
                changed.add(path)
            else:
                changed.update(differences(left[key], right[key], path))
        return changed
    return set() if left == right and type(left) is type(right) else {prefix}


def inspect_directory(directory: Path, review: dict) -> dict:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Original export must be a real directory')
    directory = directory.resolve()
    if review.get('schemaVersion') != 1 or not str(review.get('reason', '')).strip():
        raise ValueError('An explicit operator review and reason are required')
    recording_id = str(uuid.UUID(review['recordingId']))
    dog_id = str(uuid.UUID(review['dogId']))
    source_profile_id = str(uuid.UUID(review['sourceProfileId']))
    metadata = {}
    for name, hash_key in [('manifest.json', 'expectedManifestSha256'), ('sync.json', 'expectedSyncSha256')]:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_METADATA:
            raise ValueError('Original metadata missing, unsafe or too large: ' + name)
        if file_hash(path) != review.get(hash_key):
            raise ValueError('Original metadata differs from the operator review: ' + name)
        metadata[name] = json.loads(path.read_bytes())
    manifest, sync = metadata['manifest.json'], metadata['sync.json']
    profile, record = manifest['profile'], manifest['recording']
    if str(uuid.UUID(record['id'])) != recording_id or sync.get('recordingId') != recording_id:
        raise ValueError('Original recording identity differs from the review')
    if str(uuid.UUID(profile['id'])) != source_profile_id or sync.get('profileId') != source_profile_id:
        raise ValueError('Original profile identity differs from the review')
    approved = review.get('approvedSyncDifferences', [])
    if not isinstance(approved, list) or len(approved) != len(set(approved)):
        raise ValueError('Reviewed metadata difference list is invalid')
    if set(approved) - {'sessionQuestionnaire.sessionLabel'}:
        raise ValueError('Clock, identity and other metadata differences cannot be approved here')
    changed_sync = differences(sync, manifest.get('synchronization'))
    if changed_sync != set(approved):
        raise ValueError('Original sync differences do not exactly match the review')
    if profile['questionnaire'] != sync.get('dogQuestionnaire'):
        raise ValueError('Original animal questionnaire snapshots disagree')
    original_session, exported_session = sync['sessionQuestionnaire'], record['questionnaire']
    changed_session = differences(original_session, exported_session)
    allowed_session = {'endTime', 'durationMinutes'}
    if 'sessionQuestionnaire.sessionLabel' in approved:
        allowed_session.add('sessionLabel')
    if changed_session - allowed_session:
        raise ValueError('Unreviewed session questionnaire differences')
    if record.get('sessionLabel') != exported_session.get('sessionLabel'):
        raise ValueError('Exported session labels disagree')
    if record.get('source') not in ('live', 'replay') or record.get('status') not in ('completed', 'failed', 'interrupted'):
        raise ValueError('Original final capture status/source is missing')
    if sync.get('source') != record['source'] or sync.get('timezone') != record.get('timezone'):
        raise ValueError('Original source/timezone metadata disagree')
    sensor, video = sync.get('sensor') or {}, sync.get('video') or {}
    anchor, start = timestamp(sensor.get('absoluteUtc')), timestamp(sync.get('selectedSessionStartUtc'))
    first, last = integer(sensor, 'monotonicTimeNs'), integer(sync, 'lastSensorPacketMonotonicNs')
    if last < first or abs(int(anchor.timestamp() * 1000) - integer(sensor, 'wallClockEpochMillis')) > 1:
        raise ValueError('Original sensor clock anchors disagree')
    if sensor.get('monotonicClock') not in ('android.elapsedRealtimeNanos', 'ios.CMClock.hostTime'):
        raise ValueError('Original monotonic clock is unknown')
    integer(sensor, 'samplingUncertaintyNs')
    if video and video.get('offsetFromSensorNs') != integer(video, 'firstFrameMonotonicNs') - first:
        raise ValueError('Original video/sensor clock offset disagrees')
    declared = manifest.get('files', [])
    sizes = {row['name']: row['size'] for row in declared}
    if len(sizes) != len(declared) or not {'sync.json', 'packets.bin', 'packet_timeline.bin', 'raw_fragments.binlog'} <= sizes.keys():
        raise ValueError('Original capture file inventory is incomplete or duplicated')
    if set(sizes) - FILE_TYPES.keys() or set(p.name for p in directory.iterdir()) != set(sizes) | {'manifest.json'}:
        raise ValueError('Directory entries differ from the original manifest')
    if ('video.mp4' in sizes) != bool(video) or bool(exported_session.get('videoRequested')) != bool(video):
        raise ValueError('Original video declaration is inconsistent')
    inventory, artifacts = [], []
    for name, expected in sorted({**sizes, 'manifest.json': (directory / 'manifest.json').stat().st_size}.items()):
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.resolve().parent != directory:
            raise ValueError('Original file is missing or unsafe: ' + name)
        if not isinstance(expected, int) or isinstance(expected, bool) or expected < 0 or path.stat().st_size != expected:
            raise ValueError('Original file size differs from manifest: ' + name)
        digest = file_hash(path)
        inventory.append({'name': name, 'sizeBytes': expected, 'sha256': digest})
        if name != 'manifest.json':
            kind, mime = FILE_TYPES[name]
            artifacts.append({'id': str(uuid.uuid5(uuid.UUID(recording_id), 'archive-file:' + name)),
                'type': kind, 'fileName': name, 'mimeType': mime, 'sizeBytes': expected,
                'sha256': digest, 'stagedPath': str(path)})
    inventory_sha256 = hashlib.sha256(canonical(inventory)).hexdigest()
    return {'schemaVersion': 1, 'sourceKind': 'native_directory', 'sourceDirectory': str(directory),
        'recordingId': recording_id, 'dogId': dog_id, 'sourceId': review['sourceId'],
        'archiveSha256': None, 'manifestSha256': review['expectedManifestSha256'],
        'sourceInventorySha256': inventory_sha256, 'sourceInventory': inventory,
        'identityReview': review, 'metadataReview': {'syncDifferences': sorted(changed_sync),
            'sessionDifferences': sorted(changed_session), 'originalMetadataPreserved': True},
        'manifest': manifest, 'sync': sync, 'startedAtUtc': start.isoformat(), 'anchorAtUtc': anchor.isoformat(),
        'artifacts': artifacts, 'captureQuality': {'status': 'not_audited'},
        'completionFieldsFinalizedAfterCapture': sorted(changed_session & {'endTime', 'durationMinutes'}),
        'unknowns': ['original_capture_device_not_exported', 'recording_end_timestamp_not_exported',
                     'hardware_calibration_not_measured']}


def verify_directory_plan(plan):
    if inspect_directory(Path(plan['sourceDirectory']), plan['identityReview']) != plan:
        raise ValueError('Original directory or reviewed import plan changed before publication')
