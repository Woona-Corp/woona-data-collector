"""Explicit coverage, byte/time bounds and cross-worker audit admission."""
from contextlib import redirect_stderr
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

from fastapi import HTTPException
from sqlalchemy import text

from server import app as api
from server.integrity_audit import AUDIT_LOCK, audit_limits, inspect_page, integrity_page
from server.tests.test_api import DEVICE, request, expect_http
from server.tests import test_storage_policy as quota_tests
from server.verify_storage import arguments


POLICY = {'maxArtifacts': 10, 'maxFileBytes': 128, 'maxHashBytes': 256,
          'maxSeconds': 2, 'minimumIntervalSeconds': 0}


class IntegrityBoundedReaderTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def row(self, content, name=None):
        identity = uuid.uuid4()
        name = name or str(identity) + '.bin'
        (self.root / name).write_bytes(content)
        return {'id': identity, 'server_relative_path': name, 'expected_size_bytes': len(content),
                'sha256': hashlib.sha256(content).hexdigest()}

    def test_small_and_empty_regular_files_are_fully_hashed(self):
        rows = [self.row(b'correct'), self.row(b'')]
        result = inspect_page(self.root, rows, mode='sha256', policy=POLICY)
        self.assertEqual(result['hashedArtifacts'], 2)
        self.assertEqual(result['hashedBytes'], 7)
        self.assertFalse(result['problems'])
        self.assertFalse(result['uncheckedArtifacts'])

    def test_one_large_file_is_explicitly_unhashed_and_never_enters_sha_reader(self):
        row = self.row(b'L' * 129)
        with patch('server.integrity_audit.hashlib.sha256', side_effect=AssertionError('Large-file hashing must not start')):
            result = inspect_page(self.root, [row], mode='sha256', policy=POLICY)
        self.assertEqual(result['hashedBytes'], 0)
        self.assertEqual(result['uncheckedArtifacts'][0]['reason'], 'file_hash_limit')

    def test_total_hash_budget_applies_across_small_files(self):
        rows = [self.row(b'ab'), self.row(b'cd'), self.row(b'ef')]
        result = inspect_page(self.root, rows, mode='sha256', policy={**POLICY, 'maxHashBytes': 4})
        self.assertEqual(result['hashedBytes'], 4)
        self.assertEqual(result['hashedArtifacts'], 2)
        self.assertEqual(result['uncheckedArtifacts'][0]['reason'], 'page_hash_budget')

    def test_deadline_is_checked_inside_hashing_not_only_between_files(self):
        rows = [self.row(b'ab'), self.row(b'cd')]
        result = inspect_page(self.root, rows, mode='sha256', policy=POLICY,
                              started_at=0, clock=lambda: 3)
        self.assertEqual(result['hashedBytes'], 0)
        self.assertEqual(result['checkedArtifacts'], 1)
        self.assertTrue(result['timeBudgetExhausted'])
        self.assertEqual(result['uncheckedArtifacts'][0]['reason'], 'time_budget')

    def test_deadline_stops_a_partially_read_file_without_accepting_prefix_checksum(self):
        row = self.row(b'x' * (3 * 1024 ** 2))
        ticks = iter((0, 3))
        result = inspect_page(self.root, [row], mode='sha256',
            policy={**POLICY, 'maxFileBytes': 4 * 1024 ** 2, 'maxHashBytes': 4 * 1024 ** 2},
            started_at=0, clock=lambda: next(ticks))
        self.assertEqual(result['hashedBytes'], 1024 ** 2)
        self.assertEqual(result['hashedArtifacts'], 0)
        self.assertEqual(result['uncheckedArtifacts'][0]['reason'], 'time_budget')

    def test_metadata_mode_does_not_claim_any_checksum(self):
        row = self.row(b'ab')
        with patch('server.integrity_audit.hashlib.sha256', side_effect=AssertionError('Metadata mode must not hash')):
            result = inspect_page(self.root, [row], mode='metadata', policy=POLICY)
        self.assertEqual(result['hashedArtifacts'], 0)
        self.assertEqual(result['uncheckedArtifacts'][0]['reason'], 'hash_not_requested')

    def test_missing_mismatched_hash_size_and_nonregular_files_are_visible_without_path_leak(self):
        missing = self.row(b'absent'); (self.root / missing['server_relative_path']).unlink()
        bad_hash = self.row(b'actual'); bad_hash['sha256'] = '0' * 64
        wrong_size = self.row(b'changed'); wrong_size['expected_size_bytes'] += 1
        fifo = self.row(b''); (self.root / fifo['server_relative_path']).unlink()
        os.mkfifo(self.root / fifo['server_relative_path'])
        result = inspect_page(self.root, [missing, bad_hash, wrong_size, fifo], mode='sha256', policy=POLICY)
        self.assertEqual([item['problem'] for item in result['problems']], ['missing', 'hash', 'size', 'not_regular_file'])
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_escape_and_outside_symlink_are_never_opened(self):
        with tempfile.TemporaryDirectory() as outside:
            external = Path(outside) / 'private.bin'; external.write_bytes(b'PRIVATE')
            alias = self.root / 'alias'; alias.symlink_to(external)
            row = {'id': uuid.uuid4(), 'server_relative_path': 'alias', 'expected_size_bytes': 7,
                   'sha256': hashlib.sha256(b'PRIVATE').hexdigest()}
            result = inspect_page(self.root, [row], mode='sha256', policy=POLICY)
            self.assertEqual(result['problems'][0]['problem'], 'missing')
            self.assertEqual(result['hashedBytes'], 0)

    def test_operator_cli_requires_explicit_scope_and_keeps_resource_budgets_bounded(self):
        for argv in ([], ['--unassigned', '--account', 'a'], ['--unassigned', '--max-bytes', '0'],
                     ['--unassigned', '--max-seconds', '3601'], ['--unassigned', '--limit', '101']):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                arguments(argv)
        result = arguments(['--account', 'clinic', '--max-bytes', '4294967296', '--limit', '10'])
        self.assertEqual((result.account, result.max_bytes, result.limit), ('clinic', 4294967296, 10))

    def test_http_configuration_cannot_remove_byte_time_page_or_cooldown_bounds(self):
        with patch.dict(os.environ, {'WOONA_INTEGRITY_MAX_ARTIFACTS': '100000',
                'WOONA_INTEGRITY_MAX_FILE_BYTES': str(1024 ** 4),
                'WOONA_INTEGRITY_MAX_HASH_BYTES': str(1024 ** 4),
                'WOONA_INTEGRITY_MAX_SECONDS': '3600', 'WOONA_INTEGRITY_MIN_INTERVAL_SECONDS': '0'}):
            bounded = audit_limits()
        self.assertEqual(bounded, {'maxArtifacts': 100, 'maxFileBytes': 64 * 1024 ** 2,
            'maxHashBytes': 256 * 1024 ** 2, 'maxSeconds': 5, 'minimumIntervalSeconds': 1})


