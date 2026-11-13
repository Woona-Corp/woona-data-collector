"""Catalog HTTP contract; hermetic data, no production DB or user credentials."""
import io
import unittest
import uuid
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from server import dashboard


class CatalogRoutesTest(unittest.TestCase):
    def setUp(self):
        api = FastAPI()
        api.include_router(dashboard.router)
        self.client = TestClient(api)
        self.addCleanup(self.client.close)
        self.recording_id = str(uuid.uuid4())
        records = [{
            'source_id': 'woona:' + self.recording_id, 'recording_id': self.recording_id,
            'origin': 'Woona', 'dog': 'Тестовый пёс', 'dog_id': str(uuid.uuid4()),
            'account_id': 'team-one', 'account_name': 'team-one', 'source': 'live',
            'date': '2026-11-09', 'started_at': '2026-11-09T12:00:00+00:00',
            'ended_at': None, 'duration_seconds': None, 'session_label': 'Тест',
            'ingest_status': 'uploading', 'capture_status': 'interrupted',
            'capture_error_code': None, 'capture_error_message': None, 'files': [],
            'profile': None, 'session_questionnaire': {'answers': {}},
        }]
        self.data = dashboard.summarize(records,
            [{'id': 21, 'title': 'Activity', 'timeline_name': 'videoLabels', 'labels': []}],
            {'activity': []}, {}, {'dogs': 1, 'profile_versions': 0, 'session_questionnaires': 0})
        loader = patch.object(dashboard, 'load_dashboard', return_value=self.data)
        self.loader = loader.start()
        self.addCleanup(loader.stop)
        self.headers = {'Cookie': 'session=synthetic'}
        provider = patch.object(dashboard, 'urlopen', side_effect=lambda *args, **kwargs:
                                io.BytesIO(b'{"permissions":["projects.view"]}'))
        provider.start()
        self.addCleanup(provider.stop)

    def test_all_read_pages_require_label_studio_session(self):
        for path in ('/dashboard', '/dashboard/data', '/dashboard/recordings/' + self.recording_id):
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 401)
        self.loader.assert_not_called()
        with patch.object(dashboard, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(b'{"permissions":[]}')):
            self.assertEqual(self.client.get('/dashboard/recordings/' + self.recording_id,
                                             headers=self.headers).status_code, 403)
        self.loader.assert_not_called()

    def test_catalog_detail_and_json_are_no_store(self):
        for path in ('/dashboard', '/dashboard/data', '/dashboard/recordings/' + self.recording_id):
            with self.subTest(path=path):
                response = self.client.get(path, headers=self.headers)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.headers['cache-control'], 'no-store')
                self.assertIn('Тестовый пёс', response.text)
        self.assertEqual(self.loader.call_count, 3, 'Each read gets a fresh physical-file snapshot')
        self.assertIsNone(self.client.get('/dashboard/data', headers=self.headers).json()
                          ['records'][0]['duration_seconds'])

    def test_unknown_or_invalid_recording_has_no_detail(self):
        self.assertEqual(self.client.get('/dashboard/recordings/' + str(uuid.uuid4()),
                                         headers=self.headers).status_code, 404)
        self.loader.reset_mock()
        self.assertEqual(self.client.get('/dashboard/recordings/not-a-uuid',
                                         headers=self.headers).status_code, 422)
        self.loader.assert_not_called()

    def test_new_filters_validate_and_preserve_existing_statuses(self):
        with patch.object(dashboard, 'render', return_value='catalog') as renderer:
            response = self.client.get('/dashboard', headers=self.headers, params={
                'q': 'пёс', 'status': 'upload_problem', 'ble': 'absent', 'page': 2,
                'account': '__unassigned__', 'date_from': '2026-11-01', 'date_to': '2026-11-09'})
            self.assertEqual(response.status_code, 200)
            renderer.assert_called_once_with(self.data, 'пёс', 'upload_problem', 'absent', 2,
                                             '__unassigned__', '2026-11-01', '2026-11-09')
        response = self.client.get('/dashboard', headers=self.headers, params={
            'q': '', 'account': '', 'date_from': '', 'date_to': '', 'status': 'all', 'ble': 'all'})
        self.assertEqual(response.status_code, 200, 'Empty date inputs from HTML forms must be accepted')
        for status in ('all', 'ready', 'in_progress', 'complete', 'incomplete',
                       'upload_problem', 'no_video', 'awaiting_annotation'):
            with self.subTest(status=status):
                self.assertEqual(self.client.get('/dashboard', headers=self.headers,
                                                 params={'status': status}).status_code, 200)

    def test_invalid_filters_rejected_before_snapshot(self):
        for params in ({'date_from': 'not-a-date'}, {'account': 'x' * 65}, {'page': 0}, {'status': 'arbitrary'},
                       {'ble': 'arbitrary'}, {'q': 'x' * 101}):
            with self.subTest(params=params):
                self.assertEqual(self.client.get('/dashboard', params=params,
                                                 headers=self.headers).status_code, 422)
        self.loader.assert_not_called()


if __name__ == '__main__':
    unittest.main()
