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
