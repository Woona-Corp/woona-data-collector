import unittest
from copy import deepcopy
from server.export_dataset import build_dataset, segments


class DatasetExportTest(unittest.TestCase):
    def test_coordinates_multilabel_and_canonical_identity_fail_closed(self):
        project = {'label_config': '<View><Video name="video" frameRate="24"/><TimelineLabels name="labels" toName="video"><Label value="Шаг"/><Label value="Нюхает"/></TimelineLabels></View>'}
        task = {'id': 1, 'data': {'recording_id': 'r', 'dog_id': 'canonical-dog', 'dog_profile_version_id': 'version', 'video': '/video'},
                'meta': {'dog_questionnaire': {'schemaVersion': 2}, 'session_questionnaire': {'schemaVersion': 2},
                         'data_quality': {'packet_sha256': 'packet-hash', 'timeline_sha256': 'packet_timeline'}},
                'annotations': [{'id': 1, 'result': [{'id': 'region', 'type': 'timelinelabels', 'from_name': 'labels', 'to_name': 'video', 'value': {'ranges': [{'start': 25, 'end': 48}], 'timelinelabels': ['Шаг', 'Нюхает']}}]}]}
        span = segments(task, project)[0]
        self.assertEqual((span['start_seconds'], span['end_seconds_exclusive']), (1, 2))
        self.assertEqual(span['labels'], ['Шаг', 'Нюхает'])
        canonical = deepcopy(task)
        inventory = {'r': {'ingest_status': 'complete', 'capture_status': 'completed', 'sync': {'sensor_clock_quality': 'first_packet_arrival', 'overall_sync_quality': 'unavailable', 'video_offset_from_sensor_ns': None},
                           'artifacts': [{'artifact_type': t, 'storage_status': 'available', 'sha256': 'packet-hash' if t == 'packet' else t} for t in ['packet', 'packet_timeline', 'raw', 'diagnostic', 'sync', 'video']]}}
        result = build_dataset([canonical], [task], inventory, project)
        self.assertEqual(result['records'][0]['split_group'], 'canonical-dog')
        task['data']['dog_profile_version_id'] = canonical['data']['dog_profile_version_id'] = 'corrected-version'
        task['meta']['dog_questionnaire'] = canonical['meta']['dog_questionnaire'] = {'schemaVersion': 2, 'chronicLameness': 'да'}
        corrected = build_dataset([canonical], [task], inventory, project)['records'][0]
        self.assertEqual(corrected['dog_profile_version_id'], 'corrected-version')
        self.assertEqual(corrected['dog_questionnaire']['chronicLameness'], 'да')
        self.assertNotIn('feature_questionnaire', corrected)
        self.assertFalse(build_dataset([canonical], [task], inventory, project, 'ble')['records'])
        self.assertTrue(build_dataset([canonical], [task], inventory, project)['records'])
        canonical['meta']['video_presentation'] = {'source_sha256': 'video', 'sha256': 'derived'}
        with self.assertRaisesRegex(ValueError, 'presentation mismatch'):
            build_dataset([canonical], [task], inventory, project)
        task['meta']['video_presentation'] = deepcopy(canonical['meta']['video_presentation'])
        presented = build_dataset([canonical], [task], inventory, project)['records'][0]
        self.assertEqual(presented['video_presentation']['sha256'], 'derived')
        self.assertEqual(next(a['sha256'] for a in presented['artifacts'] if a['artifact_type'] == 'video'), 'video')
        task['meta']['dataset_admission'] = {'status': 'excluded'}
        self.assertFalse(build_dataset([canonical], [task], inventory, project)['records'])
        del task['meta']['dataset_admission']
        task['meta']['annotation_coordinates'] = {'frame_rate': 30}
        with self.assertRaisesRegex(ValueError, 'FPS changed'):
            segments(task, project)
        del task['meta']['annotation_coordinates']
        # A 30 fps label grid alone is not proof of a real CFR working video.
        config30 = {'label_config': project['label_config'].replace('24', '30')}
        self.assertEqual(build_dataset([canonical], [task], inventory, config30)['excluded'][0]['reasons'],
                         ['verified_cfr30_video_required'])
        proof = {'transform':'cfr30','frame_rate':30,'frame_count':90,'duration_seconds':3,
                 'source_duration_seconds':3,'grid_error_seconds':0,'video_start_seconds':0,
                 'time_mapping':{'scale':1,'offset_seconds':0,'max_error_seconds':1/30},
                 'source_sha256':'video','sha256':'derived'}
        canonical['meta']['video_presentation'] = task['meta']['video_presentation'] = proof
        migrated = build_dataset([canonical], [task], inventory, config30)['records'][0]
        self.assertEqual(migrated['annotation_frame_rate'], 30)
        self.assertEqual(next(a['sha256'] for a in migrated['artifacts'] if a['artifact_type'] == 'video'), 'video')
        task['data']['dog_id'] = 'other-dog'
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            build_dataset([canonical], [task], inventory, project)


if __name__ == '__main__':
    unittest.main()


class CfrDatasetIdentityTest(unittest.TestCase):
    def test_original_alignment_hash_and_presentation_error_remain_separate(self):
        config = '<View><Video name="video" frameRate="30"/><TimelineLabels name="labels" toName="video"><Label value="Шаг"/></TimelineLabels></View>'
        proof = dict(transform='cfr30', frame_rate=30, frame_count=30, duration_seconds=1,
            source_duration_seconds=1, grid_error_seconds=0, video_start_seconds=0,
            time_mapping={'scale': 1, 'offset_seconds': 0, 'max_error_seconds': 1/30})
        task = {'id': 1, 'data': {'recording_id': 'r', 'dog_id': 'd', 'dog_profile_version_id': 'v', 'video': '/derived'},
            'meta': {'video_presentation': proof, 'dog_questionnaire': {}, 'session_questionnaire': {},
                     'annotation_coordinates': {'frame_rate': 30, 'frame_origin': 1, 'end_inclusive': True}},
            'annotations': [{'id': 2, 'result': [{'id': 'a', 'type': 'timelinelabels', 'from_name': 'labels', 'to_name': 'video',
                'value': {'ranges': [{'start': 1, 'end': 30}], 'timelinelabels': ['Шаг']}}]}]}
        files = [{'artifact_type': k, 'storage_status': 'available', 'sha256': k} for k in ['packet', 'packet_timeline', 'raw', 'diagnostic', 'sync', 'video']]
        alignment = dict(status='verified', method='shared_clock', clock_basis_confirmed=True, latency_bound_measured=True,
            offset_seconds=0, scale=1, max_error_seconds=.2, packet_sha256='packet', packet_timeline_sha256='packet_timeline', video_sha256='video')
        inventory = {'r': {'ingest_status': 'complete', 'capture_status': 'completed', 'sync': {'alignment': alignment}, 'artifacts': files}}
        result = build_dataset([deepcopy(task)], [task], inventory, {'label_config': config}, 'ble')['records'][0]
        self.assertEqual(result['alignment']['video_sha256'], 'video')
        self.assertEqual(result['video_presentation']['download_url'], '/derived')
        self.assertEqual(result['segments'][0]['presentation_time_error_seconds'], 1/30)
        self.assertEqual(result['segments'][0]['sensor_intervals'][0]['max_error_seconds'], .2)
        changed = deepcopy(task)
        changed['meta']['annotation_coordinates']['frame_rate'] = 24
        with self.assertRaisesRegex(ValueError, 'FPS changed'):
            build_dataset([task], [changed], inventory, {'label_config': config})
