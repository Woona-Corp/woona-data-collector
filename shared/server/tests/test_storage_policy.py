"""Isolated PostgreSQL admission, ownership and offset regressions."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from fastapi import HTTPException
from sqlalchemy import text
from starlette.requests import Request

from server import app as api
from server.errors import error_guidance
from server.storage_policy import limits, storage_status
from server.tests.test_api import DEVICE, request, expect_http
from server.tests.tools.isolated_load_fuzz import make_fixture


class StoragePolicyTest(unittest.TestCase):
    def setUp(self):
        self.fixtures = []
        self.account = 'qa-quota-' + uuid.uuid4().hex
        self.directory = api.STORAGE_ROOT / ('qa-quota-' + uuid.uuid4().hex)
        self.directory.mkdir()
        self.env = patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '1000',
            'WOONA_RECORDING_QUOTA_BYTES': '1000', 'WOONA_UPLOAD_FREE_SPACE_RESERVE_BYTES': '0'})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        with api.engine.begin() as connection:
            for fixture in self.fixtures:
                manifest = fixture['manifest']
                for artifact in manifest['artifacts']:
                    api.incoming_path(uuid.UUID(artifact['id'])).unlink(missing_ok=True)
                connection.execute(text('DELETE FROM artifacts WHERE recording_id=:id'), {'id': fixture['recording_id']})
                connection.execute(text('DELETE FROM recording_sync WHERE recording_id=:id'), {'id': fixture['recording_id']})
                connection.execute(text('DELETE FROM recordings WHERE id=:id'), {'id': fixture['recording_id']})
                connection.execute(text('DELETE FROM dog_profile_versions WHERE dog_id=:id'), {'id': manifest['dog']['id']})
                connection.execute(text('DELETE FROM dog_external_ids WHERE dog_id=:id'), {'id': manifest['dog']['id']})
                connection.execute(text('DELETE FROM dogs WHERE id=:id'), {'id': manifest['dog']['id']})
        shutil.rmtree(self.directory)

    def fixture(self, size, data=None):
        fixture = make_fixture(len(self.fixtures), 'quota-' + uuid.uuid4().hex, DEVICE)
        manifest = fixture['manifest']
        manifest['recording']['captureStatus'] = 'failed'
        manifest['artifacts'] = [manifest['artifacts'][0]]
        manifest['artifacts'][0].update(sizeBytes=size, sha256=hashlib.sha256(data or b'fixture').hexdigest())
        self.fixtures.append(fixture)
        return fixture

    def put(self, fixture, account=None):
        return api.put_recording(uuid.UUID(fixture['recording_id']),
            api.RecordingManifest.model_validate(fixture['manifest']), uuid.UUID(DEVICE), account)

    def assert_absent(self, fixture):
        with api.engine.connect() as connection:
            for table, identity in [('recordings', fixture['recording_id']),
                                    ('dogs', fixture['manifest']['dog']['id']),
                                    ('dog_profile_versions', fixture['manifest']['dogProfileVersion']['id'])]:
                self.assertEqual(connection.execute(text(f'SELECT count(*) FROM {table} WHERE id=:id'),
                    {'id': identity}).scalar_one(), 0)

    def test_recording_quota_rejects_the_whole_transaction_and_explains_nonretryable_action(self):
        fixture = self.fixture(11)
        with patch.dict(os.environ, {'WOONA_RECORDING_QUOTA_BYTES': '10'}):
            with self.assertRaises(HTTPException) as caught:
                self.put(fixture, self.account)
        self.assertEqual((caught.exception.status_code, caught.exception.detail['quotaScope']), (413, 'recording'))
        self.assertEqual(caught.exception.detail['code'], 'storage_quota_exceeded')
        self.assertFalse(error_guidance('storage_quota_exceeded', 413)['retryable'])
        self.assert_absent(fixture)

    def test_whole_manifest_quota_is_checked_before_physical_admission_of_any_file(self):
        fixture = self.fixture(6)
        second = dict(fixture['manifest']['artifacts'][0])
        second.update(id=str(uuid.uuid4()), fileName='second.bin')
        fixture['manifest']['artifacts'].append(second)
        with patch.dict(os.environ, {'WOONA_RECORDING_QUOTA_BYTES': '10'}), \
                patch('server.storage_policy.shutil.disk_usage') as usage:
            with self.assertRaises(HTTPException) as caught:
                self.put(fixture, self.account)
            usage.assert_not_called()
        self.assertEqual((caught.exception.status_code, caught.exception.detail['quotaScope']), (413, 'recording'))
        self.assertEqual(caught.exception.detail['requestedBytes'], 12)
        self.assert_absent(fixture)

    def test_real_http_manifest_quota_error_has_request_id_and_does_not_create_rows(self):
        fixture = self.fixture(21 * 1024 ** 3)
        body = expect_http(413, 'PUT', '/v1/recordings/' + fixture['recording_id'],
                           fixture['manifest'], headers={'X-Woona-Account': self.account})
        self.assertEqual(body['code'], 'storage_quota_exceeded')
        self.assertEqual(body['quotaScope'], 'recording')
        self.assertFalse(body['retryable'])
        self.assertEqual(body['nextAction'], 'review_server_storage_limits')
        self.assertTrue(body['requestId'])
        self.assert_absent(fixture)

    def test_pending_sizes_charge_account_quota_and_other_accounts_remain_independent(self):
        first, second, other = self.fixture(60), self.fixture(41), self.fixture(41)
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '100'}):
            self.put(first, self.account)
            with self.assertRaises(HTTPException) as caught:
                self.put(second, self.account)
            self.put(other, self.account + '-other')
        self.assertEqual(caught.exception.detail['quotaScope'], 'account')
        self.assertEqual(caught.exception.detail['reservedBytes'], 60)
        self.assert_absent(second)

    def test_idempotent_manifest_retry_and_existing_upload_resume_survive_lowered_limits(self):
        fixture = self.fixture(4, b'ABCD')
        self.put(fixture, self.account)
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '1', 'WOONA_RECORDING_QUOTA_BYTES': '1'}):
            self.put(fixture, self.account)
            sent = False
            async def receive():
                nonlocal sent
                if sent: return {'type': 'http.disconnect'}
                sent = True
                return {'type': 'http.request', 'body': b'ABCD', 'more_body': False}
            native = Request({'type': 'http', 'headers': [(b'content-length', b'4')]}, receive)
            identity = uuid.UUID(fixture['manifest']['artifacts'][0]['id'])
            response = asyncio.run(api.patch_artifact(identity, native, uuid.UUID(DEVICE), 0))
            self.assertEqual(response.headers['upload-offset'], '4')
            self.assertEqual(api.complete_artifact(identity, uuid.UUID(DEVICE))['sizeBytes'], 4)
            with api.engine.connect() as connection:
                relative = connection.execute(text('SELECT server_relative_path FROM artifacts WHERE id=:id'), {'id': identity}).scalar_one()
            self.assertEqual((api.STORAGE_ROOT / relative).read_bytes(), b'ABCD')
            # Remove only this generated fixture's verified bytes.
            (api.STORAGE_ROOT / relative).unlink()

    def test_account_quota_concurrency_admits_exactly_one_and_rolls_back_the_other(self):
        fixtures = [self.fixture(60), self.fixture(60)]
        with api.engine.begin() as connection:
            api.ensure_account(connection, self.account)
        def accept(fixture):
            try: self.put(fixture, self.account); return 200
            except HTTPException as error: return error.status_code
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '100'}), ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(accept, fixtures))
        self.assertEqual(sorted(results), [200, 413])
        self.assert_absent(fixtures[results.index(413)])

    def test_physical_reservations_serialize_across_accounts_before_any_bytes_are_written(self):
        fixtures = [self.fixture(60), self.fixture(60)]
        def accept(pair):
            index, fixture = pair
            try: self.put(fixture, self.account + str(index)); return 200
            except HTTPException as error: return error.status_code
        with patch('server.storage_policy.shutil.disk_usage', return_value=SimpleNamespace(free=100)), ThreadPoolExecutor(max_workers=2) as workers:
            # Other synthetic pending rows may exist in the suite. Use this
            # account pair's fixed generated set for the physical boundary.
            with patch('server.storage_policy.pending_reservation', side_effect=lambda connection, root:
                (sum(connection.execute(text('SELECT expected_size_bytes FROM artifacts WHERE id IN (CAST(:a AS uuid),CAST(:b AS uuid))'),
                     {'a': fixtures[0]['manifest']['artifacts'][0]['id'], 'b': fixtures[1]['manifest']['artifacts'][0]['id']}).scalars()), 0)):
                results = list(workers.map(accept, enumerate(fixtures)))
        self.assertEqual(sorted(results), [200, 507])
        self.assert_absent(fixtures[results.index(507)])

    def test_missing_part_is_fully_reserved_and_rejection_preserves_existing_prefix(self):
        first, second = self.fixture(20), self.fixture(10)
        self.put(first, self.account)
        identity = uuid.UUID(first['manifest']['artifacts'][0]['id'])
        part = api.incoming_path(identity)
        part.write_bytes(b'P' * 10)
        with api.engine.begin() as connection:
            connection.execute(text('UPDATE artifacts SET stored_size_bytes=10 WHERE id=:id'), {'id': identity})
        # Isolate the reservation arithmetic while retaining its actual file stat.
        from server.storage_policy import pending_reservation
        with api.engine.connect() as connection:
            before_pending = pending_reservation(connection, api.STORAGE_ROOT)[0]
        with patch('server.storage_policy.shutil.disk_usage', return_value=SimpleNamespace(free=before_pending + 9)):
            with self.assertRaises(HTTPException) as caught: self.put(second, self.account)
        self.assertEqual(caught.exception.detail['code'], 'storage_reservation_unavailable')
        self.assertEqual(part.read_bytes(), b'P' * 10)
        self.assert_absent(second)
        part.unlink()
        with api.engine.connect() as connection:
            after_pending = pending_reservation(connection, api.STORAGE_ROOT)[0]
        self.assertEqual(after_pending, before_pending + 10)

    def test_reference_admission_counts_unique_artifacts_and_idempotent_retry_only_once(self):
        fixture = self.fixture(50)
        self.put(fixture, self.account)
        reference = api.ArtifactPayload.model_validate({'id': str(uuid.uuid4()), 'type': 'ecg',
            'fileName': 'reference.csv', 'mimeType': 'text/csv', 'sizeBytes': 10,
            'sha256': hashlib.sha256(b'R' * 10).hexdigest(), 'clientCreatedAtUtc': '2026-10-29T10:00:00Z',
            'referenceMetadata': {'source': 'Synthetic reference', 'startedAtUtc': '2026-10-29T10:00:00Z',
                                  'endedAtUtc': '2026-10-29T10:01:00Z'}})
        with patch.dict(os.environ, {'WOONA_RECORDING_QUOTA_BYTES': '60'}):
            api.add_reference(uuid.UUID(fixture['recording_id']), reference, uuid.UUID(DEVICE))
            api.add_reference(uuid.UUID(fixture['recording_id']), reference, uuid.UUID(DEVICE))
            extra = reference.model_copy(update={'id': uuid.uuid4(), 'file_name': 'extra.csv', 'size_bytes': 1})
            with self.assertRaises(HTTPException) as caught:
                api.add_reference(uuid.UUID(fixture['recording_id']), extra, uuid.UUID(DEVICE))
        self.assertEqual(caught.exception.detail['quotaScope'], 'recording')

    def test_account_assignment_cannot_bypass_quota_and_idempotent_link_survives_lowered_limit(self):
        old, owned = self.fixture(80), self.fixture(30)
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '0'}):
            self.put(old)
        self.put(owned, self.account)
        assignment = api.AccountAssignment(accountId=self.account)
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '100'}):
            with self.assertRaises(HTTPException):
                api.assign_dog_account(uuid.UUID(old['manifest']['dog']['id']), assignment, uuid.UUID(DEVICE), self.account)
        with api.engine.connect() as connection:
            self.assertIsNone(connection.execute(text('SELECT account_id FROM dogs WHERE id=:id'), {'id': old['manifest']['dog']['id']}).scalar_one())
        api.assign_dog_account(uuid.UUID(old['manifest']['dog']['id']), assignment, uuid.UUID(DEVICE), self.account)
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '1'}):
            api.assign_dog_account(uuid.UUID(old['manifest']['dog']['id']), assignment, uuid.UUID(DEVICE), self.account)

    def test_status_never_promises_new_capacity_when_account_quota_is_exhausted(self):
        self.put(self.fixture(100), self.account)
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '100'}), api.engine.begin() as connection:
            result = storage_status(connection, api.STORAGE_ROOT, self.account)
        self.assertEqual(result['status'], 'account_quota_reached')
        self.assertEqual(result['account']['remainingQuotaBytes'], 0)
        self.assertEqual(result['admission']['newArtifactUpperBoundBytes'], 0)
        self.assertIn('account_quota_reached', result['admission']['blockingReasons'])
        self.assertTrue(result['existingUploadsMayResume'])
        self.assertFalse(result['automaticDeletionEnabled'])

    def test_status_uses_current_prefix_instead_of_stale_database_acknowledgement(self):
        fixture = self.fixture(20)
        self.put(fixture, self.account)
        identity = uuid.UUID(fixture['manifest']['artifacts'][0]['id'])
        with api.engine.begin() as connection:
            connection.execute(text('UPDATE artifacts SET stored_size_bytes=10 WHERE id=:id'), {'id': identity})
        with api.engine.begin() as connection:
            missing = storage_status(connection, api.STORAGE_ROOT, self.account)
        self.assertEqual(missing['account']['acknowledgedBytes'], 0)
        self.assertEqual(missing['account']['metadataAcknowledgedBytes'], 10)
        api.incoming_path(identity).write_bytes(b'P' * 6)
        with api.engine.begin() as connection:
            resumed = storage_status(connection, api.STORAGE_ROOT, self.account)
        self.assertEqual(resumed['account']['acknowledgedBytes'], 6)

    def test_external_pending_symlink_cannot_fake_reserved_or_received_bytes(self):
        import tempfile
        fixture = self.fixture(20)
        self.put(fixture, self.account)
        identity = uuid.UUID(fixture['manifest']['artifacts'][0]['id'])
        with api.engine.begin() as connection:
            connection.execute(text('UPDATE artifacts SET stored_size_bytes=10 WHERE id=:id'), {'id': identity})
        with tempfile.TemporaryDirectory() as outside:
            private = Path(outside) / 'private.bin'
            private.write_bytes(b'PRIVATE-DATA')
            api.incoming_path(identity).symlink_to(private)
            with api.engine.begin() as connection:
                result = storage_status(connection, api.STORAGE_ROOT, self.account)
            self.assertEqual(result['account']['acknowledgedBytes'], 0)
            self.assertGreaterEqual(result['serverStorage']['pendingReservedBytes'], 20)
            self.assertEqual(private.read_bytes(), b'PRIVATE-DATA')

    def test_offset_and_corrupt_resets_can_race_manifest_admission_without_lock_inversion(self):
        import threading
        for corrupt in (False, True):
            with self.subTest(corrupt=corrupt):
                old, new = self.fixture(4, b'GOOD'), self.fixture(3)
                self.put(old, self.account)
                identity = uuid.UUID(old['manifest']['artifacts'][0]['id'])
                part = api.incoming_path(identity)
                if corrupt:
                    part.write_bytes(b'BADD')
                with api.engine.begin() as connection:
                    connection.execute(text('UPDATE artifacts SET stored_size_bytes=4 WHERE id=:id'), {'id': identity})
                gate = threading.Barrier(2)
                def reset():
                    gate.wait(timeout=5)
                    if corrupt:
                        try: api.complete_artifact(identity, uuid.UUID(DEVICE))
                        except HTTPException as error: return error.status_code
                    async def receive(): return {'type': 'http.request', 'body': b'G', 'more_body': False}
                    native = Request({'type': 'http', 'headers': [(b'content-length', b'1')]}, receive)
                    return asyncio.run(api.patch_artifact(identity, native, uuid.UUID(DEVICE), 0)).status_code
                def create():
                    gate.wait(timeout=5)
                    self.put(new, self.account + '-new')
                    return 200
                with ThreadPoolExecutor(max_workers=2) as workers:
                    reset_future, create_future = workers.submit(reset), workers.submit(create)
                    self.assertEqual(reset_future.result(timeout=10), 422 if corrupt else 204)
                    self.assertEqual(create_future.result(timeout=10), 200)
                self.assertEqual(part.read_bytes(), b'' if corrupt else b'G')

    def test_status_http_is_authenticated_and_does_not_include_other_account_entities(self):
        expect_http(401, 'GET', '/v1/storage-status', token='invalid')
        self.put(self.fixture(25), self.account)
        other = self.fixture(17)
        self.put(other, self.account + '-other')
        body = json.loads(request('GET', '/v1/storage-status', headers={'X-Woona-Account': self.account})[2])
        self.assertEqual(body['account']['declaredReservedBytes'], 25)
        self.assertEqual(body['checkedScope']['accountId'], self.account)
        self.assertFalse(body['checkedScope']['includesAllAccounts'])
        self.assertEqual(body['serverStorage']['scope'], 'server')
        self.assertNotIn(self.directory.name, json.dumps(body))
        self.assertNotIn(other['recording_id'], json.dumps(body))
        self.assertNotIn(other['manifest']['dog']['id'], json.dumps(body))
        self.assertNotIn(self.account + '-other', json.dumps(body))

    def test_limit_configuration_is_explicit_and_zero_disables_only_quota_not_safety(self):
        with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': '0'}):
            self.assertEqual(limits()['accountBytes'], 0)
        for invalid in ('-1', 'not-an-integer', str(2 ** 63)):
            with patch.dict(os.environ, {'WOONA_ACCOUNT_QUOTA_BYTES': invalid}), self.assertRaises(RuntimeError):
                limits()

    def test_retired_parents_and_child_stop_charging_without_removing_their_bytes(self):
        from server.storage_policy import pending_reservation, reserved_bytes
        fixture = self.fixture(20)
        self.put(fixture, self.account)
        artifact = fixture['manifest']['artifacts'][0]['id']
        part = api.incoming_path(uuid.UUID(artifact))
        part.write_bytes(b'P' * 5)
        ids = {'dog': fixture['manifest']['dog']['id'],
               'profile': fixture['manifest']['dogProfileVersion']['id'],
               'recording': fixture['recording_id'], 'artifact': artifact}
        for kind, identity in ids.items():
            digest = hashlib.sha256(identity.encode()).hexdigest()
            with self.subTest(kind=kind), api.engine.begin() as connection:
                before = pending_reservation(connection, api.STORAGE_ROOT)[0]
                connection.execute(text('INSERT INTO retired_entities(kind,id_sha256) VALUES(:kind,:hash)'),
                                   {'kind': kind, 'hash': digest})
                try:
                    self.assertEqual(reserved_bytes(connection, account=self.account), 0)
                    self.assertEqual(pending_reservation(connection, api.STORAGE_ROOT)[0], before - 20)
                    self.assertEqual(part.read_bytes(), b'P' * 5)
                finally:
                    connection.execute(text('DELETE FROM retired_entities WHERE kind=:kind AND id_sha256=:hash'),
                                       {'kind': kind, 'hash': digest})
