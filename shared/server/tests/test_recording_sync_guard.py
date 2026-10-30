"""Missing synchronization metadata must fail safely, not fabricate timestamps."""
import unittest
import uuid

from sqlalchemy import text

from server import app as api
from server.tests import test_storage_policy as quota_tests
from server.tests.test_api import DEVICE, expect_http


class RecordingSyncGuardTest(unittest.TestCase):
    def test_missing_sync_row_is_explicit_retryable_failure_without_invented_metadata(self):
        helper = quota_tests.StoragePolicyTest()
        helper.setUp()
        self.addCleanup(helper.tearDown)
        fixture = helper.fixture(1)
        helper.put(fixture, helper.account)
        identity = fixture['recording_id']
        self.assertIn('sync', api.get_recording(uuid.UUID(identity), uuid.UUID(DEVICE)))
        with api.engine.begin() as connection:
            connection.execute(text('DELETE FROM recording_sync WHERE recording_id=:id'), {'id': identity})
        body = expect_http(503, 'GET', '/v1/recordings/' + identity,
                           headers={'X-Woona-Account': helper.account})
        self.assertEqual(body['code'], 'recording_metadata_incomplete')
        self.assertTrue(body['retryable'])
        self.assertEqual(body['nextAction'], 'contact_support_preserve_local_data')
        self.assertNotIn('sync', body)