class IntegrityApiBudgetTest(unittest.TestCase):
    # Reuse fixture construction/cleanup without inheriting and duplicating the
    # independent quota test cases in unittest discovery.
    setUp = quota_tests.StoragePolicyTest.setUp
    tearDown = quota_tests.StoragePolicyTest.tearDown
    fixture = quota_tests.StoragePolicyTest.fixture
    put = quota_tests.StoragePolicyTest.put

    def available(self, content):
        fixture = self.fixture(len(content), content)
        self.put(fixture, self.account)
        artifact = fixture['manifest']['artifacts'][0]['id']
        path = self.directory / (artifact + '.bin')
        path.write_bytes(content)
        with api.engine.begin() as connection:
            connection.execute(text("UPDATE artifacts SET stored_size_bytes=expected_size_bytes, storage_status='available', server_relative_path=:path, verified_at=now() WHERE id=:id"),
                               {'id': artifact, 'path': str(path.relative_to(api.STORAGE_ROOT))})
        return artifact

    def audit(self, mode='sha256', limit=10, cursor=None, policy=None):
        with api.engine.begin() as connection:
            return integrity_page(connection, api.STORAGE_ROOT, self.account, mode=mode,
                                  limit=limit, cursor=cursor, policy=policy or POLICY)

    def test_cursor_visits_each_scoped_artifact_once_and_never_labels_one_page_global_ok(self):
        ids = {self.available(b'a'), self.available(b'b'), self.available(b'c')}
        seen, cursor = [], None
        while True:
            result = self.audit(limit=1, cursor=cursor)
            self.assertEqual(result['status'], 'partial')
            self.assertFalse(result['coverage']['scopeChecksumVerified'])
            self.assertTrue(result['coverage']['pageChecksumVerified'])
            self.assertEqual(result['scopeArtifacts'], 3)
            if result['hasMore']:
                seen.append(result['nextCursor']); cursor = result['nextCursor']
            else:
                break
        self.assertEqual(len(set(seen)), 2)
        self.assertTrue(set(seen).issubset(ids))
        whole = self.audit()
        self.assertEqual(whole['status'], 'ok')
        self.assertTrue(whole['coverage']['scopeChecksumVerified'])
        self.assertEqual(whole['checkedArtifacts'], 3)

    def test_large_and_metadata_results_are_honest_partial(self):
        self.available(b'x' * 129)
        result = self.audit()
        self.assertEqual(result['status'], 'partial')
        self.assertEqual(result['nextAction'], 'run_operator_integrity_audit')
        self.assertEqual(result['hashedBytes'], 0)
        metadata = self.audit(mode='metadata')
        self.assertEqual(metadata['status'], 'partial')
        self.assertFalse(metadata['coverage']['scopeChecksumVerified'])

    def test_real_http_rejects_unbounded_modes_bad_cursor_and_requires_authentication(self):
        for query in ('mode=full', 'limit=101', 'limit=0', 'cursor=not-a-uuid'):
            expect_http(422, 'GET', '/v1/integrity?' + query)
        expect_http(401, 'GET', '/v1/integrity?mode=metadata', token='invalid')
        self.available(b'ok')
        result = json.loads(request('GET', '/v1/integrity?mode=metadata', headers={'X-Woona-Account': self.account})[2])
        self.assertEqual(result['checkedArtifacts'], 1)
        self.assertFalse(result['checkedScope']['includesAllAccounts'])
        self.assertEqual(result['hashedBytes'], 0)
        self.assertEqual(result['status'], 'partial')

    def test_concurrent_worker_returns_429_instead_of_starting_a_second_scan(self):
        with api.engine.begin() as connection:
            connection.execute(text('SELECT pg_advisory_xact_lock(:key)'), {'key': AUDIT_LOCK})
            error = expect_http(429, 'GET', '/v1/integrity?mode=metadata')
        self.assertEqual(error['code'], 'integrity_check_busy')
        self.assertTrue(error['retryable'])
        self.assertEqual(error['phase'], 'concurrent_audit')

    def test_persisted_cooldown_applies_to_a_fresh_connection_and_metadata_does_not_hash(self):
        with api.engine.begin() as connection:
            connection.execute(text('DELETE FROM integrity_check_budget'))
        try:
            self.audit(policy={**POLICY, 'minimumIntervalSeconds': 60})
            with self.assertRaises(HTTPException) as caught:
                self.audit(policy={**POLICY, 'minimumIntervalSeconds': 60})
            self.assertEqual(caught.exception.status_code, 429)
            self.assertEqual(caught.exception.detail['phase'], 'cooldown')
            self.assertGreaterEqual(int(caught.exception.headers['Retry-After']), 1)
            self.audit(mode='metadata')
        finally:
            with api.engine.begin() as connection:
                connection.execute(text('DELETE FROM integrity_check_budget'))

    def test_database_lock_wait_is_bounded_and_returns_a_retryable_budget_error(self):
        from concurrent.futures import ThreadPoolExecutor
        def blocked_request():
            try:
                api.integrity(uuid.UUID(DEVICE), self.account, mode='sha256', limit=10)
                return None
            except HTTPException as error:
                return error
        with api.engine.begin() as gate, ThreadPoolExecutor(max_workers=1) as worker:
            gate.execute(text('LOCK TABLE integrity_check_budget IN ACCESS EXCLUSIVE MODE'))
            error = worker.submit(blocked_request).result(timeout=6)
            self.assertIsNotNone(error)
            self.assertEqual(error.status_code, 429)
            self.assertEqual(error.detail['phase'], 'metadata_query_budget')
        with api.engine.connect() as connection:
            self.assertEqual(connection.execute(text('SHOW statement_timeout')).scalar_one(), '0')

    def test_retired_available_artifact_is_outside_audit_scope(self):
        identity = self.available(b'kept source')
        digest = hashlib.sha256(identity.encode()).hexdigest()
        with api.engine.begin() as connection:
            connection.execute(text("INSERT INTO retired_entities(kind,id_sha256) VALUES('artifact',:hash)"), {'hash': digest})
        try:
            result = self.audit()
            self.assertEqual(result['scopeArtifacts'], 0)
            self.assertEqual(result['checkedArtifacts'], 0)
        finally:
            with api.engine.begin() as connection:
                connection.execute(text("DELETE FROM retired_entities WHERE kind='artifact' AND id_sha256=:hash"), {'hash': digest})

    def test_operator_cli_verifies_explicit_large_budget_without_exposing_http_full_mode(self):
        import subprocess
        import sys
        with patch.dict(os.environ, {'WOONA_RECORDING_QUOTA_BYTES': '0', 'WOONA_ACCOUNT_QUOTA_BYTES': '0'}):
            self.available(b'L' * (17 * 1024 ** 2))
        def reset_budget():
            with api.engine.begin() as connection:
                connection.execute(text('DELETE FROM integrity_check_budget'))
        try:
            reset_budget()
            bounded = json.loads(request('GET', '/v1/integrity', headers={'X-Woona-Account': self.account})[2])
            self.assertEqual(bounded['status'], 'partial')
            self.assertEqual(bounded['hashedBytes'], 0)
            reset_budget()
            verified = subprocess.run([sys.executable, '-m', 'server.verify_storage', '--account', self.account,
                '--max-bytes', str(20 * 1024 ** 2), '--max-seconds', '10'], capture_output=True, text=True, timeout=15)
            self.assertEqual(verified.returncode, 0, verified.stderr)
            report = json.loads(verified.stdout)
            self.assertEqual(report['hashedBytes'], 17 * 1024 ** 2)
            self.assertTrue(report['coverage']['scopeChecksumVerified'])
            reset_budget()
            partial = subprocess.run([sys.executable, '-m', 'server.verify_storage', '--account', self.account,
                '--max-bytes', '128'], capture_output=True, text=True, timeout=15)
            self.assertEqual(partial.returncode, 2, partial.stderr)
            self.assertEqual(json.loads(partial.stdout)['status'], 'partial')
        finally:
            reset_budget()
