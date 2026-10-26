import hashlib
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import uuid

from server.sync_status import recording_status


class SyncStatusTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'incoming').mkdir()
        self.now = datetime(2026, 10, 26, 18, 0, tzinfo=timezone.utc)
        self.recording = {'id': uuid.uuid4(), 'ingest_status': 'uploading',
            'server_verified_at': None, 'receipt_sha256': None,
            'capture_status': 'completed', 'capture_error_code': None, 'capture_error_message': None,
            'server_updated_at': self.now - timedelta(days=1),
            'session_questionnaire': {'schemaVersion': 2, 'plannedActivities': ['Активность']}}

    def artifact(self, kind='video', size=10):
        return {'id': uuid.uuid4(), 'artifact_type': kind, 'file_name': kind + '.mp4',
            'expected_size_bytes': size, 'stored_size_bytes': 0, 'storage_status': 'uploading',
            'server_relative_path': None, 'verified_at': None,
            'upload_updated_at': self.now - timedelta(days=1), 'sha256': 'a' * 64,
            'error_code': None, 'error_message': None}

    def available(self, row):
        row.update(storage_status='available', stored_size_bytes=row['expected_size_bytes'],
            server_relative_path=str(row['id']), verified_at=self.now)
        (self.root / row['server_relative_path']).write_bytes(b'x' * row['expected_size_bytes'])

    def receipt(self, rows):
        values = [{'id': str(row['id']), 'sha256': row['sha256'], 'size': row['expected_size_bytes']}
                  for row in sorted(rows, key=lambda row: str(row['id']))
                  if row['artifact_type'] not in ('ecg', 'heart_rate', 'rr')]
        self.recording.update(ingest_status='complete', server_verified_at=self.now,
            receipt_sha256=hashlib.sha256(json.dumps(values, sort_keys=True, separators=(',', ':')).encode()).hexdigest())

    def status(self, rows):
        return recording_status(self.recording, rows, self.root, now=self.now)

    def test_partial_offset_is_head_compatible_and_stall_is_explicit(self):
        row = self.artifact()
        row['stored_size_bytes'] = 8
        (self.root / 'incoming' / f"{row['id']}.part").write_bytes(b'12345')
        result = self.status([row])
        self.assertEqual(result['transfer']['uploadedBytes'], 5)
        self.assertTrue(result['transfer']['stalled'])
        self.assertEqual(result['transfer']['status'], 'uploading')
        self.assertEqual(result['transfer']['nextAction'], 'resume_upload')
        self.assertEqual(result['artifacts'][0]['uploadedBytes'], 5)
        self.assertFalse(result['transfer']['receiptVerified'])

    def test_lost_temporary_file_does_not_report_acknowledged_bytes_as_current(self):
        row = self.artifact()
        row['stored_size_bytes'] = 10
        result = self.status([row])
        self.assertEqual(result['transfer']['uploadedBytes'], 0)
        self.assertEqual(result['transfer']['status'], 'uploading')

    def test_all_bytes_are_not_equivalent_to_verified_recording(self):
        row = self.artifact()
        row['stored_size_bytes'] = 10
        (self.root / 'incoming' / f"{row['id']}.part").write_bytes(b'x' * 10)
        result = self.status([row])
        self.assertEqual(result['transfer']['status'], 'awaiting_verification')
        self.assertTrue(result['transfer']['allFilesUploaded'])
        self.assertFalse(result['transfer']['allFilesVerified'])
        self.assertFalse(result['transfer']['receiptVerified'])
        self.assertEqual(result['artifacts'][0]['nextAction'], 'verify_file')
        self.available(row)
        self.assertEqual(self.status([row])['transfer']['nextAction'], 'finalize_recording')

    def test_receipt_and_capture_failure_are_independent(self):
        row = self.artifact()
        self.available(row)
        self.receipt([row])
        self.recording.update(capture_status='failed', capture_error_code='gatt_error',
                              capture_error_message='GATT connection failed: 8')
        result = self.status([row])
        self.assertTrue(result['transfer']['receiptVerified'])
        self.assertEqual(result['transfer']['status'], 'verified')
        self.assertFalse(result['capture']['successful'])
        self.assertEqual(result['capture']['errorMessage'], 'GATT connection failed: 8')
        self.assertFalse(result['labeling']['eligible'])
        self.assertEqual(result['labeling']['taskStatus'], 'not_checked')
        self.assertFalse(result['transfer']['stalled'])

    def test_missing_or_truncated_verified_file_revokes_current_confirmation(self):
        row = self.artifact()
        self.available(row)
        self.receipt([row])
        for content, expected in [(b'x', 'stored_file_size_mismatch'), (None, 'stored_file_missing')]:
            with self.subTest(expected=expected):
                path = self.root / row['server_relative_path']
                path.unlink() if content is None else path.write_bytes(content)
                result = self.status([row])
                self.assertEqual(result['transfer']['status'], 'integrity_problem')
                self.assertFalse(result['transfer']['receiptVerified'])
                self.assertEqual(result['artifacts'][0]['errorCode'], expected)
                self.assertFalse(result['transfer']['retryable'])
                self.assertEqual(result['transfer']['nextAction'], 'contact_support_preserve_local_data')

    def test_symlink_outside_storage_is_not_verified(self):
        row = self.artifact()
        self.available(row)
        self.receipt([row])
        target = self.root / row['server_relative_path']
        target.unlink()
        target.symlink_to('/etc/hosts')
        self.assertFalse(self.status([row])['transfer']['receiptVerified'])

    def test_receipt_mismatch_and_references_cannot_fake_capture_confirmation(self):
        row = self.artifact()
        self.available(row)
        self.receipt([row])
        reference = self.artifact('ecg', 100)
        result = self.status([row, reference])
        self.assertTrue(result['transfer']['receiptVerified'])
        self.assertEqual(result['transfer']['totalFiles'], 1)
        self.assertEqual(result['transfer']['totalBytes'], 10)
        self.assertFalse(result['artifacts'][1]['partOfCaptureReceipt'])
        self.recording['receipt_sha256'] = 'b' * 64
        self.assertEqual(self.status([row])['transfer']['status'], 'integrity_problem')

    def test_zero_byte_file_still_requires_verification_and_no_files_is_pending(self):
        row = self.artifact(size=0)
        self.assertEqual(self.status([row])['transfer']['status'], 'awaiting_verification')
        self.assertFalse(self.status([row])['transfer']['receiptVerified'])
        self.assertEqual(self.status([])['transfer']['status'], 'metadata_pending')
        self.assertFalse(self.status([])['transfer']['allFilesVerified'])

    def test_corruption_has_explicit_safe_recovery(self):
        row = self.artifact()
        row.update(storage_status='corrupt', error_code='hash_mismatch')
        result = self.status([row])
        self.assertEqual(result['transfer']['status'], 'integrity_problem')
        self.assertTrue(result['transfer']['retryable'])
        self.assertEqual(result['artifacts'][0]['nextAction'], 'restart_file_upload')
        row['storage_status'] = 'rejected'
        self.assertEqual(self.status([row])['transfer']['status'], 'rejected')
        self.assertFalse(self.status([row])['transfer']['retryable'])

class SyncStatusApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from server.tests.test_api import ApiIntegrationTest
        ApiIntegrationTest.setUpClass()

    def test_progress_receipt_capture_failure_and_account_scope_over_http(self):
        from server.tests.test_api import expect_http
        from server.tests.test_heart import heart_manifest, request
        manifest, contents = heart_manifest()
        manifest['recording'].update(captureStatus='failed', captureErrorCode='gatt_error',
                                     captureErrorMessage='GATT connection failed: 8')
        identity = str(uuid.uuid4())
        path = '/v1/recordings/' + identity
        request('PUT', path, manifest)
        initial = json.loads(request('GET', path + '/sync-status')[2])
        self.assertEqual(initial['schemaVersion'], 2)
        self.assertEqual(initial['ingestStatus'], 'uploading')
        self.assertEqual(initial['transfer']['uploadedBytes'], 0)
        self.assertEqual(initial['transfer']['totalFiles'], 6)
        self.assertFalse(initial['capture']['successful'])
        for artifact in manifest['artifacts']:
            request('PATCH', f"/v1/artifacts/{artifact['id']}/content", contents[artifact['type']], {'Upload-Offset': '0'})
            request('POST', f"/v1/artifacts/{artifact['id']}/complete", {})
        waiting = json.loads(request('GET', path + '/sync-status')[2])
        self.assertEqual(waiting['transfer']['status'], 'awaiting_verification')
        self.assertTrue(waiting['transfer']['allFilesVerified'])
        self.assertFalse(waiting['transfer']['receiptVerified'])
        receipt = json.loads(request('POST', path + '/complete', {})[2])
        final = json.loads(request('GET', path + '/sync-status')[2])
        self.assertTrue(final['transfer']['receiptVerified'])
        self.assertEqual(final['receiptSha256'], receipt['receiptSha256'])
        self.assertEqual(final['transfer']['status'], 'verified')
        self.assertFalse(final['capture']['successful'])
        self.assertEqual(final['capture']['errorCode'], 'gatt_error')
        self.assertFalse(final['labeling']['eligible'])
        expect_http(404, 'GET', path + '/sync-status', headers={'X-Woona-Account': 'other-account'})

class CalibrationWireCompatibilityTest(unittest.TestCase):
    def test_unknown_calibration_is_not_a_measured_zero(self):
        from server.sync_status import calibration_status
        for offset in [None, 0, 123]:
            result = calibration_status({'calibration_offset_ns': offset, 'sensor_clock_quality': 'first_packet_arrival'})
            self.assertFalse(result['measured'])
            self.assertIsNone(result['offsetNs'])
            self.assertEqual(result['compatibilityPlaceholder'], offset is None)
        self.assertFalse(calibration_status({'calibration_offset_ns': 0, 'sensor_clock_quality': 'calibrated'})['measured'])
