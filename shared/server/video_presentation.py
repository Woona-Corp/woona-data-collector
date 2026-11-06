"""Verified working videos, separate from immutable capture artifacts."""
import json
import math
import os
from pathlib import Path


FRAME_RATE = 30


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
            and item['frame_count'] > 0
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
    if data.get('schema_version') not in (1, 2):
        raise ValueError('Unsupported video presentation registry')
    item = data['entries'].get(str(recording_id))
    if item is None:
        return None
    original_matches = item['source_artifact_id'] == str(artifact_id) and item['source_sha256'] == source_sha256
    legacy_verified = item.get('timestamps_identical') is True and item.get('payload_identical') is True
    if not original_matches or not (is_cfr30(item) or legacy_verified and item.get('transform') is None):
        raise ValueError('Video presentation is not bound to the original artifact or not verified')
    path = (root / item['relative_path']).resolve()
    if not path.is_relative_to(root / 'derived') or not path.is_file() or path.stat().st_size != item['size_bytes']:
        raise ValueError('Video presentation file missing or changed')
    return dict(item)
