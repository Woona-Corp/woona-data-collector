import unittest
from copy import deepcopy
from pathlib import Path
from fastapi import HTTPException
from starlette.requests import Request

from server.dashboard import KINDS, available_file, render, require_label_user, summarize


class DashboardTest(unittest.TestCase):
    def test_missing_file_is_unavailable_not_an_error(self):
        self.assertFalse(available_file(Path("/nonexistent-woona-dashboard-file"), 0))

    def test_record_counts_and_class_progress(self):
        records = [
            {"source_id": "woona:one", "origin": "Woona", "dog": "Тест <пёс>",
             "date": "2026-09-19", "ingest_status": "complete",
             "files": [{"name": "clip.mp4", "relative": "woona/clip.mp4", "size": 100, "available": True},
                       {"name": "sensor.binlog", "relative": "woona/sensor.binlog", "size": 20, "available": True}],
             "profile": {"version_id": "v1", "answers": {}},
             "session_questionnaire": {"answers": {}}},
            {"source_id": "drive:two", "origin": "Drive", "dog": "unknown",
             "date": "2026-09-18", "ingest_status": "verified",
             "files": [{"name": "sensor.binlog", "relative": "drive/raw/sensor.binlog", "size": 20,
                        "available": True}], "profile": None, "session_questionnaire": None},
        ]
        projects = [{"id": 21, "title": "Активность и Аллюр", "timeline_name": "videoLabels", "labels": ["Шаг"]}]
        tasks = {kind: [{"id": n, "data": {"source_id": "woona:one"},
                         "is_labeled": kind in ("source", "activity")}] for n, kind in enumerate(KINDS, 1)}
        annotations = {
            ("activity", 1): {"annotations": [{"result": [{"from_name": "videoLabels",
                                                           "value": {"timelinelabels": ["Шаг"]}},
                                                          {"from_name": "videoLabels",
                                                           "value": {"timelinelabels": ["Шаг"]}}]}]},
        }
        data = summarize(records, projects, tasks, annotations,
                         {"drive_files": 1, "drive_unindexed_files": 0,
                          "dogs": 1, "profile_versions": 1, "session_questionnaires": 1})
        self.assertEqual(data["totals"]["groups"], 2)
        self.assertEqual(data["totals"]["video_ble"], 1)
        self.assertEqual(data["totals"]["annotated_any"], 1)
        self.assertEqual(data["totals"]["annotated_all"], 1)
        self.assertEqual(data["categories"]["activity"]["classes"]["Шаг"],
                         {"records": 1, "segments": 2})
        self.assertEqual(data["totals"]["available_files"], 3)
        page = render(data, "<")
        self.assertIn("&lt;", page)
        self.assertNotIn("Тест <пёс>", page)
        self.assertIn('content="60"', page)
        self.assertIn('class="topbar"', page)
        self.assertIn('class="panel" id="data-manager"', page)
        self.assertIn('сессий: 1/1', page)
        self.assertIn('Найдено 1 из 2 групп', render(data, "", status="complete"))
        self.assertIn('Найдено 1 из 2 групп', render(data, "", status="incomplete"))
        self.assertIn('Найдено 0 из 2 групп', render(data, "", ble="absent"))
        self.assertIn('Показано 1–2 из 2', render(data, "", page=100))
        self.assertIn('Анкета старого формата', render(data, ""))
        self.assertIn('Открыть ↗', render(data, ""))
        pending = deepcopy(data)
        pending["records"][0]["tasks"] = {kind: None for kind in KINDS}
        pending["records"][0]["annotated_any"] = False
        self.assertIn('Анкета старого формата', render(pending, ""))
        self.assertIn('Найдено 0 из 2 групп', render(pending, "", status="ready"))

    def test_anonymous_user_cannot_read_dashboard(self):
        request = Request({"type": "http", "headers": [], "method": "GET", "path": "/dashboard"})
        with self.assertRaises(HTTPException) as raised:
            require_label_user(request)
        self.assertEqual(raised.exception.status_code, 401)


if __name__ == "__main__":
    unittest.main()

