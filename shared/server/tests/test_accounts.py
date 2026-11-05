"""Account selection, explicit legacy linking and revision-safe questionnaire edits."""
import copy
import json
import unittest
import uuid

from server.tests import test_api
from server.tests.test_api import SECOND_TOKEN, expect_http
from server.tests.test_heart import heart_manifest, request


class AccountApiTest(unittest.TestCase):
    def test_historical_v1_edit_preserves_schema_and_rejects_upgrade(self):
        manifest, _ = heart_manifest()
        original = test_api.session_questionnaire()
        manifest["recording"].update(questionnaireSchemaVersion=1, sessionQuestionnaire=original, videoRequested=False)
        manifest["artifacts"] = [a for a in manifest["artifacts"] if a["type"] != "video"]
        recording = str(uuid.uuid4())
        request("PUT", "/v1/recordings/" + recording, manifest, headers=self.headers)
        path = "/v1/recordings/" + recording + "/questionnaire"
        upgraded = dict(original, schemaVersion=2, plannedActivities=["Покой"])
        rejected = expect_http(422, "PUT", path, {"expectedRevision": 1, "questionnaire": upgraded}, headers=self.headers)
        self.assertEqual("immutable_capture_field", rejected["code"])
        self.assertEqual("schemaVersion", rejected["field"])
        edited = dict(original, sessionLabel="Edited historical v1")
        saved = json.loads(request("PUT", path, {"expectedRevision": 1, "questionnaire": edited}, headers=self.headers)[2])
        self.assertEqual(edited, saved["sessionQuestionnaire"])
        self.assertEqual(2, saved["questionnaireRevision"])

    @classmethod
    def setUpClass(cls):
        test_api.ApiIntegrationTest.setUpClass()

    def setUp(self):
        self.account = "operator-" + uuid.uuid4().hex
        self.other = "operator-" + uuid.uuid4().hex
        self.headers = {"X-Woona-Account": self.account}
        self.other_headers = {"X-Woona-Account": self.other}

    def create_recording(self, headers=None, activity=False):
        manifest, contents = heart_manifest()
        if activity:
            questionnaire = manifest["recording"]["sessionQuestionnaire"]
            questionnaire["sessionKind"] = "activity"
            questionnaire.pop("heartQuestionnaire")
        recording = str(uuid.uuid4())
        request("PUT", "/v1/recordings/" + recording, manifest, headers=headers)
        return recording, manifest, contents

    def detail(self, recording, headers=None, token=test_api.TOKEN):
        return json.loads(request("GET", "/v1/recordings/" + recording,
                                  headers=headers or self.headers, token=token)[2])

    def test_identifier_normalization_and_validation(self):
        raw = self.account.upper()
        body = json.loads(request("PUT", "/v1/accounts/" + raw, {})[2])
        self.assertEqual({"identifier": self.account}, body)
        self.assertEqual(body, json.loads(request("PUT", "/v1/accounts/" + raw, {})[2]))
        for invalid in ("", "two words", "a" * 65, ".leading", "a/b"):
            expect_http(422, "GET", "/v1/dogs", headers={"X-Woona-Account": invalid})
        expect_http(401, "PUT", "/v1/accounts/" + self.account, {}, token="invalid")

    def test_new_dogs_scoped_lists_details_artifacts_and_other_devices(self):
        recording, manifest, _ = self.create_recording(self.headers)
        other_recording, other_manifest, _ = self.create_recording(self.other_headers)
        dog = manifest["dog"]["id"]
        listed = json.loads(request("GET", "/v1/dogs?limit=1", headers=self.headers)[2])
        self.assertEqual([dog], [item["id"] for item in listed["items"]])
        self.assertIsNone(listed["nextCursor"])
        self.assertEqual(self.account, listed["items"][0]["accountId"])
        detail = self.detail(recording, token=SECOND_TOKEN)
        self.assertEqual(self.account, detail["accountId"])
        self.assertEqual(1, detail["questionnaireRevision"])
        for path in (f"/v1/dogs/{dog}", f"/v1/dogs/{dog}/recordings",
                     f"/v1/recordings/{recording}", f"/v1/recordings/{recording}/sync-status",
                     f"/v1/recordings/{uuid.UUID(recording).hex}",
                     f'/v1/artifacts/{manifest["artifacts"][0]["id"]}/content'):
            expect_http(404, "GET", path, headers=self.other_headers)
            expect_http(404, "GET", path)
        self.assertEqual([recording], [item["id"] for item in json.loads(request("GET", f"/v1/dogs/{dog}/recordings", headers=self.headers)[2])["items"]])
        expect_http(404, "PUT", "/v1/recordings/" + other_recording, other_manifest, headers=self.headers)
        # A new recording under an existing foreign dog must also be rejected.
        expect_http(404, "PUT", "/v1/recordings/" + str(uuid.uuid4()), other_manifest, headers=self.headers)

    def test_old_dog_link_is_explicit_atomic_and_links_all_sessions(self):
        recording, manifest, _ = self.create_recording()
        dog = manifest["dog"]["id"]
        second = copy.deepcopy(manifest)
        second["artifacts"] = [dict(artifact, id=str(uuid.uuid4())) for artifact in second["artifacts"]]
        second_recording = str(uuid.uuid4())
        request("PUT", "/v1/recordings/" + second_recording, second)
        path = f"/v1/dogs/{dog}/account"
        expect_http(404, "GET", f"/v1/dogs/{dog}", headers=self.headers)
        expect_http(404, "PUT", "/v1/recordings/" + recording, manifest, headers=self.headers)
        expect_http(422, "PUT", path, {"accountId": self.account})
        self.assertEqual(None, json.loads(request("GET", f"/v1/dogs/{dog}")[2])["accountId"])
        for _ in range(2):
            result = json.loads(request("PUT", path, {"accountId": self.account}, headers=self.headers)[2])
            self.assertEqual(self.account, result["accountId"])
        for identity in (recording, second_recording):
            self.assertEqual(self.account, self.detail(identity)["accountId"])
        expect_http(409, "PUT", path, {"accountId": self.other}, headers=self.other_headers)
        expect_http(404, "GET", f"/v1/dogs/{dog}")

    def test_activity_and_heart_edits_preserve_bytes_manifest_and_receipt(self):
        for activity in (True, False):
            with self.subTest(activity=activity):
                recording, manifest, contents = self.create_recording(self.headers, activity=activity)
                path = "/v1/recordings/" + recording
                for artifact in manifest["artifacts"]:
                    artifact_path = f'/v1/artifacts/{artifact["id"]}'
                    request("PATCH", artifact_path + "/content", contents[artifact["type"]],
                            headers={**self.headers, "Upload-Offset": "0"})
                    request("POST", artifact_path + "/complete", {}, headers=self.headers)
                receipt = json.loads(request("POST", path + "/complete", {}, headers=self.headers)[2])
                before = self.detail(recording)
                edited = copy.deepcopy(before["sessionQuestionnaire"])
                edited["sessionLabel"] = "Исправлено после записи"
                saved = json.loads(request("PUT", path + "/questionnaire",
                    {"expectedRevision": 1, "questionnaire": edited}, headers=self.headers, token=SECOND_TOKEN)[2])
                self.assertEqual(2, saved["questionnaireRevision"])
                self.assertEqual(edited, saved["sessionQuestionnaire"])
                self.assertEqual(edited["sessionLabel"], saved["sessionLabel"])
                for field in ("sync", "artifacts", "profileVersion", "startedAtUtc", "endedAtUtc", "appVersion", "videoRequested"):
                    self.assertEqual(before[field], saved[field], field)
                # Retrying original immutable upload must not undo accepted edits.
                request("PUT", path, manifest, headers=self.headers)
                self.assertEqual(edited, self.detail(recording)["sessionQuestionnaire"])
                after = json.loads(request("POST", path + "/complete", {}, headers=self.headers)[2])
                self.assertEqual(receipt["receiptSha256"], after["receiptSha256"])
                for artifact in manifest["artifacts"]:
                    data = request("GET", f'/v1/artifacts/{artifact["id"]}/content', headers=self.headers)[2]
                    self.assertEqual(contents[artifact["type"]], data)

    def test_stale_invalid_and_foreign_edits_leave_questionnaire_unchanged(self):
        recording, manifest, _ = self.create_recording(self.headers)
        path = "/v1/recordings/" + recording + "/questionnaire"
        original = manifest["recording"]["sessionQuestionnaire"]
        payload = {"expectedRevision": 1, "questionnaire": copy.deepcopy(original)}
        expect_http(404, "PUT", path, payload, headers=self.other_headers)
        for key, value in (("videoRequested", False), ("sessionKind", "activity")):
            invalid = copy.deepcopy(payload)
            invalid["questionnaire"][key] = value
            if key == "sessionKind":
                invalid["questionnaire"].pop("heartQuestionnaire", None)
            self.assertEqual("immutable_capture_field", expect_http(422, "PUT", path, invalid, headers=self.headers)["code"])
        invalid = copy.deepcopy(payload)
        invalid["questionnaire"]["heartQuestionnaire"] = {}
        expect_http(422, "PUT", path, invalid, headers=self.headers)
        self.assertEqual(original, self.detail(recording)["sessionQuestionnaire"])
        request("PUT", path, payload, headers=self.headers)
        payload["questionnaire"]["sessionLabel"] = "Stale overwrite"
        error = expect_http(409, "PUT", path, payload, headers=self.headers, token=SECOND_TOKEN)
        self.assertEqual("questionnaire_revision_conflict", error["code"])
        self.assertEqual(2, error["serverRevision"])
        self.assertEqual(original, self.detail(recording)["sessionQuestionnaire"])
