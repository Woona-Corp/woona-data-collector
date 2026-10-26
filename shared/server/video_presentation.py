"""Verified presentation derivatives, separate from immutable capture artifacts."""
import json
import os
from pathlib import Path


def presentation_for_video(recording_id, artifact_id, source_sha256, storage=None):
    root = Path(storage or os.environ.get('WOONA_STORAGE_ROOT', '/srv/woona')).resolve()
    manifest = root / 'derived' / 'video-presentations.json'
    if not manifest.is_file():
        return None
    data = json.loads(manifest.read_text())
    if data.get('schema_version') != 1:
        raise ValueError('Unsupported video presentation registry')
    item = data['entries'].get(str(recording_id))
    if item is None:
        return None
    if (item['source_artifact_id'] != str(artifact_id) or item['source_sha256'] != source_sha256
            or not item.get('timestamps_identical') or not item.get('payload_identical')):
        raise ValueError('Video presentation is not bound to the original artifact')
    path = (root / item['relative_path']).resolve()
    if not path.is_relative_to(root / 'derived') or not path.is_file() or path.stat().st_size != item['size_bytes']:
        raise ValueError('Video presentation file missing or changed')
    return dict(item)
