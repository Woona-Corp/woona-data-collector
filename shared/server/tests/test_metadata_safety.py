"""Regressions for malformed metadata found by the bounded isolated API fuzz run."""
import copy
import unittest
import uuid
from unittest.mock import MagicMock, patch

from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from pydantic import ValidationError
from server.app import (RecordingManifest, ProfilePut, StrictModel, apply_profile,
                        request_id_middleware, validation_error)
from server.tests.test_error_status import AsgiClient
from server.tests.tools.isolated_load_fuzz import make_fixture


class MetadataSafetyTest(unittest.TestCase):
    def setUp(self):
        self.fixture = make_fixture(0, 'loadtest-' + '0' * 32, str(uuid.uuid4()))

    def test_timezone_required_for_every_utc_field_and_utc_range_checked(self):
        routes = [('recording', 'startedAtUtc'), ('recording', 'endedAtUtc'),
                  ('sync', 'sessionZeroAtUtc'), ('dogProfileVersion', 'clientCreatedAtUtc')]
        for parent, key in routes:
            for stamp in ['2026-10-26T12:00:00', '2026-10-26',
                          '0001-01-01T00:00:00+14:00', '9999-12-31T23:59:59-14:00']:
                with self.subTest(parent=parent, key=key, stamp=stamp):
                    manifest = copy.deepcopy(self.fixture['manifest']);manifest[parent][key] = stamp
                    with self.assertRaises(ValidationError):RecordingManifest.model_validate(manifest)
        manifest = self.fixture['manifest']
        manifest['recording']['startedAtUtc'] = '2026-10-26T15:00:00+03:00'
        self.assertIsNotNone(RecordingManifest.model_validate(manifest).recording.started_at_utc.tzinfo)

    def test_unicode_nul_nonfinite_integer_and_depth_are_rejected_before_hashing(self):
        for bad in ['\ud800', '\udfff', '\x00', float('nan'), float('inf'), -(2**63)-1, 2**63]:
            for key in ('numberOrName', 'notes'):
                manifest = copy.deepcopy(self.fixture['manifest'])
                manifest['dogProfileVersion']['questionnaire'][key] = bad
                with self.subTest(key=key, bad=repr(bad)), self.assertRaises(ValidationError):
                    RecordingManifest.model_validate(manifest)
        manifest = copy.deepcopy(self.fixture['manifest'])
        manifest['dogProfileVersion']['questionnaire']['\ud800'] = 'invalid-key'
        with self.assertRaises(ValidationError):RecordingManifest.model_validate(manifest)
        nested = 0
        for _ in range(100):nested = {'nested': nested}
        manifest['dogProfileVersion']['questionnaire'] = nested
        with self.assertRaises(ValidationError):RecordingManifest.model_validate(manifest)
        manifest = self.fixture['manifest']
        manifest['dogProfileVersion']['questionnaire']['numberOrName'] = 'Пёс 🐕'
        self.assertEqual(RecordingManifest.model_validate(manifest).dog_profile_version.questionnaire['numberOrName'], 'Пёс 🐕')

    def test_storage_ranges_apply_after_numeric_coercion(self):
        for field, value in [('sessionZeroMonotonicNs', str(2**63)),
                             ('calibrationOffsetNs', 1e30), ('estimatedDriftPpm', 'NaN'),
                             ('schemaVersion', 32768)]:
            manifest = copy.deepcopy(self.fixture['manifest']);manifest['sync'][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValidationError):
                RecordingManifest.model_validate(manifest)
        manifest = self.fixture['manifest'];manifest['sync']['calibrationOffsetNs'] = -(2**63)
        self.assertEqual(RecordingManifest.model_validate(manifest).sync.calibration_offset_ns, -(2**63))

    def test_http_validation_is_safe_and_explains_fields_without_echoing_bad_input(self):
        app = FastAPI()
        app.middleware('http')(request_id_middleware)
        app.add_exception_handler(RequestValidationError, validation_error)
        @app.put('/metadata')
        def metadata(payload: RecordingManifest):
            return {'accepted': True}
        client = AsgiClient(app)
        for value in ['\ud800', '\x00', float('inf')]:
            manifest = copy.deepcopy(self.fixture['manifest'])
            manifest['dogProfileVersion']['questionnaire']['notes'] = value
            response = client.request('PUT', '/metadata', manifest,
                {'Content-Type': 'application/json', 'X-Request-ID': 'metadata-safety'})
            self.assertEqual(response.status_code, 422)
            result = response.json()
            self.assertEqual(result['requestId'], response.headers['x-request-id'])
            self.assertEqual(result['nextAction'], 'review_invalid_fields')
            self.assertTrue(result['fieldErrors'])

    def test_duplicate_profile_content_is_conflict_before_any_updates(self):
        payload = ProfilePut.model_validate(self.fixture['profile'])
        existing_id = uuid.uuid4()
        connection = MagicMock()
        def execute(query, parameters):
            result = MagicMock()
            sql = str(query)
            if sql.startswith('SELECT dog_id,content_sha256,questionnaire'):
                result.mappings.return_value.first.return_value = None
            elif sql.startswith('SELECT id FROM dog_profile_versions'):
                result.scalar_one_or_none.return_value = existing_id
            else:
                self.fail('Duplicate content must not mutate or supersede any row: ' + sql)
            return result
        connection.execute.side_effect = execute
        with patch('server.app.assert_dog_account'), patch('server.app.ensure_not_retired'):
            with self.assertRaises(HTTPException) as caught:
                apply_profile(connection, payload.dog, payload.profile_version, uuid.uuid4())
        self.assertEqual(caught.exception.status_code, 409)
        self.assertEqual(caught.exception.detail['code'], 'profile_content_already_exists')
        self.assertEqual(caught.exception.detail['existingProfileVersionId'], str(existing_id))
        self.assertEqual(connection.execute.call_count, 2)
