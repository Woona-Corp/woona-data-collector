"""A stalled upload must explain itself without inventing a cause."""
import hashlib
import json
import unittest
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from fastapi import HTTPException
from sqlalchemy import text

from server import app as api
from server.app import DEVICE_ID, engine, persist_artifact_chunk
from server.tests.test_api import (
    BASE,
    TOKEN,
    canonical_hash,
    dog_questionnaire,
    expect_http,
    request,
    session_questionnaire,
)

STALE = timedelta(hours=3)


def raw_patch(path, body, headers):
    """Binary PATCH: the shared JSON helper cannot send capture bytes."""
    prepared = dict(headers, Authorization=f'Bearer {TOKEN}')
    try:
        with urllib.request.urlopen(urllib.request.Request(
                BASE + path, data=body, headers=prepared, method='PATCH')) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


class UploadStallReasonTest(unittest.TestCase):
    """Server storage failures are stored; silence is derived, never guessed."""

    @classmethod
    def setUpClass(cls):
        cls.dog = str(uuid.uuid4())
        cls.profile = str(uuid.uuid4())
        cls.recording = str(uuid.uuid4())
        questionnaire = dog_questionnaire('Stall')
        status, _, _ = request('PUT', f'/v1/dogs/{cls.dog}/profile-versions/{cls.profile}', {
            'dog': {'id': cls.dog, 'numberOrName': 'Stall', 'expectedRevision': 0},
            'profileVersion': {
                'id': cls.profile, 'schemaVersion': 1, 'validationState': 'complete',
                'questionnaire': questionnaire,
                'contentSha256': canonical_hash(questionnaire),
                'clientCreatedAtUtc': '2026-07-30T17:00:00Z',
            },
        })
        assert status == 200
        cls.content = b'stall-fixture'
        # A capture manifest must declare every required capture file; only the
        # packet artifact is exercised here, the others stay untouched.
        cls.artifacts = {
            'packet': (str(uuid.uuid4()), cls.content, 'packets.bin'),
            'packet_timeline': (str(uuid.uuid4()), b'tl', 'packet_timeline.bin'),
            'raw': (str(uuid.uuid4()), b'raw', 'raw_fragments.binlog'),
            'diagnostic': (str(uuid.uuid4()), b'log', 'diagnostics.log'),
            'sync': (str(uuid.uuid4()), b'{}', 'sync.json'),
        }
        cls.artifact = cls.artifacts['packet'][0]
        status, _, _ = request('PUT', f'/v1/recordings/{cls.recording}', {
            'schemaVersion': 1,
            'captureDeviceId': str(DEVICE_ID),
            'dog': {'id': cls.dog, 'numberOrName': 'Stall', 'expectedRevision': 1},
            'dogProfileVersion': {
                'id': cls.profile, 'schemaVersion': 1, 'validationState': 'complete',
                'questionnaire': questionnaire,
                'contentSha256': canonical_hash(questionnaire),
                'clientCreatedAtUtc': '2026-07-30T17:00:00Z',
            },
            'recording': {
                'source': 'live', 'captureStatus': 'completed',
                'startedAtUtc': '2026-07-30T17:00:00Z', 'endedAtUtc': '2026-07-30T17:01:00Z',
                'timezone': 'Europe/Moscow', 'sessionLabel': 'E2E',
                'videoRequested': False, 'sensorHardwareId': 'fake-sensor',
                'appVersion': 'test', 'protocolVersion': '1',
                'questionnaireSchemaVersion': 1, 'questionnaireValidationState': 'complete',
                'sessionQuestionnaire': session_questionnaire(),
            },
            'sync': {
                'schemaVersion': 2, 'monotonicClock': 'android.elapsedRealtimeNanos',
                'sessionZeroAtUtc': '2026-07-30T17:00:00Z', 'sessionZeroWallClockMs': 1785430800000,
                'sessionZeroMonotonicNs': 1000000000, 'sessionZeroUncertaintyNs': 1000,
                'firstSensorPacketMonotonicNs': 1001000000,
                'videoFirstFrameMonotonicNs': 1002000000, 'videoOffsetFromSensorNs': 1000000,
                'cameraClockQuality': 'unavailable', 'sensorClockQuality': 'first_packet_arrival',
                'overallSyncQuality': 'arrival_aligned', 'calibrationOffsetNs': 0,
            },
            'artifacts': [{
                'id': artifact_id, 'type': kind, 'fileName': file_name,
                'mimeType': {'diagnostic': 'text/plain', 'sync': 'application/json'}.get(
                    kind, 'application/octet-stream'),
                'sizeBytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(),
                'clientCreatedAtUtc': '2026-07-30T17:00:00Z',
            } for kind, (artifact_id, payload, file_name) in cls.artifacts.items()],
        })
        assert status == 200

    # --- helpers -------------------------------------------------------
    def sync_status(self):
        status, _, body = request('GET', f'/v1/recordings/{self.recording}/sync-status')
        assert status == 200
        return json.loads(body)

    def packet_status(self, artifact_id=None):
        wanted = artifact_id or self.artifact
        return next(item for item in self.sync_status()['artifacts'] if item['id'] == wanted)

    def artifact_row(self, artifact_id=None):
        with engine.connect() as connection:
            return connection.execute(text(
                'SELECT storage_status,stored_size_bytes,error_code,error_message '
                'FROM artifacts WHERE id=:id'
            ), {'id': artifact_id or self.artifact}).mappings().one()

    def set_packet_progress(self, stored, updated_at):
        with engine.begin() as connection:
            connection.execute(text(
                "UPDATE artifacts SET stored_size_bytes=:stored,storage_status='uploading',"
                'upload_updated_at=:updated,error_code=NULL,error_message=NULL WHERE id=:id'
            ), {'stored': stored, 'updated': updated_at, 'id': self.artifact})

    def age_other_capture_files(self, updated_at):
        """Transfer staleness is judged on the newest capture file, not one row."""
        with engine.begin() as connection:
            connection.execute(text(
                'UPDATE artifacts SET upload_updated_at=:updated '
                'WHERE recording_id=:id AND id<>:packet'
            ), {'updated': updated_at, 'id': self.recording, 'packet': self.artifact})

    def reset_upload(self, stored=0, hours_ago=0, part_bytes=0):
        """Start each case from a known staging state so order never matters."""
        part = api.incoming_path(uuid.UUID(self.artifact))
        part.parent.mkdir(parents=True, exist_ok=True)
        if part.exists():
            part.unlink()
        if part_bytes:
            part.write_bytes(self.content[:part_bytes])
        updated_at = datetime.now(timezone.utc) - timedelta(hours=hours_ago)
        self.set_packet_progress(stored, updated_at)
        self.age_other_capture_files(updated_at)

    # --- cases ---------------------------------------------------------
    def test_storage_failure_is_stored_and_cleared_by_the_next_chunk(self):
        self.reset_upload()
        with patch.object(api, 'append_upload',
                          side_effect=HTTPException(507, detail={'code': 'storage_full'})):
            with self.assertRaises(HTTPException) as caught:
                persist_artifact_chunk(uuid.UUID(self.artifact), DEVICE_ID, 0, bytearray(b'x'), 'test')
        self.assertEqual(507, caught.exception.status_code)
        row = self.artifact_row()
        self.assertEqual('storage_full', row['error_code'])
        self.assertEqual(0, row['stored_size_bytes'])
        self.assertEqual('uploading', row['storage_status'])
        self.assertTrue(row['error_message'])
        artifact = self.packet_status()
        self.assertEqual('storage_full', artifact['errorCode'])
        self.assertFalse(artifact['errorDerived'])
        self.assertTrue(artifact['retryable'])
        status = raw_patch(f'/v1/artifacts/{self.artifact}/content', self.content,
                           {'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': '0'})
        self.assertEqual(204, status)
        row = self.artifact_row()
        self.assertIsNone(row['error_code'])
        self.assertEqual(len(self.content), row['stored_size_bytes'])

    def test_client_conflicts_are_not_stored_as_server_storage_failures(self):
        self.reset_upload()
        for detail, status_code in (({'code': 'offset_mismatch'}, 409),
                                    ({'code': 'artifact_size_exceeded'}, 413)):
            with patch.object(api, 'append_upload', side_effect=HTTPException(status_code, detail=detail)):
                with self.assertRaises(HTTPException):
                    persist_artifact_chunk(uuid.UUID(self.artifact), DEVICE_ID, 0, bytearray(b'x'), 'test')
            self.assertIsNone(self.artifact_row()['error_code'])

    def test_silence_without_progress_is_derived_not_claimed(self):
        self.reset_upload(0, hours_ago=3)
        artifact = self.packet_status()
        self.assertEqual('upload_not_started', artifact['errorCode'])
        self.assertTrue(artifact['errorDerived'])
        self.assertEqual('resume_upload', artifact['nextAction'])
        self.assertIn('has received none', artifact['errorMessage'])
        self.assertNotIn('offline', artifact['errorMessage'])
        self.assertNotIn('background', artifact['errorMessage'])

    def test_partial_stall_reports_acknowledged_bytes_and_preserves_them(self):
        half = len(self.content) // 2
        self.reset_upload(half, hours_ago=3, part_bytes=half)
        artifact = self.packet_status()
        self.assertEqual('upload_interrupted', artifact['errorCode'])
        self.assertTrue(artifact['errorDerived'])
        self.assertIn(f'at {half} of {len(self.content)}', artifact['errorMessage'])
        self.assertEqual(half, self.artifact_row()['stored_size_bytes'])

    def test_recent_progress_has_no_error_and_no_stall(self):
        self.reset_upload(0, hours_ago=0)
        artifact = self.packet_status()
        self.assertIsNone(artifact['errorCode'])
        self.assertFalse(artifact['errorDerived'])
        self.assertFalse(self.sync_status()['transfer']['stalled'])

    def test_stalled_transfer_exposes_the_derived_reason_as_last_error(self):
        self.reset_upload(0, hours_ago=3)
        transfer = self.sync_status()['transfer']
        self.assertTrue(transfer['stalled'])
        self.assertEqual('upload_not_started', transfer['lastError']['code'])
        self.assertTrue(transfer['lastError']['retryable'])
        self.assertGreater(transfer['secondsSinceLastProgress'], transfer['staleAfterSeconds'])

    def test_unknown_recording_is_not_reported_as_a_stall(self):
        expect_http(404, 'GET', f'/v1/recordings/{uuid.uuid4()}/sync-status')
