"""Regression coverage for phone-to-server hardening fixes."""
import hashlib
import json
import threading
import unittest
import urllib.error
import uuid
from pathlib import Path

from sqlalchemy import text

from server.app import STORAGE_ROOT, engine
from server.tests.test_api import (
    DEVICE,
    canonical_hash,
    dog_questionnaire,
    expect_http,
    patch_bytes,
    request,
    session_questionnaire,
)


def _profile(dog_id: str, profile_id: str, name: str = "Hardening dog", expected: int = 0):
    questionnaire = dog_questionnaire(name)
    return {
        "dog": {"id": dog_id, "numberOrName": name, "expectedRevision": expected},
        "profileVersion": {
            "id": profile_id,
            "schemaVersion": 1,
            "validationState": "complete",
            "questionnaire": questionnaire,
            "contentSha256": canonical_hash(questionnaire),
            "clientCreatedAtUtc": "2026-07-30T17:00:00Z",
        },
    }


def _manifest(dog_id: str, profile_id: str, recording_id: str, label: str = "Hardening"):
    contents = {
        "packet": b"packet",
        "packet_timeline": b"timeline",
        "raw": b"raw",
        "diagnostic": b"diag",
        "sync": b'{"schemaVersion":2}',
    }
    extensions = {
        "packet": "bin",
        "packet_timeline": "bin",
        "raw": "binlog",
        "diagnostic": "log",
        "sync": "json",
    }
    artifacts = []
    for kind, content in contents.items():
        artifact_id = str(uuid.uuid4())
        artifacts.append(
            {
                "id": artifact_id,
                "type": kind,
                "fileName": f"{kind}-{artifact_id[:8]}.{extensions[kind]}",
                "mimeType": {
                    "diagnostic": "text/plain",
                    "sync": "application/json",
                }.get(kind, "application/octet-stream"),
                "sizeBytes": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
                "clientCreatedAtUtc": "2026-07-30T17:00:00Z",
            }
        )
    profile = _profile(dog_id, profile_id)
    manifest = {
        "schemaVersion": 1,
        "captureDeviceId": DEVICE,
        "dog": profile["dog"],
        "dogProfileVersion": profile["profileVersion"],
        "recording": {
            "source": "live",
            "captureStatus": "completed",
            "startedAtUtc": "2026-07-30T17:00:00Z",
            "endedAtUtc": "2026-07-30T17:01:00Z",
            "timezone": "Europe/Moscow",
            "sessionLabel": label,
            "videoRequested": False,
            "sensorHardwareId": "hardening",
            "appVersion": "test",
            "protocolVersion": "1",
            "questionnaireSchemaVersion": 1,
            "questionnaireValidationState": "complete",
            "sessionQuestionnaire": session_questionnaire(),
        },
        "sync": {
            "schemaVersion": 2,
            "monotonicClock": "android.elapsedRealtimeNanos",
            "sessionZeroAtUtc": "2026-07-30T17:00:00Z",
            "sessionZeroWallClockMs": 1785430800000,
            "sessionZeroMonotonicNs": 1000000000,
            "sessionZeroUncertaintyNs": 1000,
            "firstSensorPacketMonotonicNs": 1001000000,
            "videoFirstFrameMonotonicNs": 1002000000,
            "videoOffsetFromSensorNs": 1000000,
            "cameraClockQuality": "unavailable",
            "sensorClockQuality": "first_packet_arrival",
            "overallSyncQuality": "arrival_aligned",
            "calibrationOffsetNs": 0,
        },
        "artifacts": artifacts,
    }
    return manifest, contents


