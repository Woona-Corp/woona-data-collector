import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from server.label_sync import ensure_storage, task, paged, sync


class LabelSyncTest(unittest.TestCase):
    def test_video_links_escape_file_names_and_titles(self):
        item = task("woona:one", "Dog <video>",
                    [{"name": "clip.mp4", "relative": "woona/Джена <видео>/clip.mp4", "size": 3, "sha256": "a" * 64}],
                    source="app", dog="Джена", date="2026-08-14")
        self.assertIn("%D0%94", item["data"]["video"])
        self.assertIn("%3C", item["data"]["video"])
        self.assertIn("&lt;video&gt;", item["data"]["html"])

    def test_community_task_pagination(self):
        with patch("server.label_sync.request_json", side_effect=[
            {"total": 2, "tasks": [{"id": 1}]},
            {"total": 2, "tasks": [{"id": 2}]},
        ]):
            self.assertEqual([row["id"] for row in paged("/api/tasks?project=1")], [1, 2])

    def test_storage_connections_are_idempotent(self):
        with patch("server.label_sync.request_json", side_effect=[
            [{"path": "/label-studio/files/woona"}],
        ]) as api:
            ensure_storage(1)
            api.assert_called_once_with("GET", "/api/storages/localfiles/?project=1")

    def test_parallel_sync_calls_do_not_create_duplicate_projects(self):
        active = 0
        peak = 0

        def run_once():
            nonlocal active, peak
            active += 1
            peak = max(peak, active)
            time.sleep(0.02)
            active -= 1
            return {}

        with patch("server.label_sync._sync_unlocked", side_effect=run_once):
            with ThreadPoolExecutor(max_workers=2) as pool:
                self.assertEqual(list(pool.map(lambda _: sync(), range(2))), [{}, {}])
        self.assertEqual(peak, 1)


if __name__ == "__main__":
    unittest.main()

class LabelPaginationFailureTest(unittest.TestCase):
    def test_repeated_or_empty_next_page_fails_instead_of_hanging_or_double_counting(self):
        for pages in [
            [{'total': 2, 'tasks': [{'id': 1}]}, {'total': 2, 'tasks': [{'id': 1}]}],
            [{'next': '/next', 'results': []}],
            [{'total': 1, 'tasks': []}],
            [{'total': '2', 'tasks': [{'id': 1}]}],
            [{'total': 2, 'tasks': [{'id': 1}, {'id': 1}]}],
        ]:
            with self.subTest(pages=pages), patch('server.label_sync.request_json', side_effect=pages):
                with self.assertRaises(RuntimeError):
                    paged('/api/tasks?project=21')

    def test_empty_project_is_not_a_failure(self):
        with patch('server.label_sync.request_json', return_value={'total': 0, 'tasks': []}):
            self.assertEqual(paged('/api/tasks?project=21'), [])

class ManagedTaskMetadataTest(unittest.TestCase):
    def test_questionnaire_edit_updates_metadata_without_changing_annotations_or_coordinates(self):
        from server.label_sync import managed_task_patch
        candidate = {'data': {'source_id': 'woona:r', 'recording_id': 'r', 'session': 'Corrected'},
            'meta': {'session_questionnaire': {'sessionLabel': 'Corrected'}}}
        current = {'data': {'source_id': 'woona:r', 'recording_id': 'r', 'session': 'Typo',
                            'video': '/original.mp4', 'custom': 'preserve'},
            'meta': {'session_questionnaire': {'sessionLabel': 'Typo'},
                     'annotation_coordinates': {'frame_rate': 24}, 'review': 'preserve'},
            'annotations': [{'id': 1, 'result': ['preserve']}], 'is_labeled': True}
        update = managed_task_patch(candidate, current)
        self.assertEqual(update['data']['session'], 'Corrected')
        self.assertEqual(update['data']['video'], '/original.mp4')
        self.assertEqual(update['data']['custom'], 'preserve')
        self.assertEqual(update['meta']['session_questionnaire'], {'sessionLabel': 'Corrected'})
        self.assertEqual(update['meta']['annotation_coordinates'], {'frame_rate': 24})
        self.assertEqual(update['meta']['review'], 'preserve')
        self.assertNotIn('annotations', update)
        self.assertIsNone(managed_task_patch(candidate, update))
        self.assertEqual(current['meta']['session_questionnaire'], {'sessionLabel': 'Typo'})

    def test_canonical_identity_conflict_is_not_silently_overwritten(self):
        from server.label_sync import managed_task_patch
        with self.assertRaisesRegex(RuntimeError, 'identity conflicts'):
            managed_task_patch({'data': {'recording_id': 'one'}, 'meta': {}},
                               {'data': {'recording_id': 'two'}, 'meta': {}})


