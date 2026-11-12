"""Verified working videos, separate from immutable capture artifacts."""
import hashlib
import json
import math
import os
from datetime import datetime
from pathlib import Path


FRAME_RATE = 30


def derivative_fingerprint(stat, checksum):
    return {'device': stat.st_dev, 'inode': stat.st_ino, 'size_bytes': stat.st_size,
            'mtime_ns': stat.st_mtime_ns, 'ctime_ns': stat.st_ctime_ns, 'sha256': checksum}


def derivative_fingerprint_matches(item, stat):
    fingerprint = item.get('derivative_fingerprint')
    return isinstance(fingerprint, dict) and fingerprint == derivative_fingerprint(stat, item.get('sha256'))


def is_cfr30(item):
    """Admission proof emitted only after encoding and complete timestamp/decode checks."""
    if not isinstance(item, dict) or item.get('transform') != 'cfr30':
        return False
    mapping = item.get('time_mapping', {})
    if not isinstance(mapping, dict):
        return False
    numbers = [item.get('duration_seconds'), item.get('source_duration_seconds'),
               item.get('grid_error_seconds'), item.get('video_start_seconds'),
               mapping.get('scale'), mapping.get('offset_seconds'), mapping.get('max_error_seconds')]
    if not all(type(v) in (int, float) and math.isfinite(v) for v in numbers):
        return False
    return (item.get('frame_rate') == FRAME_RATE and type(item.get('frame_count')) is int
            and item['frame_count'] > 0 and item['source_duration_seconds'] > 0
            and abs(item['duration_seconds'] - item['frame_count'] / FRAME_RATE) <= 1e-4
            and -1e-4 <= item['duration_seconds'] - item['source_duration_seconds'] <= 1 / FRAME_RATE + 1e-4
            and 0 <= item['grid_error_seconds'] <= 1e-6 and abs(item['video_start_seconds']) <= 1e-6
            and mapping['scale'] == 1 and mapping['offset_seconds'] == 0
            and 0 <= mapping['max_error_seconds'] <= 1 / FRAME_RATE + 1e-9)


def presentation_for_video(recording_id, artifact_id, source_sha256, storage=None):
    root = Path(storage or os.environ.get('WOONA_STORAGE_ROOT', '/srv/woona')).resolve()
    manifest = root / 'derived' / 'video-presentations.json'
    if not manifest.is_file():
        return None
    data = json.loads(manifest.read_text())
    if (not isinstance(data, dict) or type(data.get('schema_version')) is not int
            or data['schema_version'] not in (1, 2) or not isinstance(data.get('entries'), dict)):
        raise ValueError('Unsupported video presentation registry')
    item = data['entries'].get(str(recording_id))
    if item is None:
        return None
    if not isinstance(item, dict):
        raise ValueError('Malformed video presentation')
    original_matches = item.get('source_artifact_id') == str(artifact_id) and item.get('source_sha256') == source_sha256
    legacy_verified = item.get('timestamps_identical') is True and item.get('payload_identical') is True
    if not original_matches or not (is_cfr30(item) or legacy_verified and item.get('transform') is None):
        raise ValueError('Video presentation is not bound to the original artifact or not verified')
    cfr = item.get('transform') == 'cfr30'
    if cfr:
        for key in ('source_sha256', 'sha256'):
            value = item.get(key)
            if not isinstance(value, str) or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
                raise ValueError('Malformed video presentation checksum')
        source = item.get('source_relative_path')
        encoder = item.get('encoder')
        if (data['schema_version'] != 2 or type(item.get('size_bytes')) is not int or item['size_bytes'] <= 0
                or not isinstance(source, str) or not source or Path(source).is_absolute() or '..' in Path(source).parts
                or not isinstance(encoder, dict) or encoder.get('codec') != 'libx264'
                or encoder.get('preset') not in ('ultrafast', 'superfast', 'veryfast', 'fast')
                or type(encoder.get('crf')) is not int or not 0 <= encoder['crf'] <= 30
                or encoder.get('maxrate_kbps') != 12000):
            raise ValueError('Malformed video presentation proof')
        try:
            if datetime.fromisoformat(item['verified_at_utc']).tzinfo is None:
                raise ValueError('Missing verification timezone')
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError('Malformed video presentation verification time') from error
    relative = item.get('relative_path')
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError('Video presentation file missing or changed')
    path = (root / relative).resolve()
    boundary = root / 'derived' / 'cfr30' if cfr else root / 'derived'
    if not path.is_relative_to(boundary) or not path.is_file():
        raise ValueError('Video presentation file missing or changed')
    stat = path.stat()
    if stat.st_size != item.get('size_bytes'):
        raise ValueError('Video presentation file missing or changed')
    if cfr and not derivative_fingerprint_matches(item, stat):
        with path.open('rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
            verified = os.fstat(stream.fileno())
        if (checksum != item['sha256']
                or derivative_fingerprint(stat, checksum) != derivative_fingerprint(verified, checksum)):
            raise ValueError('Video presentation checksum changed')
    return dict(item)
