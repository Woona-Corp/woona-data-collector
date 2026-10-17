import hashlib
import json
import os
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from sqlalchemy import text

from server.app import STORAGE_ROOT, engine, ensure_device, incoming_path


BASE = os.getenv("WOONA_TEST_BASE_URL", "http://127.0.0.1:8080")
TOKEN = os.getenv("WOONA_TEST_TOKEN", "change-me-local-token")
SECOND_TOKEN = "woona-ios-integration-token"
DEVICE = "00000000-0000-0000-0000-000000000001"
SECOND_DEVICE = "00000000-0000-0000-0000-000000000002"
DOG = "10000000-0000-0000-0000-000000000001"
PROFILE = "20000000-0000-0000-0000-000000000001"
RECORDING = "32000000-0000-0000-0000-000000000001"


def canonical_hash(value):
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def dog_questionnaire(name="Rex"):
    return {
        "schemaVersion": 1,
        "numberOrName": name,
        "shelterOrPlace": "Shelter 1",
        "breedStatus": "unknown",
        "breedName": None,
        "resembles": None,
        "size": "medium",
        "ageStatus": "unknown",
        "ageYears": None,
        "ageMonths": None,
        "ageSource": "unknown",
        "sex": "unknown",
        "sterilizationStatus": "unknown",
        "weightStatus": "unknown",
        "weightKg": None,
        "bodyConditionStatus": "unable",
        "bodyConditionScore": None,
        "muscleMass": "unable",
        "neckCircumferenceStatus": "not_measured",
        "neckCircumferenceCm": None,
        "coatLength": "unknown",
        "undercoat": "unknown",
        "shavedAreasStatus": "unknown",
        "shavedAreasDetails": None,
        "observedSigns": ["none"],
        "diagnosesStatus": "unknown",
        "diagnosesDetails": None,
        "housing": "unknown",
        "housingDetails": None,
        "walksStatus": "unknown",
        "walksDescription": None,
        "cohabitants": "unknown",
        "shelterPermission": "unknown",
        "notesStatus": "none",
        "notes": None,
    }


def session_questionnaire():
    return {
        "schemaVersion": 1,
        "sessionLabel": "E2E",
        "operatorName": "Test",
        "activityGroup": "stationary",
        "activityType": "rest",
        "activityDetails": None,
        "location": "indoors",
        "surface": "concrete",
        "surfaceDetails": None,
        "airTemperatureStatus": "not_measured",
        "airTemperatureC": None,
        "sensorPosition": "dorsal_neck",
        "sensorPositionDetails": None,
        "collarTightness": "snug",
        "preMeasurementState": "rest",
        "preMeasurementStateDetails": None,
        "pulseStatus": "not_measured",
        "pulseBpm": None,
        "respirationStatus": "not_measured",
        "respirationPerMinute": None,
        "bodyTemperatureStatus": "not_measured",
        "bodyTemperatureC": None,
        "measurementAtUtc": None,
        "videoRequested": False,
    }


def profile_payload(name="Rex", expected=0, profile_id=PROFILE):
    questionnaire = dog_questionnaire(name)
    return {
        "dog": {
            "id": DOG,
            "numberOrName": name,
            "expectedRevision": expected,
        },
        "profileVersion": {
            "id": profile_id,
            "schemaVersion": 1,
            "validationState": "complete",
            "questionnaire": questionnaire,
            "contentSha256": canonical_hash(questionnaire),
            "clientCreatedAtUtc": "2026-07-30T17:00:00Z",
        },
    }


def request(method, path, payload=None, headers=None, token=TOKEN):
    body = None if payload is None else json.dumps(payload).encode()
    all_headers = {"Authorization": f"Bearer {token}"}
    if payload is not None:
        all_headers["Content-Type"] = "application/json"
    all_headers.update(headers or {})
    raw = urllib.request.urlopen(
        urllib.request.Request(
            BASE + path,
            data=body,
            headers=all_headers,
            method=method,
        )
    )
    return raw.status, {key.lower(): value for key, value in raw.headers.items()}, raw.read()


def expect_http(status, method, path, payload=None, headers=None, token=TOKEN):
    with unittest.TestCase().assertRaises(urllib.error.HTTPError) as caught:
        request(method, path, payload, headers, token)
    assert caught.exception.code == status
    try:
        return json.loads(caught.exception.read())
    finally:
        caught.exception.close()


class ApiIntegrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with engine.begin() as connection:
            connection.execute(
                text(
                    """
                    INSERT INTO client_devices(id,label,token_hash)
                    VALUES(CAST(:id AS uuid),'iOS integration',:hash)
                    ON CONFLICT(id) DO UPDATE SET
                      label=EXCLUDED.label,token_hash=EXCLUDED.token_hash,
                      revoked_at=NULL
                    """
                ),
                {
                    "id": SECOND_DEVICE,
                    "hash": hashlib.sha256(SECOND_TOKEN.encode()).hexdigest(),
                },
            )

    def test_01_auth_and_profile_without_recording(self):
        expect_http(401, "GET", "/v1/dogs", token="wrong")
        status, headers, body = request(
            "PUT",
            f"/v1/dogs/{DOG}/profile-versions/{PROFILE}",
            profile_payload(),
        )
        self.assertEqual(200, status)
        self.assertIn("x-request-id", headers)
        receipt = json.loads(body)
        self.assertEqual(1, receipt["dogRevision"])
        self.assertTrue(receipt["serverTimestampUtc"].endswith("Z"))

        _, _, body = request("GET", f"/v1/dogs/{DOG}")
        self.assertEqual(PROFILE, json.loads(body)["profileVersion"]["id"])

    def test_02_invalid_and_immutable_profile_rejected(self):
        invalid = profile_payload()
        invalid_profile_id = "20000000-0000-0000-0000-000000000099"
        invalid["profileVersion"]["id"] = invalid_profile_id
        invalid["profileVersion"]["questionnaire"]["numberOrName"] = ""
        invalid["profileVersion"]["contentSha256"] = canonical_hash(
            invalid["profileVersion"]["questionnaire"]
        )
        expect_http(
            422,
            "PUT",
            f"/v1/dogs/{DOG}/profile-versions/{invalid_profile_id}",
            invalid,
        )

        changed = profile_payload("Other")
        error = expect_http(
            409,
            "PUT",
            f"/v1/dogs/{DOG}/profile-versions/{PROFILE}",
            changed,
        )
        self.assertEqual("immutable_profile_conflict", error["code"])

        next_profile_id = "20000000-0000-0000-0000-000000000098"
        status, _, _ = request(
            "PUT",
            f"/v1/dogs/{DOG}/profile-versions/{next_profile_id}",
            profile_payload("Rex updated", expected=1, profile_id=next_profile_id),
        )
        self.assertEqual(200, status)
        _, _, body = request("GET", f"/v1/dogs/{DOG}")
        restored = json.loads(body)
        self.assertEqual(next_profile_id, restored["profileVersion"]["id"])
        self.assertGreaterEqual(len(restored["profileVersions"]), 2)

    def test_03_manifest_resume_complete_range_and_idempotency(self):
        contents = {
            "packet": b"packet-data",
            "packet_timeline": b"packet-timeline-data",
            "raw": b"raw-fragment-data",
            "diagnostic": b"diagnostic-data",
            "sync": b'{"schemaVersion":2}',
        }
        artifacts = []
        ids = {}
        for index, (kind, content) in enumerate(contents.items(), start=1):
            artifact_id = f"42000000-0000-0000-0000-{index:012d}"
            ids[kind] = artifact_id
            extension = {
                "packet": "bin",
                "packet_timeline": "bin",
                "raw": "binlog",
                "diagnostic": "log",
                "sync": "json",
            }[kind]
            artifacts.append(
                {
                    "id": artifact_id,
                    "type": kind,
                    "fileName": f"{kind}.{extension}",
                    "mimeType": {
                        "diagnostic": "text/plain",
                        "sync": "application/json",
                    }.get(kind, "application/octet-stream"),
                    "sizeBytes": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "clientCreatedAtUtc": "2026-07-30T17:00:00Z",
                }
            )
        profile = profile_payload()
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
                "sessionLabel": "E2E",
                "videoRequested": False,
                "sensorHardwareId": "fake-sensor",
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
        status, _, body = request("PUT", f"/v1/recordings/{RECORDING}", manifest)
        self.assertEqual(200, status)
        self.assertEqual(5, len(json.loads(body)["artifacts"]))
        status, _, _ = request("PUT", f"/v1/recordings/{RECORDING}", manifest)
        self.assertEqual(200, status)

        for kind, content in contents.items():
            artifact_id = ids[kind]
            _, headers, _ = request(
                "HEAD", f"/v1/artifacts/{artifact_id}/content"
            )
            offset = int(headers["upload-offset"])
            if offset == 0:
                split = max(1, len(content) // 2)
                first = content[:split]
                status, headers, _ = patch_bytes(artifact_id, 0, first)
                self.assertEqual(204, status)
                if kind == "raw":
                    incoming = (
                        Path(__file__).parents[2]
                        / "var"
                        / "storage"
                        / "incoming"
                        / f"{artifact_id}.part"
                    )
                    if incoming.exists() and os.access(incoming, os.W_OK):
                        with incoming.open("ab") as output:
                            output.write(b"uncommitted-tail")
                error = expect_patch_error(artifact_id, 0, first, 409)
                self.assertEqual("offset_mismatch", error["code"])
                _, headers, _ = request(
                    "HEAD", f"/v1/artifacts/{artifact_id}/content"
                )
                offset = int(headers["upload-offset"])
            if offset < len(content):
                patch_bytes(artifact_id, offset, content[offset:])
            request("POST", f"/v1/artifacts/{artifact_id}/complete", {})
            request("POST", f"/v1/artifacts/{artifact_id}/complete", {})

        _, _, first = request(
            "GET",
            f"/v1/artifacts/{ids['raw']}/content",
            headers={"Range": "bytes=0-2"},
        )
        self.assertEqual(contents["raw"][:3], first)

        _, _, first_receipt = request(
            "POST", f"/v1/recordings/{RECORDING}/complete", {}
        )
        _, _, second_receipt = request(
            "POST", f"/v1/recordings/{RECORDING}/complete", {}
        )
        self.assertEqual(
            json.loads(first_receipt)["receiptSha256"],
            json.loads(second_receipt)["receiptSha256"],
        )
        self.assertTrue(json.loads(first_receipt)["verifiedAtUtc"].endswith("Z"))
        _, _, integrity = request("GET", "/v1/integrity")
        self.assertEqual("ok", json.loads(integrity)["status"])
        _, _, restored = request("GET", f"/v1/recordings/{RECORDING}")
        restored_value = json.loads(restored)
        self.assertEqual("arrival_aligned", restored_value["sync"]["overallSyncQuality"])
        self.assertTrue(restored_value["sync"]["sessionZeroAtUtc"].endswith("Z"))
        self.assertEqual(5, len(restored_value["artifacts"]))

    def test_04_path_traversal_is_rejected(self):
        profile = profile_payload()
        payload = {
            "schemaVersion": 1,
            "captureDeviceId": DEVICE,
            "dog": profile["dog"],
            "dogProfileVersion": profile["profileVersion"],
            "recording": {
                "source": "live",
                "captureStatus": "failed",
                "startedAtUtc": "2026-07-30T18:00:00Z",
                "endedAtUtc": "2026-07-30T18:00:01Z",
                "timezone": "UTC",
                "sessionLabel": "bad path",
                "videoRequested": False,
                "appVersion": "test",
                "questionnaireSchemaVersion": 1,
                "questionnaireValidationState": "complete",
                "sessionQuestionnaire": session_questionnaire(),
            },
            "sync": {
                "schemaVersion": 2,
                "monotonicClock": "android.elapsedRealtimeNanos",
                "sessionZeroAtUtc": "2026-07-30T18:00:00Z",
                "sessionZeroWallClockMs": 1785434400000,
                "sessionZeroMonotonicNs": 1,
                "sessionZeroUncertaintyNs": 0,
                "cameraClockQuality": "unavailable",
                "sensorClockQuality": "unavailable",
                "overallSyncQuality": "unavailable",
            },
            "artifacts": [
                {
                    "id": "49999999-0000-0000-0000-000000000001",
                    "type": "diagnostic",
                    "fileName": "../../escape",
                    "mimeType": "text/plain",
                    "sizeBytes": 0,
                    "sha256": hashlib.sha256(b"").hexdigest(),
                    "clientCreatedAtUtc": "2026-07-30T18:00:00Z",
                }
            ],
        }
        expect_http(
            422,
            "PUT",
            "/v1/recordings/39999999-0000-0000-0000-000000000001",
            payload,
        )

    def test_05_zero_byte_artifact_can_be_completed_and_downloaded(self):
        profile = profile_payload()
        recording_id = "30000000-0000-0000-0000-000000000005"
        artifact_id = "40000000-0000-0000-0000-000000000005"
        payload = {
            "schemaVersion": 1,
            "captureDeviceId": DEVICE,
            "dog": profile["dog"],
            "dogProfileVersion": profile["profileVersion"],
            "recording": {
                "source": "live",
                "captureStatus": "failed",
                "startedAtUtc": "2026-07-30T19:00:00Z",
                "endedAtUtc": "2026-07-30T19:00:01Z",
                "timezone": "UTC",
                "sessionLabel": "zero byte",
                "videoRequested": False,
                "appVersion": "test",
                "questionnaireSchemaVersion": 1,
                "questionnaireValidationState": "complete",
                "sessionQuestionnaire": session_questionnaire(),
            },
            "sync": {
                "schemaVersion": 2,
                "monotonicClock": "android.elapsedRealtimeNanos",
                "sessionZeroAtUtc": "2026-07-30T19:00:00Z",
                "sessionZeroWallClockMs": 1785438000000,
                "sessionZeroMonotonicNs": 1,
                "sessionZeroUncertaintyNs": 0,
                "cameraClockQuality": "unavailable",
                "sensorClockQuality": "unavailable",
                "overallSyncQuality": "unavailable",
            },
            "artifacts": [
                {
                    "id": artifact_id,
                    "type": "diagnostic",
                    "fileName": "diagnostics.log",
                    "mimeType": "text/plain",
                    "sizeBytes": 0,
                    "sha256": hashlib.sha256(b"").hexdigest(),
                    "clientCreatedAtUtc": "2026-07-30T19:00:00Z",
                }
            ],
        }
        request("PUT", f"/v1/recordings/{recording_id}", payload)
        request("POST", f"/v1/artifacts/{artifact_id}/complete", {})
        request("POST", f"/v1/recordings/{recording_id}/complete", {})
        _, _, body = request("GET", f"/v1/artifacts/{artifact_id}/content")
        self.assertEqual(b"", body)

    def test_06_legacy_local_data_can_be_migrated_explicitly(self):
        dog_id = "10000000-0000-0000-0000-000000000006"
        profile_id = "20000000-0000-0000-0000-000000000006"
        recording_id = "30000000-0000-0000-0000-000000000006"
        artifact_id = "40000000-0000-0000-0000-000000000006"
        questionnaire = {"numberOrName": "Legacy Rex", "observedSigns": []}
        profile = {
            "dog": {
                "id": dog_id,
                "numberOrName": "Legacy Rex",
                "expectedRevision": 0,
            },
            "profileVersion": {
                "id": profile_id,
                "schemaVersion": 1,
                "validationState": "legacy_incomplete",
                "questionnaire": questionnaire,
                "contentSha256": canonical_hash(questionnaire),
                "clientCreatedAtUtc": "2026-07-01T00:00:00Z",
            },
        }
        content = b"legacy"
        manifest = {
            "schemaVersion": 1,
            "captureDeviceId": DEVICE,
            "dog": profile["dog"],
            "dogProfileVersion": profile["profileVersion"],
            "recording": {
                "source": "live",
                "captureStatus": "completed",
                "startedAtUtc": "2026-07-01T00:00:00Z",
                "endedAtUtc": "2026-07-01T00:01:00Z",
                "timezone": "UTC",
                "sessionLabel": "Legacy import",
                "videoRequested": False,
                "appVersion": "legacy",
                "questionnaireSchemaVersion": 1,
                "questionnaireValidationState": "legacy_incomplete",
                "sessionQuestionnaire": {},
            },
            "sync": {
                "schemaVersion": 2,
                "monotonicClock": "android.elapsedRealtimeNanos",
                "sessionZeroAtUtc": "2026-07-01T00:00:00Z",
                "sessionZeroWallClockMs": 1782864000000,
                "sessionZeroMonotonicNs": 0,
                "sessionZeroUncertaintyNs": 0,
                "cameraClockQuality": "unavailable",
                "sensorClockQuality": "unavailable",
                "overallSyncQuality": "unavailable",
            },
            "artifacts": [
                {
                    "id": artifact_id,
                    "type": "packet",
                    "fileName": "packets.bin",
                    "mimeType": "application/octet-stream",
                    "sizeBytes": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "clientCreatedAtUtc": "2026-07-01T00:01:00Z",
                }
            ],
        }
        request("PUT", f"/v1/recordings/{recording_id}", manifest)
        offset = int(
            request("HEAD", f"/v1/artifacts/{artifact_id}/content")[1][
                "upload-offset"
            ]
        )
        if offset < len(content):
            patch_bytes(artifact_id, offset, content[offset:])
        request("POST", f"/v1/artifacts/{artifact_id}/complete", {})
        _, _, receipt = request("POST", f"/v1/recordings/{recording_id}/complete", {})
        self.assertEqual(1, json.loads(receipt)["artifactCount"])

    def test_07_dog_and_recording_pagination(self):
        _, _, body = request("GET", "/v1/dogs?limit=1")
        first_dogs = json.loads(body)
        self.assertEqual(1, len(first_dogs["items"]))
        self.assertIsNotNone(first_dogs["nextCursor"])
        _, _, body = request(
            "GET", f"/v1/dogs?limit=1&cursor={first_dogs['nextCursor']}"
        )
        second_dogs = json.loads(body)
        self.assertEqual(1, len(second_dogs["items"]))
        self.assertNotEqual(
            first_dogs["items"][0]["id"], second_dogs["items"][0]["id"]
        )

        _, _, body = request("GET", f"/v1/dogs/{DOG}/recordings?limit=1")
        first_recordings = json.loads(body)
        self.assertEqual(1, len(first_recordings["items"]))
        self.assertIsNotNone(first_recordings["nextCursor"])
        _, _, body = request(
            "GET",
            f"/v1/dogs/{DOG}/recordings?limit=1"
            f"&cursor={first_recordings['nextCursor']}",
        )
        second_recordings = json.loads(body)
        self.assertEqual(1, len(second_recordings["items"]))
        self.assertNotEqual(
            first_recordings["items"][0]["id"],
            second_recordings["items"][0]["id"],
        )

    def test_08_ios_device_shares_data_but_cannot_mutate_android_upload(self):
        _, _, body = request("GET", f"/v1/dogs/{DOG}", token=SECOND_TOKEN)
        shared_dog = json.loads(body)
        self.assertEqual(DOG, shared_dog["id"])

        _, _, body = request(
            "GET", f"/v1/recordings/{RECORDING}", token=SECOND_TOKEN
        )
        self.assertEqual(RECORDING, json.loads(body)["id"])

        raw_artifact = "42000000-0000-0000-0000-000000000003"
        _, _, body = request(
            "GET", f"/v1/artifacts/{raw_artifact}/content", token=SECOND_TOKEN
        )
        self.assertEqual(b"raw-fragment-data", body)
        error = expect_http(
            403,
            "POST",
            f"/v1/artifacts/{raw_artifact}/complete",
            {},
            token=SECOND_TOKEN,
        )
        self.assertEqual("artifact_not_owned", error["code"])

        ios_profile = "20000000-0000-0000-0000-000000000097"
        status, _, body = request(
            "PUT",
            f"/v1/dogs/{DOG}/profile-versions/{ios_profile}",
            profile_payload(
                "Rex shared",
                expected=shared_dog["revision"],
                profile_id=ios_profile,
            ),
            token=SECOND_TOKEN,
        )
        self.assertEqual(200, status)
        new_revision = json.loads(body)["dogRevision"]
        _, _, body = request("GET", f"/v1/dogs/{DOG}")
        android_view = json.loads(body)
        self.assertEqual(new_revision, android_view["revision"])
        self.assertEqual(ios_profile, android_view["profileVersion"]["id"])

    def test_09_revocation_survives_startup_provisioning(self):
        try:
            with engine.begin() as connection:
                connection.execute(
                    text("UPDATE client_devices SET revoked_at=now() WHERE id=:id"),
                    {"id": DEVICE},
                )
            ensure_device()
            with engine.connect() as connection:
                revoked = connection.execute(
                    text(
                        "SELECT revoked_at IS NOT NULL "
                        "FROM client_devices WHERE id=:id"
                    ),
                    {"id": DEVICE},
                ).scalar_one()
            self.assertTrue(revoked)
            self.assertEqual(
                "invalid_bearer_token",
                expect_http(401, "GET", "/v1/me")["code"],
            )
        finally:
            with engine.begin() as connection:
                connection.execute(
                    text("UPDATE client_devices SET revoked_at=NULL WHERE id=:id"),
                    {"id": DEVICE},
                )

    def test_10_hash_mismatch_is_persisted_and_can_be_retried(self):
        recording_id = "30000000-0000-0000-0000-000000000010"
        artifact_id = "40000000-0000-0000-0000-000000000010"
        expected = b"expected"
        corrupt = b"corrupt!"
        profile = profile_payload()
        payload = {
            "schemaVersion": 1,
            "captureDeviceId": DEVICE,
            "dog": profile["dog"],
            "dogProfileVersion": profile["profileVersion"],
            "recording": {
                "source": "live",
                "captureStatus": "failed",
                "startedAtUtc": "2026-07-30T20:00:00Z",
                "endedAtUtc": "2026-07-30T20:00:01Z",
                "timezone": "UTC",
                "sessionLabel": "hash retry",
                "videoRequested": False,
                "appVersion": "test",
                "questionnaireSchemaVersion": 1,
                "questionnaireValidationState": "complete",
                "sessionQuestionnaire": session_questionnaire(),
            },
            "sync": {
                "schemaVersion": 2,
                "monotonicClock": "android.elapsedRealtimeNanos",
                "sessionZeroAtUtc": "2026-07-30T20:00:00Z",
                "sessionZeroWallClockMs": 1785441600000,
                "sessionZeroMonotonicNs": 1,
                "sessionZeroUncertaintyNs": 0,
                "cameraClockQuality": "unavailable",
                "sensorClockQuality": "unavailable",
                "overallSyncQuality": "unavailable",
            },
            "artifacts": [
                {
                    "id": artifact_id,
                    "type": "diagnostic",
                    "fileName": "hash-retry.log",
                    "mimeType": "text/plain",
                    "sizeBytes": len(expected),
                    "sha256": hashlib.sha256(expected).hexdigest(),
                    "clientCreatedAtUtc": "2026-07-30T20:00:00Z",
                }
            ],
        }
        request("PUT", f"/v1/recordings/{recording_id}", payload)
        # Backups omit incoming files; retries must use bytes still on disk.
        part = incoming_path(uuid.UUID(artifact_id))
        for remainder, offset in ((None, 0), (expected[:2], 2), (expected[:4] + b"uncommitted", 4)):
            with self.subTest(remainder=remainder):
                patch_bytes(artifact_id, 0, expected[:4])
                if remainder is None:
                    part.unlink()
                else:
                    part.write_bytes(remainder)
                _, headers, _ = request("HEAD", f"/v1/artifacts/{artifact_id}/content")
                self.assertEqual(str(offset), headers["upload-offset"])
                patch_bytes(artifact_id, offset, expected[offset:])
                self.assertEqual(expected, part.read_bytes())
                part.unlink()
                self.assertEqual("0", request("HEAD", f"/v1/artifacts/{artifact_id}/content")[1]["upload-offset"])
        patch_bytes(artifact_id, 0, corrupt)
        error = expect_http(
            422, "POST", f"/v1/artifacts/{artifact_id}/complete", {}
        )
        self.assertEqual("artifact_hash_mismatch", error["code"])
        _, headers, _ = request("HEAD", f"/v1/artifacts/{artifact_id}/content")
        self.assertEqual("0", headers["upload-offset"])
        _, _, body = request("GET", f"/v1/recordings/{recording_id}")
        self.assertEqual(
            "corrupt", json.loads(body)["artifacts"][0]["storageStatus"]
        )

        patch_bytes(artifact_id, 0, expected)
        target = (
            STORAGE_ROOT
            / "recordings"
            / recording_id[:2]
            / recording_id
            / artifact_id
            / "content.log"
        )
        target.parent.mkdir(parents=True, exist_ok=True)
        incoming_path(uuid.UUID(artifact_id)).replace(target)
        request("POST", f"/v1/artifacts/{artifact_id}/complete", {})
        _, _, body = request("GET", f"/v1/recordings/{recording_id}")
        self.assertEqual(
            "available", json.loads(body)["artifacts"][0]["storageStatus"]
        )
        for offset in (0, len(expected)):
            error = expect_patch_error(artifact_id, offset, b"X", 409)
            self.assertEqual("artifact_already_complete", error["code"])
        self.assertEqual(str(len(expected)), request("HEAD", f"/v1/artifacts/{artifact_id}/content")[1]["upload-offset"])
        self.assertEqual(expected, request("GET", f"/v1/artifacts/{artifact_id}/content")[2])
        self.assertFalse(part.exists())


def patch_bytes(artifact_id, offset, content, token=TOKEN):
    request_value = urllib.request.Request(
        BASE + f"/v1/artifacts/{artifact_id}/content",
        data=content,
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/offset+octet-stream",
            "Upload-Offset": str(offset),
            "Content-Length": str(len(content)),
        },
    )
    raw = urllib.request.urlopen(request_value)
    return raw.status, dict(raw.headers), raw.read()


def expect_patch_error(artifact_id, offset, content, status):
    with unittest.TestCase().assertRaises(urllib.error.HTTPError) as caught:
        patch_bytes(artifact_id, offset, content)
    assert caught.exception.code == status
    try:
        return json.loads(caught.exception.read())
    finally:
        caught.exception.close()


if __name__ == "__main__":
    unittest.main()
