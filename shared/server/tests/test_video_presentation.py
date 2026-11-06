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

class CfrPresentationTest(unittest.TestCase):
    def test_cfr30_proof_requires_identity_time_and_complete_grid(self):
        from copy import deepcopy
        from server.video_presentation import is_cfr30
        proof={'transform':'cfr30','frame_rate':30,'frame_count':45,'duration_seconds':1.5,
               'source_duration_seconds':1.49,'grid_error_seconds':0,'video_start_seconds':0,
               'time_mapping':{'scale':1,'offset_seconds':0,'max_error_seconds':1/30}}
        self.assertTrue(is_cfr30(proof))
        for field,value in [('frame_rate',24),('frame_count',True),('grid_error_seconds',.01),
                            ('duration_seconds',2),('source_duration_seconds',1.4),('video_start_seconds',.1)]:
            broken=deepcopy(proof);broken[field]=value
            self.assertFalse(is_cfr30(broken),field)
        for field,value in [('scale',1.01),('offset_seconds',.1),('max_error_seconds',float('nan'))]:
            broken=deepcopy(proof);broken['time_mapping'][field]=value
            self.assertFalse(is_cfr30(broken),field)

    def test_new_task_waits_for_verified_video_in_30fps_project(self):
        proof={'transform':'cfr30','frame_rate':30,'frame_count':30,'duration_seconds':1,
               'source_duration_seconds':1,'grid_error_seconds':0,'video_start_seconds':0,
               'time_mapping':{'scale':1,'offset_seconds':0,'max_error_seconds':1/30}}
        ready={'data':{'source_id':'woona:ready','video':'/derived','original_video':'/original'},'meta':{'video_presentation':proof}}
        pending={'data':{'source_id':'woona:pending','video':'/original'},'meta':{}}
        project={'id':21,'frame_rate':30,'label_config':'<View><Video frameRate="30"/></View>'}
        with patch('server.label_sync.active_project',return_value=project), \
             patch('server.label_sync.ensure_storage'), \
             patch('server.label_sync.app_tasks',return_value=[ready,pending]), \
             patch('server.label_sync.paged',side_effect=[[],[ready]]), \
             patch('server.label_sync.request_json') as request, \
             patch.dict('os.environ',{'DATABASE_URL':'unused'}):
            self.assertEqual(_sync_unlocked(),{'activity':(1,1)})
        request.assert_called_once_with('POST','/api/projects/21/import',[ready])
        self.assertEqual(ready['meta']['annotation_coordinates']['frame_rate'],30)

    def test_production_target_rejects_project_drift(self):
        from server.label_sync import active_project
        config='<View><Video name="video" value="$video" frameRate="24"/><TimelineLabels name="labels" toName="video"/></View>'
        with patch.dict('os.environ',{'LABEL_TARGET_FRAME_RATE':'30'}):
            with self.assertRaisesRegex(ValueError,'migrated fixed 30'):
                active_project(fetch=lambda *args:{'label_config':config})
            self.assertEqual(active_project(fetch=lambda *args:{'label_config':config.replace('24','30')})['frame_rate'],30)