class SyncListReuseTest(unittest.TestCase):
    def run_cycle(self, *, initial=None, refreshed=None, detail=None, expected=None):
        from copy import deepcopy
        from urllib.parse import parse_qs, urlsplit
        from server import label_sync
        self.expected = expected if expected is not None else [
            {'data': {'source_id': f'woona:{i}', 'recording_id': str(i), 'session': 'new'}, 'meta': {}}
            for i in range(201)]
        initial = initial if initial is not None else [dict(deepcopy(t), id=i + 1) for i, t in enumerate(self.expected)]
        refreshed = refreshed if refreshed is not None else initial
        walks, calls = [], []
        real_paged = label_sync.paged
        def paged(path):
            walks.append(path)
            return real_paged(path)
        def request(method, path, payload=None, **kwargs):
            calls.append((method, path, payload))
            if method == 'GET' and path.startswith('/api/tasks?'):
                page = int(parse_qs(urlsplit(path).query)['page'][0])
                rows = initial if len(walks) == 1 else refreshed
                return {'tasks': deepcopy(rows[(page - 1) * 100:page * 100]), 'total': len(rows)}
            if method == 'GET':
                return deepcopy(detail)
            return None
        self.walks, self.calls = walks, calls
        with patch.object(label_sync, 'active_project', return_value={'id': 21, 'label_config': '<View><Video frameRate="24"/></View>'}), \
             patch.object(label_sync, 'ensure_storage'), patch.object(label_sync, 'app_tasks', return_value=self.expected), \
             patch.object(label_sync, 'paged', side_effect=paged), patch.object(label_sync, 'request_json', side_effect=request), \
             patch.dict('os.environ', {'DATABASE_URL': 'unused-hermetic'}):
            return label_sync._sync_unlocked()

    def test_idle_uses_one_full_paginated_walk(self):
        self.assertEqual(self.run_cycle(), {'activity': (201, 201)})
        self.assertEqual(len(self.walks), 1)
        self.assertEqual(len(self.calls), 3)
        self.assertTrue(all(method == 'GET' and '/api/tasks?' in path for method, path, _ in self.calls))

    def test_import_refreshes_and_incomplete_import_still_fails(self):
        candidate = {'data': {'source_id': 'woona:one'}, 'meta': {}}
        current = dict(candidate, id=1)
        self.assertEqual(self.run_cycle(initial=[], refreshed=[current], expected=[candidate]), {'activity': (1, 1)})
        self.assertEqual(len(self.walks), 2)
        self.assertEqual([method for method, _, _ in self.calls], ['GET', 'POST', 'GET'])
        self.assertIn('annotation_coordinates', self.calls[1][2][0]['meta'])
        with self.assertRaisesRegex(RuntimeError, 'import not verified'):
            self.run_cycle(initial=[], refreshed=[], expected=[candidate])
        self.assertEqual(len(self.walks), 2)

    def test_duplicate_source_with_distinct_task_ids_still_fails(self):
        with self.assertRaisesRegex(RuntimeError, 'duplicate source IDs'):
            self.run_cycle(initial=[{'id': 1, 'data': {'source_id': 'woona:one'}, 'meta': {}},
                                    {'id': 2, 'data': {'source_id': 'woona:one'}, 'meta': {}}],
                           expected=[{'data': {'source_id': 'woona:one'}, 'meta': {}}])

    def test_fresh_detail_before_patch_preserves_concurrent_fields(self):
        candidate = {'data': {'source_id': 'woona:one', 'recording_id': 'one', 'session': 'new'}, 'meta': {}}
        listed = {'id': 7, 'data': {'source_id': 'woona:one', 'recording_id': 'one', 'session': 'old'}, 'meta': {}}
        detail = {'id': 7, 'data': {**listed['data'], 'custom': 'latest'},
                  'meta': {'review': 'latest', 'annotation_coordinates': {'frame_rate': 24}},
                  'annotations': [{'id': 33, 'result': ['latest']}], 'is_labeled': True}
        self.run_cycle(initial=[listed], expected=[candidate], detail=detail)
        self.assertEqual([method for method, _, _ in self.calls], ['GET', 'GET', 'PATCH'])
        payload = self.calls[-1][2]
        self.assertEqual(payload['data']['custom'], 'latest')
        self.assertEqual(payload['meta'], detail['meta'])
        self.assertNotIn('annotations', payload)
        self.assertEqual(detail['data']['session'], 'old')

    def test_fresh_detail_identity_conflicts_prevent_mutation(self):
        from copy import deepcopy
        candidate = {'data': {'source_id': 'woona:one', 'recording_id': 'one', 'dog_id': 'dog',
                              'dog_profile_version_id': 'profile', 'session': 'new'}, 'meta': {}}
        listed = {'id': 7, 'data': {**candidate['data'], 'session': 'old'}, 'meta': {}}
        for key in ('source_id', 'recording_id', 'dog_id', 'dog_profile_version_id'):
            with self.subTest(key=key):
                detail = deepcopy(listed)
                detail['data'][key] = 'conflicting'
                with self.assertRaisesRegex(RuntimeError, 'identity conflicts'):
                    self.run_cycle(initial=[listed], expected=[candidate], detail=detail)
                self.assertFalse(any(method == 'PATCH' for method, _, _ in self.calls))
