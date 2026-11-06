import unittest
from unittest.mock import patch

from jsonschema import ValidationError

from server.questionnaires import empty_sheet, validate_sheet
from server.label_sync import _sync_unlocked, active_project


class SheetContractTest(unittest.TestCase):
    def test_separate_dog_identity_and_optional_medical_answers(self):
        dog = empty_sheet("dog")
        dog.update(animalId="лилу", numberOrName="Лилу", diagnosesStatus="есть",
                   medications="Препарат 2 мг", specialistName="Иван")
        validate_sheet("dog", dog)
        dog["animalId"] = " "
        with self.assertRaises(ValidationError):
            validate_sheet("dog", dog)
        dog["animalId"] = "лилу"
        dog["weightKg"] = float("nan")
        with self.assertRaises(ValueError):
            validate_sheet("dog", dog)

    def test_surface_multiselect_and_invalid_measurements(self):
        session = empty_sheet("session")
        session.update(sessionLabel="2", plannedActivities=["Аллюр/движение"], surfaces=["Асфальт", "Грунт", "Трава"],
                       sensorPosition="Снизу на горле", sessionDate="2026-09-04", startTime="19:08")
        validate_sheet("session", session)
        session["surfaces"].append("Трава")
        with self.assertRaises(ValidationError):
            validate_sheet("session", session)
        session["surfaces"] = []
        session["sessionDate"] = "2026-02-30"
        with self.assertRaises(ValueError):
            validate_sheet("session", session)

    def test_only_existing_project_is_used_and_config_is_never_written(self):
        project = {"id": 21, "title": "Активность и Аллюр", "label_config":
                   '<View><TimelineLabels name="videoLabels" toName="video"><Label value="Шаг"/></TimelineLabels><Video name="video" value="$video"/></View>'}
        task = {"data": {"source_id": "woona:one", "video": "/video"}, "meta": {}}
        with patch("server.label_sync.request_json", return_value=project) as request:
            self.assertEqual(active_project()["labels"], ["Шаг"])
            self.assertEqual(request.call_args.args[0], "GET")
        with patch("server.label_sync.active_project", return_value=project), patch("server.label_sync.ensure_storage"), \
                patch.dict("os.environ", {"DATABASE_URL": "unused"}), \
                patch("server.label_sync.app_tasks", return_value=[task]), \
                patch("server.label_sync.paged", side_effect=[[], [task], [task]]) as pages, \
                patch("server.label_sync.request_json") as request:
            self.assertEqual(_sync_unlocked(), {"activity": (1, 1)})
            self.assertEqual(_sync_unlocked(), {"activity": (1, 1)})
            request.assert_called_once_with("POST", "/api/projects/21/import", [task])
            self.assertEqual(pages.call_count, 3, 'Import refresh plus one idle walk')
