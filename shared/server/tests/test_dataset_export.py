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
        task['data']['dog_id'] = 'other-dog'
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            build_dataset([canonical], [task], inventory, project)


if __name__ == '__main__':
    unittest.main()
