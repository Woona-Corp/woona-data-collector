import unittest
from server.eligibility import REQUIRED_ACTIVITY_ARTIFACTS, activity_exclusion_reasons
from server.dashboard import summarize, render


class EligibilityTest(unittest.TestCase):
    def test_upload_complete_does_not_hide_camera_failure(self):
        reasons = activity_exclusion_reasons('complete', 'completed', 'camera_failed',
            {'schemaVersion': 2, 'plannedActivities': ['Активность']}, REQUIRED_ACTIVITY_ARTIFACTS)
        self.assertEqual(reasons, ['Ошибка захвата: camera_failed'])

    def test_heart_and_incomplete_video_are_explained_separately(self):
        reasons = activity_exclusion_reasons('uploading', 'completed', None,
            {'schemaVersion': 2, 'sessionKind': 'heart'}, REQUIRED_ACTIVITY_ARTIFACTS - {'video'})
        self.assertIn('Загрузка не завершена', reasons)
        self.assertTrue(any('сердцебиения' in reason for reason in reasons))
        self.assertIn('Недостающие файлы: video', reasons)

    def test_only_complete_activity_bundle_is_admitted(self):
        self.assertEqual([], activity_exclusion_reasons('complete', 'completed', None,
            {'schemaVersion': 2, 'plannedActivities': ['Аллюр/движение']}, REQUIRED_ACTIVITY_ARTIFACTS))

    def test_dashboard_funnel_distinguishes_upload_capture_and_missing_import(self):
        def record(identity, error=None, uploaded=True):
            return {'source_id': 'woona:' + identity, 'origin': 'Woona', 'dog': identity,
                'date': '2026-10-26', 'ingest_status': 'complete' if uploaded else 'uploading',
                'capture_status': 'completed', 'capture_error_code': error,
                'files': [{'type': k, 'name': k, 'relative': k, 'size': 10, 'available': uploaded}
                          for k in REQUIRED_ACTIVITY_ARTIFACTS],
                'profile': None, 'session_questionnaire': {'answers':
                    {'schemaVersion': 2, 'plannedActivities': ['Активность']}}}
        records = [record('ready'), record('failed', '<camera_failed>'), record('pending', uploaded=False)]
        data = summarize(records, [{'id': 21, 'title': 'Activity', 'timeline_name': 'videoLabels', 'labels': []}],
            {'activity': []}, {}, {'dogs': 3, 'profile_versions': 3, 'session_questionnaires': 3, 'drive_files': 0, 'drive_unindexed_files': 0})
        self.assertEqual(data['funnel'], {'attempts': 3, 'capture_ok': 2, 'uploaded': 2,
            'eligible': 1, 'in_label_studio': 0, 'with_annotations': 0})
        self.assertEqual(data['totals']['pending_import'], 1)
        page = render(data, '')
        self.assertIn('Ошибка захвата: &lt;camera_failed&gt;', page)
        self.assertIn('Загрузка не завершена', page)
        self.assertNotIn('Ошибка захвата: <camera_failed>', page)
