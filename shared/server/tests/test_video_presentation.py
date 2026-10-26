import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from server.video_presentation import presentation_for_video
from server.label_sync import _sync_unlocked


class VideoPresentationTest(unittest.TestCase):
    def test_verified_derivative_is_bound_to_original_and_cannot_escape_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'derived').mkdir()
            (root / 'derived' / 'clip.mp4').write_bytes(b'video')
            item = {'source_artifact_id': 'artifact', 'source_sha256': 'original',
                'relative_path': 'derived/clip.mp4', 'size_bytes': 5, 'sha256': 'derivative',
                'timestamps_identical': True, 'payload_identical': True}
            registry = root / 'derived' / 'video-presentations.json'
            def save(): registry.write_text(json.dumps({'schema_version': 1, 'entries': {'recording': item}}))
            save()
            self.assertEqual(presentation_for_video('recording', 'artifact', 'original', root), item)
            self.assertIsNone(presentation_for_video('other', 'artifact', 'original', root))
            with self.assertRaisesRegex(ValueError, 'bound'):
                presentation_for_video('recording', 'different-artifact', 'original', root)
            item['relative_path'] = '../outside.mp4'; save()
            with self.assertRaisesRegex(ValueError, 'missing or changed'):
                presentation_for_video('recording', 'artifact', 'original', root)
            item['relative_path'] = 'derived/clip.mp4'; item['payload_identical'] = False; save()
            with self.assertRaisesRegex(ValueError, 'bound'):
                presentation_for_video('recording', 'artifact', 'original', root)

    def test_task_update_preserves_custom_data_and_annotation_coordinates(self):
        candidate = {'data': {'source_id': 'woona:r', 'original_video': '/original', 'video': '/derived'},
                     'meta': {'video_presentation': {'sha256': 'derived'}}}
        detail = {'id': 3, 'data': {'source_id': 'woona:r', 'video': '/original', 'custom': 'keep'},
                  'meta': {'annotation_coordinates': {'frame_rate': 24}, 'review': 'keep'},
                  'annotations': [{'id': 1, 'result': [{'value': 'untouched'}]}]}
        with patch('server.label_sync.active_project', return_value={'id': 21}), \
             patch('server.label_sync.ensure_storage'), \
             patch('server.label_sync.app_tasks', return_value=[candidate]), \
             patch('server.label_sync.paged', return_value=[detail]), \
             patch('server.label_sync.request_json', return_value=detail) as request, \
             patch.dict('os.environ', {'DATABASE_URL': 'unused'}):
            self.assertEqual(_sync_unlocked(), {'activity': (1, 1)})
        method, path, payload = request.call_args.args
        self.assertEqual((method, path), ('PATCH', '/api/tasks/3/'))
        self.assertEqual(payload['data']['custom'], 'keep')
        self.assertEqual(payload['meta']['annotation_coordinates'], {'frame_rate': 24})
        self.assertEqual(payload['meta']['review'], 'keep')
        self.assertNotIn('annotations', payload)
        self.assertEqual(payload['data']['video'], '/derived')
