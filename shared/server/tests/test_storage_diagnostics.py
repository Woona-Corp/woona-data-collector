"""Diagnostic limits fail explicitly; authoritative admission remains unchanged."""
import asyncio
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
import os
import unittest
from unittest.mock import Mock, patch
import uuid

from fastapi import HTTPException
import httpx
from sqlalchemy import text

from server import app as api
from server.storage_diagnostics import DiagnosticBudget
from server.storage_policy import reservation_lock
from server.tests.test_api import DEVICE
from server.tests import test_storage_policy as quota_tests


def detail(error: HTTPException) -> dict:
    if not isinstance(error.detail, dict):
        raise AssertionError('Expected structured diagnostic error')
    return error.detail


class DiagnosticBudgetTest(unittest.TestCase):
    def test_row_limit_is_in_sql_and_overflow_never_counts_as_complete(self):
        connection = Mock()
        connection.execute.return_value.mappings.return_value.all.return_value = [{}, {}, {}]
        budget = DiagnosticBudget(2, 1000)
        with self.assertRaises(HTTPException) as caught:
            budget.rows(connection, 'SELECT a.id FROM artifacts a')
        self.assertEqual(detail(caught.exception)['phase'], 'artifact_budget')
        statement, parameters = connection.execute.call_args.args
        self.assertIn('LIMIT :diagnostic_limit', str(statement))
        self.assertEqual(parameters['diagnostic_limit'], 3)
        self.assertEqual(budget.visited, 0)

    def test_shared_row_budget_bounds_both_scans(self):
        connection = Mock()
        connection.execute.return_value.mappings.return_value.all.return_value = [{}, {}]
        budget = DiagnosticBudget(3, 1000)
        self.assertEqual(len(budget.rows(connection, 'SELECT a.id FROM artifacts a')), 2)
        with self.assertRaises(HTTPException):
            budget.rows(connection, 'SELECT a.id FROM artifacts a')
        self.assertEqual(connection.execute.call_args.args[1]['diagnostic_limit'], 2)

    def test_deadline_is_explicit_and_statement_timeout_is_transaction_local(self):
        clock = [0.0]
        budget = DiagnosticBudget(2, 1000, clock=lambda: clock[0])
        connection = Mock()
        budget.query(connection)
        self.assertIn("set_config('statement_timeout', :timeout, true)",
                      str(connection.execute.call_args.args[0]))
        clock[0] = 1.0
        with self.assertRaises(HTTPException) as caught:
            budget.check()
        self.assertEqual(caught.exception.status_code, 503)
        self.assertEqual(detail(caught.exception), {'code': 'storage_status_busy', 'phase': 'time_budget'})
        self.assertEqual((caught.exception.headers or {})['Retry-After'], '1')


class StorageDiagnosticsTest(unittest.TestCase):
    # Compose the existing synthetic fixture helper, without duplicating its tests.
    def setUp(self):
        self.helper = quota_tests.StoragePolicyTest()
        self.helper.setUp()
        self.addCleanup(self.helper.tearDown)
        self.account = self.helper.account

    def fixture(self, size):
        return self.helper.fixture(size)

    def put(self, fixture, account):
        return self.helper.put(fixture, account)

    def test_contended_reservation_lock_fails_fast_without_waiting_for_upload_admission(self):
        held = api.engine.connect()
        transaction = held.begin()
        workers = ThreadPoolExecutor(max_workers=1)
        try:
            reservation_lock(held)
            def inspect():
                try:
                    api.get_storage_status(uuid.UUID(DEVICE), self.account)
                except HTTPException as error:
                    return error
            result = workers.submit(inspect)
            try:
                error = result.result(timeout=0.75)
            except FutureTimeout:
                self.fail('Storage diagnostics waited for the admission lock')
            if not isinstance(error, HTTPException):
                self.fail('Expected retryable diagnostic failure')
            self.assertEqual(error.status_code, 503)
            self.assertEqual(detail(error)['code'], 'storage_status_busy')
        finally:
            transaction.rollback()
            held.close()
            workers.shutdown(wait=True)

    def test_row_budget_returns_no_misleading_partial_capacity_and_does_no_file_stats(self):
        self.put(self.fixture(1), self.account)
        self.put(self.fixture(1), self.account)
        with patch.dict(os.environ, {'WOONA_STORAGE_STATUS_MAX_ARTIFACTS': '1'}), \
                patch('server.storage_policy.Path.lstat') as stat:
            with self.assertRaises(HTTPException) as caught:
                api.get_storage_status(uuid.UUID(DEVICE), self.account)
        self.assertEqual(detail(caught.exception)['phase'], 'artifact_budget')
        stat.assert_not_called()

    def test_database_query_budget_maps_to_retryable_diagnostic_failure(self):
        def slow_query(connection, **kwargs):
            connection.execute(text('SELECT pg_sleep(0.05)'))
            return 0
        with patch.dict(os.environ, {'WOONA_STORAGE_STATUS_TIMEOUT_MS': '10'}), \
                patch('server.storage_policy.reserved_bytes', side_effect=slow_query):
            with self.assertRaises(HTTPException) as caught:
                api.get_storage_status(uuid.UUID(DEVICE), self.account)
        self.assertEqual(caught.exception.status_code, 503)
        self.assertEqual(detail(caught.exception)['code'], 'storage_status_busy')
        self.assertEqual(detail(caught.exception)['phase'], 'query_budget')

    def test_http_budget_failure_has_retry_guidance_and_no_capacity_or_private_paths(self):
        self.put(self.fixture(1), self.account)
        self.put(self.fixture(1), self.account)
        async def inspect():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=api.app),
                                         base_url='http://isolated.test') as client:
                return await client.get('/v1/storage-status', headers={'X-Woona-Account': self.account})
        with patch.dict(os.environ, {'WOONA_STORAGE_STATUS_MAX_ARTIFACTS': '1'}), \
                patch.dict(api.app.dependency_overrides, {api.authenticated_device: lambda: uuid.UUID(DEVICE)}):
            response = asyncio.run(inspect())
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.headers['retry-after'], '1')
        body = response.json()
        self.assertEqual(body['code'], 'storage_status_busy')
        self.assertTrue(body['retryable'])
        self.assertEqual(body['nextAction'], 'retry_later')
        self.assertEqual(response.headers['x-request-id'], body['requestId'])
        self.assertNotIn('admission', body)
        self.assertNotIn(str(self.helper.directory), response.text)

    def test_diagnostic_limits_do_not_reject_authoritative_manifest_admission(self):
        with patch.dict(os.environ, {'WOONA_STORAGE_STATUS_MAX_ARTIFACTS': '1',
                                     'WOONA_STORAGE_STATUS_TIMEOUT_MS': '1'}):
            first, second = self.fixture(1), self.fixture(1)
            self.put(first, self.account)
            self.put(second, self.account)
            self.put(first, self.account)
        with api.engine.connect() as connection:
            self.assertEqual(connection.execute(text('SELECT count(*) FROM recordings WHERE id IN (:a,:b)'),
                {'a': first['recording_id'], 'b': second['recording_id']}).scalar_one(), 2)