class PipelineHardeningTest(unittest.TestCase):
    def _create_recording(self):
        dog_id, profile_id, recording_id = (str(uuid.uuid4()) for _ in range(3))
        assert request(
            "PUT",
            f"/v1/dogs/{dog_id}/profile-versions/{profile_id}",
            _profile(dog_id, profile_id),
        )[0] == 200
        manifest, contents = _manifest(dog_id, profile_id, recording_id)
        assert request("PUT", f"/v1/recordings/{recording_id}", manifest)[0] == 200
        return dog_id, profile_id, recording_id, manifest, contents

    def _upload_all(self, recording_id, manifest, contents):
        for artifact in manifest["artifacts"]:
            patch_bytes(artifact["id"], 0, contents[artifact["type"]])
            assert request("POST", f"/v1/artifacts/{artifact['id']}/complete", {})[0] == 200
        assert request("POST", f"/v1/recordings/{recording_id}/complete", {})[0] == 200

    def test_manifest_capture_replay_conflict(self):
        _, _, recording_id, manifest, _ = self._create_recording()
        changed = json.loads(json.dumps(manifest))
        changed["recording"]["startedAtUtc"] = "2026-07-30T17:00:30Z"
        error = expect_http(409, "PUT", f"/v1/recordings/{recording_id}", changed)
        assert error["code"] == "immutable_recording_conflict"
        assert "started_at_utc" in error["fields"]

    def test_missing_verified_file_blocks_head_and_complete(self):
        _, _, recording_id, manifest, contents = self._create_recording()
        self._upload_all(recording_id, manifest, contents)
        artifact_id = manifest["artifacts"][2]["id"]
        with engine.connect() as connection:
            relative = connection.execute(
                text("SELECT server_relative_path FROM artifacts WHERE id=:id"),
                {"id": artifact_id},
            ).scalar_one()
        (Path(STORAGE_ROOT) / relative).unlink()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            request("HEAD", f"/v1/artifacts/{artifact_id}/content")
        assert caught.exception.code == 409
        error = expect_http(409, "POST", f"/v1/artifacts/{artifact_id}/complete", {})
        assert error["code"] == "stored_file_missing"
        error = expect_http(409, "POST", f"/v1/recordings/{recording_id}/complete", {})
        assert error["code"] == "stored_file_missing"

    def test_retired_artifact_keeps_verified_receipt(self):
        _, _, recording_id, manifest, contents = self._create_recording()
        self._upload_all(recording_id, manifest, contents)
        retired_id = manifest["artifacts"][0]["id"]
        with engine.begin() as connection:
            connection.execute(
                text(
                    "INSERT INTO retired_entities(kind,id_sha256) VALUES('artifact',:hash) "
                    "ON CONFLICT DO NOTHING"
                ),
                {"hash": hashlib.sha256(retired_id.lower().encode()).hexdigest()},
            )
        status, _, _ = request("POST", f"/v1/recordings/{recording_id}/complete", {})
        assert status == 200
        _, _, body = request("GET", f"/v1/recordings/{recording_id}/sync-status")
        payload = json.loads(body)
        assert payload["transfer"]["status"] == "verified"
        assert payload["transfer"]["receiptVerified"] is True
        assert all(item["id"] != retired_id for item in payload["artifacts"])

    def test_concurrent_profile_and_recording_no_deadlock(self):
        for _ in range(6):
            dog_id = str(uuid.uuid4())
            profile_id = str(uuid.uuid4())
            assert request(
                "PUT",
                f"/v1/dogs/{dog_id}/profile-versions/{profile_id}",
                _profile(dog_id, profile_id),
            )[0] == 200
            other_profile = str(uuid.uuid4())
            recording_id = str(uuid.uuid4())
            statuses = {}

            def profile_write():
                try:
                    statuses["profile"] = request(
                        "PUT",
                        f"/v1/dogs/{dog_id}/profile-versions/{other_profile}",
                        _profile(dog_id, other_profile, "Concurrent", 1),
                    )[0]
                except urllib.error.HTTPError as error:
                    statuses["profile"] = error.code

            def recording_write():
                try:
                    manifest, _ = _manifest(dog_id, other_profile, recording_id)
                    statuses["recording"] = request(
                        "PUT", f"/v1/recordings/{recording_id}", manifest
                    )[0]
                except urllib.error.HTTPError as error:
                    statuses["recording"] = error.code

            threads = [
                threading.Thread(target=profile_write),
                threading.Thread(target=recording_write),
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            assert statuses.get("profile") != 500
            assert statuses.get("recording") != 500
            assert statuses.get("profile") != 503
            assert statuses.get("recording") != 503
