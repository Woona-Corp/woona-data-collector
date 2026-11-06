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


class CfrAdmissionSafetyTest(unittest.TestCase):
    def proof(self):
        import hashlib
        return dict(transform='cfr30', frame_rate=30, frame_count=30, duration_seconds=1,
            source_duration_seconds=1, grid_error_seconds=0, video_start_seconds=0,
            time_mapping={'scale': 1, 'offset_seconds': 0, 'max_error_seconds': 1/30},
            source_artifact_id='artifact', source_sha256='a'*64, source_relative_path='source.mp4',
            relative_path='derived/cfr30/clip.mp4', size_bytes=5,
            sha256=hashlib.sha256(b'video').hexdigest(), verified_at_utc='2026-11-06T00:00:00+00:00',
            encoder={'codec': 'libx264', 'preset': 'ultrafast', 'crf': 18, 'maxrate_kbps': 12000})

    def test_schema2_checks_actual_derivative_and_malformed_binding_read_only(self):
        from copy import deepcopy
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / 'derived/cfr30/clip.mp4'
            media.parent.mkdir(parents=True)
            media.write_bytes(b'video')
            registry = root / 'derived/video-presentations.json'
            original = self.proof()
            def read(item):
                registry.write_text(json.dumps({'schema_version': 2, 'entries': {'r': item}}))
                snapshot = registry.read_bytes()
                with patch.object(Path, 'write_text', side_effect=AssertionError('read path wrote registry')):
                    result = presentation_for_video('r', 'artifact', 'a'*64, root)
                self.assertEqual(registry.read_bytes(), snapshot)
                return result
            self.assertEqual(read(original), original)
            media.write_bytes(b'other')
            with self.assertRaisesRegex(ValueError, 'checksum|changed'):
                read(original)
            media.write_bytes(b'video')
            for field, value in [('sha256', 'bad'), ('source_artifact_id', 'other'),
                    ('source_sha256', 'b'*64), ('relative_path', '../outside.mp4'),
                    ('relative_path', 5), ('size_bytes', True), ('time_mapping', []),
                    ('source_relative_path', '/absolute'), ('verified_at_utc', None)]:
                with self.subTest(field=field, value=value):
                    item = deepcopy(original)
                    item[field] = value
                    with self.assertRaises(ValueError):
                        read(item)

    def test_migrated_task_noop_and_fresh_coordinate_conflict_prevent_patch(self):
        from copy import deepcopy
        from server.label_sync import managed_task_patch
        candidate = {'data': {'source_id': 'woona:r', 'video': '/derived', 'original_video': '/original'},
                     'meta': {'video_presentation': self.proof()}}
        current = deepcopy(candidate)
        current.update(id=7, annotations=[{'id': 8, 'result': ['keep']}])
        current['data']['custom'] = 'keep'
        current['meta'].update(review='keep', annotation_coordinates={
            'frame_rate': 30, 'frame_origin': 1, 'end_inclusive': True})
        self.assertIsNone(managed_task_patch(candidate, current))
        project = {'id': 21, 'frame_rate': 30}
        for coordinates in [None, [], {}, {'frame_rate': 24, 'frame_origin': 1, 'end_inclusive': True},
                {'frame_rate': 30, 'frame_origin': 0, 'end_inclusive': True},
                {'frame_rate': 30, 'frame_origin': 1, 'end_inclusive': False}]:
            with self.subTest(coordinates=coordinates):
                broken = deepcopy(current)
                broken['meta']['annotation_coordinates'] = coordinates
                with self.assertRaisesRegex(RuntimeError, 'coordinate'):
                    managed_task_patch(candidate, broken)
                listed = deepcopy(current)
                listed['data']['video'] = '/original'
                with patch('server.label_sync.active_project', return_value=project), \
                     patch('server.label_sync.ensure_storage'), \
                     patch('server.label_sync.app_tasks', return_value=[candidate]), \
                     patch('server.label_sync.paged', return_value=[listed]), \
                     patch('server.label_sync.request_json', return_value=broken) as api, \
                     patch.dict('os.environ', {'DATABASE_URL': 'unused'}):
                    with self.assertRaisesRegex(RuntimeError, 'coordinate'):
                        _sync_unlocked()
                    self.assertEqual([c.args[0] for c in api.call_args_list], ['GET'])
        conflict = deepcopy(current)
        conflict['data']['source_id'] = 'other'
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            managed_task_patch(candidate, conflict)