class DashboardReconciliationTest(unittest.TestCase):
    def summarize(self, tasks, extra=None):
        from server.eligibility import REQUIRED_ACTIVITY_ARTIFACTS
        records = [{'source_id': 'woona:one', 'origin': 'Woona', 'dog': 'Synthetic dog',
            'date': '2026-10-26', 'ingest_status': 'complete', 'capture_status': 'completed',
            'capture_error_code': None, 'profile': None,
            'session_questionnaire': {'answers': {'schemaVersion': 2, 'plannedActivities': ['Активность']}},
            'files': [{'name': kind, 'type': kind, 'relative': kind, 'size': 1, 'available': True}
                      for kind in REQUIRED_ACTIVITY_ARTIFACTS]}]
        return summarize(records,
            [{'id': 21, 'title': 'Activity', 'timeline_name': 'videoLabels', 'labels': []}],
            {'activity': tasks}, {}, {'dogs': 1, 'profile_versions': 1, 'session_questionnaires': 1,
                'drive_files': 0, 'drive_unindexed_files': 0, **(extra or {})})

    def test_duplicates_orphans_and_missing_import_are_independent(self):
        data = self.summarize([{'id': 1, 'data': {'source_id': 'woona:unknown'}},
                               {'id': 2, 'data': {'source_id': 'woona:unknown'}},
                               {'id': 3, 'data': {}}])
        self.assertEqual(data['reconciliation']['eligible_missing_tasks'], ['woona:one'])
        self.assertEqual(data['reconciliation']['duplicate_task_sources'], {'woona:unknown': [1, 2]})
        self.assertEqual(data['reconciliation']['unknown_task_sources'], ['None', 'woona:unknown'])
        self.assertIn('дубли источников 1', render(data, ''))

    def test_labeling_outage_does_not_look_like_zero_tasks_or_missing_imports(self):
        data = self.summarize([], {'label_service': {'available': False, 'message': 'Label Studio сейчас недоступна'}})
        self.assertIsNone(data['funnel']['in_label_studio'])
        self.assertIsNone(data['totals']['pending_import'])
        self.assertEqual(data['reconciliation']['status'], 'unavailable')
        self.assertEqual(data['reconciliation']['eligible_missing_tasks'], [])
        page = render(data, '')
        self.assertIn('Недоступно', page)
        self.assertIn('наличие задачи не проверено', page)
        self.assertNotIn('ожидают импорта 0', page)

    def test_transfer_diagnostics_survive_unavailable_label_service(self):
        from unittest.mock import patch
        from urllib.error import URLError
        from server.dashboard import load_dashboard
        with patch('server.dashboard.records_from_sources', return_value=([], {
                'dogs': 0, 'profile_versions': 0, 'session_questionnaires': 0})), \
             patch('server.dashboard.active_project', side_effect=URLError('private-token-must-not-escape')):
            data = load_dashboard()
        self.assertFalse(data['label_service']['available'])
        self.assertEqual(data['label_service']['errorType'], 'URLError')
        self.assertNotIn('private-token', str(data))


