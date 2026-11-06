"""Hermetic Label Studio workload budgets; file totals remain fresh per request."""
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from unittest.mock import patch

from server import dashboard


class DashboardBudgetTest(unittest.TestCase):
    def setUp(self):
        if hasattr(dashboard, 'clear_label_summary_cache'):
            dashboard.clear_label_summary_cache()
        self.project = {'id': 21, 'title': 'Activity', 'timeline_name': 'videoLabels', 'labels': ['Walk']}
        self.extra = {'dogs': 0, 'profile_versions': 0, 'session_questionnaires': 0,
                      'drive_files': 0, 'drive_unindexed_files': 0}
        self.tasks = [{'id': number, 'data': {'source_id': f'woona:{number}'}, 'is_labeled': True,
                       'annotations': [{'result': [{'from_name': 'videoLabels',
                                                   'value': {'timelinelabels': ['Walk']}}]}]}
                      for number in range(1000)]
        self.calls = []

    def request(self, method, path, **kwargs):
        self.calls.append(path)
        if path.startswith('/api/tasks?'):
            from urllib.parse import parse_qs, urlsplit
            page = int(parse_qs(urlsplit(path).query)['page'][0])
            return {'tasks': self.tasks[(page - 1) * 100:page * 100], 'total': len(self.tasks)}
        number = int(path.rsplit('/', 1)[-1])
        return self.tasks[number]

    def patches(self):
        # paged is used only by the original implementation; the replacement must
        # enforce a whole-refresh budget instead of invoking its unbounded loop.
        return (patch.object(dashboard, 'records_from_sources', side_effect=lambda: ([], self.extra.copy())),
                patch.object(dashboard, 'active_project', return_value=self.project),
                patch.object(dashboard, 'paged', return_value=self.tasks, create=True),
                patch.object(dashboard, 'request_json', side_effect=self.request))

    def test_thousand_labeled_tasks_use_list_annotations_not_thousand_detail_requests(self):
        sources, project, paged, request = self.patches()
        with sources as source_call, project, paged, request:
            first = dashboard.load_dashboard()
            second = dashboard.load_dashboard()
        self.assertLessEqual(len(self.calls), 12, f'Unbounded Label Studio calls: {len(self.calls)}')
        self.assertEqual(source_call.call_count, 2, 'Owner requires fresh physical file totals on every request')
        for data in (first, second):
            self.assertEqual(data['categories']['activity']['classes']['Walk'], {'records': 1000, 'segments': 1000})
            self.assertTrue(data['label_service']['available'])
            self.assertIn('checkedAtUtc', data['label_service'])
            self.assertIn('снимок Label Studio', dashboard.render(data, ''))

    def test_missing_list_annotations_has_bounded_fallback_not_false_zero(self):
        for task in self.tasks:
            task.pop('annotations')
        sources, project, paged, request = self.patches()
        with sources, project, paged, request:
            data = dashboard.load_dashboard()
        self.assertLessEqual(len(self.calls), 22, f'Unbounded task-detail fallback: {len(self.calls)}')
        self.assertFalse(data['label_service']['available'])
        self.assertIsNone(data['totals']['pending_import'])
        self.assertIsNone(data['funnel']['with_annotations'])

    def test_whole_refresh_deadline_stops_new_requests(self):
        current = [0.0]
        def slow_request(*args, **kwargs):
            result = self.request(*args, **kwargs)
            current[0] += 2.0
            return result
        sources, project, paged, _ = self.patches()
        with sources, project, paged, patch.object(dashboard, 'request_json', side_effect=slow_request), \
             patch('time.monotonic', side_effect=lambda: current[0]):
            data = dashboard.load_dashboard()
        self.assertLessEqual(len(self.calls), 3)
        self.assertFalse(data['label_service']['available'])

    def test_oversized_provider_reply_is_unavailable_not_retained(self):
        self.tasks[0]['annotations'][0]['result'][0]['value']['untrusted'] = 'x' * (3 * 1024 * 1024)
        sources, project, paged, request = self.patches()
        with sources, project, paged, request:
            data = dashboard.load_dashboard()
        self.assertFalse(data['label_service']['available'])
        self.assertIsNone(data['totals']['pending_import'])

    def test_malformed_nested_provider_shapes_are_unavailable_not_dashboard_errors(self):
        malformed = [
            {'id': [], 'data': {}, 'is_labeled': True, 'annotations': []},
            {'id': 1, 'data': {'source_id': {}}, 'is_labeled': True, 'annotations': []},
            {'id': 1, 'data': {}, 'is_labeled': True, 'annotations': [None]},
            {'id': 1, 'data': {}, 'is_labeled': True, 'annotations': [{'result': None}]},
            {'id': 1, 'data': {}, 'is_labeled': True, 'annotations': [{'result': [None]}]},
            {'id': 1, 'data': {}, 'is_labeled': True, 'annotations': [{'result': [
                {'from_name': 'videoLabels', 'value': None}]}]},
            {'id': 1, 'data': {}, 'is_labeled': True, 'annotations': [{'result': [
                {'from_name': 'videoLabels', 'value': {'timelinelabels': 'Walk'}}]}]},
            {'id': 1, 'data': {}, 'is_labeled': True, 'annotations': [{'result': [
                {'from_name': 'videoLabels', 'value': {'timelinelabels': [{}]}}]}]},
        ]
        for task in malformed:
            with self.subTest(task=task):
                dashboard.clear_label_summary_cache()
                self.tasks = [task]
                sources, project, paged, request = self.patches()
                with sources, project, paged, request:
                    data = dashboard.load_dashboard()
                self.assertFalse(data['label_service']['available'])
                self.assertIsNone(data['funnel']['with_annotations'])

    def test_concurrent_refresh_does_not_start_another_remote_scan(self):
        entered, release = threading.Event(), threading.Event()
        def delayed_project(*args, **kwargs):
            entered.set()
            release.wait(3)
            return self.project
        sources, _, paged, request = self.patches()
        with sources, paged, request, patch.object(dashboard, 'active_project', side_effect=delayed_project), \
             ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(dashboard.load_dashboard)
            self.assertTrue(entered.wait(1))
            second = pool.submit(dashboard.load_dashboard)
            try:
                try:
                    immediate = second.result(timeout=0.2)
                except FutureTimeout:
                    self.fail('Concurrent dashboard waited for or duplicated a full Label Studio refresh')
                self.assertFalse(immediate['label_service']['available'])
            finally:
                release.set()
                first.result(timeout=3)
                second.result(timeout=3)


if __name__ == '__main__':
    unittest.main()