class DashboardPhysicalObservationTest(unittest.TestCase):
    """Synthetic joined history, never the application's real DB or storage."""
    def setUp(self):
        import sys
        from datetime import datetime, timezone
        from tempfile import TemporaryDirectory
        from types import ModuleType
        from unittest.mock import MagicMock, patch
        from server import dashboard
        self.dashboard = dashboard
        self.now = datetime(2026, 10, 26, 18, tzinfo=timezone.utc)
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.rows = []
        connection = MagicMock()
        def execute(statement):
            result = MagicMock()
            result.mappings.return_value.all.return_value = self.rows
            result.scalar_one.return_value = 1
            return result
        connection.execute.side_effect = execute
        engine = MagicMock()
        engine.connect.return_value.__enter__.return_value = connection
        app = ModuleType('server.app')
        app.STORAGE_ROOT, app.engine = self.root, engine
        fake_app = patch.dict(sys.modules, {'server.app': app})
        fake_app.start()
        self.addCleanup(fake_app.stop)
        dashboard.clear_label_summary_cache()
        self.addCleanup(dashboard.clear_label_summary_cache)

    def artifact(self, recording, identity, *, kind='video', status='available', relative=None):
        import hashlib
        import json
        row = dict(id=recording, started_at=self.now, ingest_status='complete',
            capture_status='completed', questionnaire_validation_state='complete',
            session_questionnaire={'schemaVersion': 2, 'plannedActivities': ['Активность']},
            capture_error_code=None, capture_error_message=None, server_verified_at=self.now,
            server_updated_at=self.now, alignment=None, number_or_name='Synthetic <dog>',
            profile_id='profile', profile_state='complete', profile_questionnaire={},
            artifact_type=kind, file_name=f'{identity}.mp4', expected_size_bytes=4,
            artifact_id=identity, server_relative_path=relative if relative is not None else identity,
            storage_status=status, reference_metadata=None, stored_size_bytes=4, sha256='a' * 64,
            verified_at=self.now, upload_updated_at=self.now, error_code=None, error_message=None)
        receipt = [{'id': identity, 'sha256': row['sha256'], 'size': 4}]
        row['receipt_sha256'] = hashlib.sha256(json.dumps(receipt, sort_keys=True,
            separators=(',', ':')).encode()).hexdigest()
        return row

    def test_available_history_observes_each_final_path_once(self):
        from collections import Counter
        from unittest.mock import patch
        self.rows = [self.artifact(str(r), f'file-{r}-{a}') for r in range(2) for a in range(8)]
        targets = {str(self.root / row['server_relative_path']) for row in self.rows}
        for target in targets:
            Path(target).write_bytes(b'xxxx')
        counts = Counter()
        real_stat, real_resolve = Path.stat, Path.resolve
        def stat(path, *args, **kwargs):
            if str(path) in targets:
                counts['stat'] += 1
            return real_stat(path, *args, **kwargs)
        def resolve(path, *args, **kwargs):
            if str(path) in targets:
                counts['resolve'] += 1
            return real_resolve(path, *args, **kwargs)
        with patch.object(Path, 'stat', stat), patch.object(Path, 'resolve', resolve):
            records, _ = self.dashboard.records_from_sources()
        self.assertEqual([len(record['files']) for record in records], [8, 8])
        self.assertEqual(counts, {'stat': 16, 'resolve': 16})

    def test_initialize_once_and_preserve_first_row_and_empty_left_join(self):
        from unittest.mock import Mock
        dates = Mock()
        dates.date.return_value = self.now.date()
        self.rows = [self.artifact(str(r), f'{r}-{a}') for r in range(2) for a in range(8)]
        self.rows.append(self.artifact('empty', 'empty', kind=None))
        for row in self.rows:
            row['started_at'] = dates
        self.rows[1]['number_or_name'] = 'later joined row must not replace first'
        records, _ = self.dashboard.records_from_sources()
        self.assertEqual([r['recording_id'] for r in records], ['0', '1', 'empty'])
        self.assertEqual([len(r['files']) for r in records], [8, 8, 0])
        self.assertEqual(records[0]['dog'], 'Synthetic <dog>')
        self.assertTrue(all(not any(key.startswith('_') for key in r) for r in records))
        self.assertEqual(dates.date.call_count, 3)

    def test_physical_matrix_json_html_receipt_and_next_request_with_warm_ls(self):
        import io
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        from unittest.mock import patch
        api = FastAPI()
        api.include_router(self.dashboard.router)
        project = {'id': 21, 'title': 'Activity', 'timeline_name': 'videoLabels', 'labels': []}
        headers = {'Cookie': 'session=synthetic'}
        real_stat = Path.stat
        def stat(path, *args, **kwargs):
            if path == self.root / 'unreadable':
                raise PermissionError('synthetic unreadable')
            return real_stat(path, *args, **kwargs)
        with patch.object(self.dashboard, 'active_project', return_value=project), \
             patch.object(self.dashboard, 'request_json', return_value={'tasks': [], 'total': 0}) as provider, \
             patch.object(self.dashboard, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(b'{"permissions":["projects.view"]}')), \
             patch.object(Path, 'stat', stat), TestClient(api) as client:
            for endpoint in ('/dashboard', '/dashboard/data'):
                self.assertEqual(client.get(endpoint).status_code, 401)
            for case, error in [('available', None), ('missing', 'stored_file_missing'),
                    ('truncated', 'stored_file_size_mismatch'), ('nonregular', 'stored_file_missing'),
                    ('unreadable', 'stored_file_unreadable'), ('outofroot', 'stored_file_missing'),
                    ('nullpath', 'stored_file_missing'), ('unverified', 'artifact_verification_missing')]:
                with self.subTest(case=case):
                    row = self.artifact(case, case)
                    self.rows = [row]
                    path = self.root / case
                    if case in ('available', 'unreadable', 'unverified'):
                        path.write_bytes(b'xxxx')
                    elif case == 'truncated':
                        path.write_bytes(b'x')
                    elif case == 'nonregular':
                        path.mkdir()
                    elif case == 'outofroot':
                        path.symlink_to(self.root.parent / 'synthetic-nonexistent-outside')
                    elif case == 'nullpath':
                        row['server_relative_path'] = None
                    if case == 'unverified':
                        row['verified_at'] = None
                    response = client.get('/dashboard/data', headers=headers)
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(response.headers['cache-control'], 'no-store')
                    data = response.json()
                    record = data['records'][0]
                    self.assertEqual(record['files'][0]['available'], case in ('available', 'unverified'))
                    self.assertEqual(record['server_status']['artifacts'][0]['errorCode'], error)
                    self.assertEqual(record['server_status']['transfer']['receiptVerified'], case == 'available')
                    page = client.get('/dashboard', headers=headers)
                    self.assertEqual(page.status_code, 200)
                    self.assertEqual(page.headers['cache-control'], 'no-store')
                    self.assertIn('Synthetic &lt;dog&gt;', page.text)
            self.rows = [self.artifact('fresh', 'fresh')]
            path = self.root / 'fresh'
            path.write_bytes(b'xxxx')
            first = client.get('/dashboard/data', headers=headers).json()
            self.assertTrue(first['records'][0]['server_status']['transfer']['receiptVerified'])
            for content in (b'x', None):
                path.unlink() if content is None else path.write_bytes(content)
                second = client.get('/dashboard/data', headers=headers).json()
                self.assertTrue(second['label_service']['cached'])
                self.assertFalse(second['records'][0]['files'][0]['available'])
                self.assertFalse(second['records'][0]['server_status']['transfer']['receiptVerified'])
            self.assertEqual(provider.call_count, 1)
            for endpoint in ('/dashboard', '/dashboard/data'):
                with patch.object(self.dashboard, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(b'{"permissions":[]}')):
                    self.assertEqual(client.get(endpoint, headers=headers).status_code, 403)
                from urllib.error import HTTPError
                with patch.object(self.dashboard, 'urlopen', side_effect=HTTPError('synthetic', 401, 'denied', {}, None)):
                    self.assertEqual(client.get(endpoint, headers=headers).status_code, 401)
