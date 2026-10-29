"""Regressions for confirmed QA02/03/10/11/12/17/19 backend failures."""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import errno
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
import urllib.error
from unittest.mock import MagicMock, patch
import uuid

from fastapi import FastAPI, HTTPException
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from starlette.requests import Request

from server import app as api
from server.safety import LOCAL_ONLY_TOKEN, append_upload, production_auth_guard
from server.tests.test_api import DEVICE, engine, expect_http, patch_bytes, request
from server.tests.tools.isolated_load_fuzz import make_fixture
from server.tests.test_error_status import AsgiClient


class BackendSafetyUnitTest(unittest.TestCase):
    def test_storage_full_http_has_request_id_retry_action_and_no_private_path(self):
        app = FastAPI()
        app.middleware('http')(api.request_id_middleware)
        app.add_exception_handler(OSError, api.storage_error)
        @app.get('/disk-fault')
        def disk_fault(): raise OSError(errno.ENOSPC, 'PRIVATE server path')
        response = AsgiClient(app).get('/disk-fault', {'X-Request-ID': 'qa-disk'})
        self.assertEqual(response.status_code, 507)
        payload = response.json()
        self.assertEqual(payload['requestId'], response.headers['x-request-id'])
        self.assertEqual(payload['code'], 'storage_full')
        self.assertEqual(payload['nextAction'], 'retry_after_storage_available')
        self.assertTrue(payload['retryable'])
        self.assertNotIn('PRIVATE', response.text)

    def test_production_rejects_example_empty_and_active_example_rows_without_echo(self):
        connection = MagicMock()
        with patch.dict(os.environ, {'WOONA_ENVIRONMENT': 'production'}):
            for token in ('', '   ', LOCAL_ONLY_TOKEN):
                with self.subTest(token_length=len(token)), self.assertRaises(RuntimeError) as caught:
                    production_auth_guard(connection, token)
                self.assertNotIn(LOCAL_ONLY_TOKEN, str(caught.exception))
            connection.execute.assert_not_called()
            connection.execute.return_value.first.return_value = (1,)
            with self.assertRaisesRegex(RuntimeError, 'active example'):
                production_auth_guard(connection, 'synthetic-private-token')
            connection.execute.return_value.first.return_value = None
            production_auth_guard(connection, 'synthetic-private-token')
        with patch.dict(os.environ, {'WOONA_ENVIRONMENT': 'development'}):
            connection.reset_mock()
            production_auth_guard(connection, LOCAL_ONLY_TOKEN)
            connection.execute.assert_not_called()

    def test_known_unique_violations_are_safe_nonretryable_conflicts(self):
        request_object = Request({'type': 'http', 'headers': [], 'state': {'request_id': 'qa-race'}})
        for constraint, code in [('artifacts_pkey', 'immutable_artifact_conflict'),
                                 ('dogs_pkey', 'revision_conflict')]:
            original = SimpleNamespace(sqlstate='23505', diag=SimpleNamespace(constraint_name=constraint))
            error = IntegrityError('PRIVATE SQL', {'secret': 'PRIVATE VALUE'}, original)
            response = asyncio.run(api.constraint_error(request_object, error))
            payload = json.loads(response.body)
            self.assertEqual(response.status_code, 409)
            self.assertEqual(payload['code'], code)
            self.assertEqual(payload['requestId'], 'qa-race')
            self.assertFalse(payload['retryable'])
            self.assertNotIn('PRIVATE', response.body.decode())

    def test_space_guard_preserves_existing_prefix_and_never_opens_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            part = Path(directory) / 'fixture.part'
            part.write_bytes(b'original')
            with patch('server.safety.shutil.disk_usage', return_value=SimpleNamespace(free=1)):
                with self.assertRaises(HTTPException) as caught:
                    append_upload(part, b'next', 8)
            self.assertEqual(caught.exception.status_code, 507)
            self.assertEqual(caught.exception.detail['code'], 'storage_space_low')
            self.assertEqual(caught.exception.headers['Upload-Offset'], '8')
            self.assertEqual(part.read_bytes(), b'original')

    def test_short_writes_are_completed_and_enospc_is_never_acknowledged(self):
        class Writer:
            def __init__(self, fail=False):
                self.data = bytearray(b'prefix'); self.fail = fail
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def write(self, data):
                if self.fail and len(self.data) > 6: raise OSError(errno.ENOSPC, 'private disk path')
                length = min(2, len(data)); self.data.extend(data[:length]); return length
            def flush(self): pass
            def fileno(self): return 123
        for fail in (False, True):
            writer = Writer(fail)
            with patch('server.safety.shutil.disk_usage', return_value=SimpleNamespace(free=2**40)), \
                    patch.object(Path, 'open', return_value=writer), patch('server.safety.os.fsync') as sync:
                if fail:
                    with self.assertRaises(HTTPException) as caught:
                        append_upload(Path('/synthetic/fixture.part'), b'abcdef', 6)
                    self.assertEqual(caught.exception.status_code, 507)
                    self.assertEqual(caught.exception.detail, {'code': 'storage_full', 'uploadOffset': 6})
                    self.assertTrue(writer.data.startswith(b'prefix'))
                    sync.assert_not_called()
                else:
                    append_upload(Path('/synthetic/fixture.part'), b'abcdef', 6)
                    self.assertEqual(writer.data, b'prefixabcdef')
                    sync.assert_called_once_with(123)


class BackendSafetyIntegrationTest(unittest.TestCase):
    def fixture(self, index=0):
        return make_fixture(index, 'qa-' + uuid.uuid4().hex, DEVICE)

    def put(self, fixture):
        try:
            status, _, body = request('PUT', '/v1/recordings/' + fixture['recording_id'], fixture['manifest'])
            return status, json.loads(body)
        except urllib.error.HTTPError as error:
            try: return error.code, json.loads(error.read())
            finally: error.close()

    def assert_absent(self, fixture):
        with engine.connect() as connection:
            self.assertEqual(connection.execute(text('SELECT count(*) FROM recordings WHERE id=:id'),
                {'id': fixture['recording_id']}).scalar_one(), 0)
            self.assertEqual(connection.execute(text('SELECT count(*) FROM dogs WHERE id=:id'),
                {'id': fixture['manifest']['dog']['id']}).scalar_one(), 0)

    def test_global_artifact_collision_rolls_back_loser_without_changes(self):
        first, second = self.fixture(), self.fixture(1)
        self.assertEqual(self.put(first)[0], 200)
        self.assertEqual(self.put(first)[0], 200)
        second['manifest']['artifacts'][0]['id'] = first['manifest']['artifacts'][0]['id']
        status, result = self.put(second)
        self.assertEqual((status, result['code']), (409, 'immutable_artifact_conflict'))
        self.assertFalse(result['retryable'])
        self.assert_absent(second)
        self.assertEqual(self.put(first)[0], 200)

    def gated_race(self, table, identity, fixtures):
        """Hold the first INSERT so both requests enter the absent-row window.

        The trigger affects only this random fixture in the current synthetic
        test DB. It does not require a test hook in the production application.
        """
        self.assertIn(table, ('dogs', 'artifacts'))
        name = 'qa_gate_' + uuid.uuid4().hex
        gate_key = uuid.uuid4().int % (2**62)
        with engine.connect() as gate:
            gate.execute(text('SELECT pg_advisory_lock(:key)'), {'key': gate_key})
            with engine.begin() as connection:
                connection.execute(text(f"""CREATE FUNCTION {name}() RETURNS trigger LANGUAGE plpgsql AS $$
                    BEGIN IF NEW.id='{uuid.UUID(identity)}'::uuid THEN
                        PERFORM pg_advisory_xact_lock({gate_key}); END IF; RETURN NEW; END $$"""))
                connection.execute(text(f'CREATE TRIGGER {name} BEFORE INSERT ON {table} FOR EACH ROW EXECUTE FUNCTION {name}()'))
            try:
                with ThreadPoolExecutor(max_workers=2) as pool:
                    futures = [pool.submit(self.put, fixture) for fixture in fixtures]
                    try:
                        deadline = time.monotonic() + 8
                        while time.monotonic() < deadline:
                            with engine.connect() as connection:
                                waiting = connection.execute(text("""SELECT count(*) FROM pg_locks
                                    WHERE locktype='advisory' AND NOT granted
                                    AND database=(SELECT oid FROM pg_database WHERE datname=current_database())""")).scalar_one()
                            if waiting >= 2: break
                            time.sleep(.02)
                        self.assertGreaterEqual(waiting, 2, 'Both concurrent requests must reach the controlled gate')
                    finally:
                        gate.execute(text('SELECT pg_advisory_unlock(:key)'), {'key': gate_key})
                    results = [future.result(timeout=15) for future in futures]
                return results
            finally:
                gate.execute(text('SELECT pg_advisory_unlock(:key)'), {'key': gate_key})
                with engine.begin() as connection:
                    connection.execute(text(f'DROP TRIGGER IF EXISTS {name} ON {table}'))
                    connection.execute(text(f'DROP FUNCTION IF EXISTS {name}()'))

    def test_same_absent_dog_uuid_concurrency_is_200_409_and_one_recording(self):
        first, second = self.fixture(), self.fixture(1)
        identity = str(uuid.uuid4())
        for fixture in (first, second): fixture['manifest']['dog']['id'] = identity
        results = self.gated_race('dogs', identity, [first, second])
        self.assertEqual(sorted(result[0] for result in results), [200, 409])
        self.assertEqual(next(result[1]['code'] for result in results if result[0] == 409), 'revision_conflict')
        with engine.connect() as connection:
            self.assertEqual(connection.execute(text('SELECT count(*) FROM recordings WHERE dog_id=:id'), {'id': identity}).scalar_one(), 1)

    def test_concurrent_global_artifact_uuid_conflict_is_200_409(self):
        first, second = self.fixture(), self.fixture(1)
        identity = str(uuid.uuid4())
        for fixture in (first, second): fixture['manifest']['artifacts'][0]['id'] = identity
        results = self.gated_race('artifacts', identity, [first, second])
        self.assertEqual(sorted(result[0] for result in results), [200, 409])
        self.assertEqual(next(result[1]['code'] for result in results if result[0] == 409), 'immutable_artifact_conflict')
        self.assert_absent([first, second][next(index for index, result in enumerate(results) if result[0] == 409)])

    def test_bootstrap_preserves_admin_rotated_token_label_and_revocation(self):
        identity = uuid.uuid4()
        old_token = 'synthetic-old-' + uuid.uuid4().hex
        new_hash = hashlib.sha256(('synthetic-new-' + uuid.uuid4().hex).encode()).hexdigest()
        with engine.begin() as connection:
            connection.execute(text("INSERT INTO client_devices(id,label,token_hash) VALUES(:id,'Provisioned label',:hash)"),
                               {'id': identity, 'hash': new_hash})
        try:
            with patch.object(api, 'DEVICE_ID', identity), patch.object(api, 'DEBUG_TOKEN', old_token):
                api.ensure_device()
                with engine.begin() as connection:
                    row = connection.execute(text('SELECT label,token_hash,revoked_at FROM client_devices WHERE id=:id'), {'id': identity}).one()
                    self.assertEqual((row.label, row.token_hash, row.revoked_at), ('Provisioned label', new_hash, None))
                    connection.execute(text('UPDATE client_devices SET revoked_at=now() WHERE id=:id'), {'id': identity})
                api.ensure_device()
                with engine.connect() as connection:
                    row = connection.execute(text('SELECT token_hash,revoked_at FROM client_devices WHERE id=:id'), {'id': identity}).one()
                    self.assertEqual(row.token_hash, new_hash)
                    self.assertIsNotNone(row.revoked_at)
        finally:
            with engine.begin() as connection: connection.execute(text('DELETE FROM client_devices WHERE id=:id'), {'id': identity})

    def test_disk_fault_does_not_advance_offset_and_real_http_resume_verifies_bytes(self):
        fixture = self.fixture(); self.assertEqual(self.put(fixture)[0], 200)
        artifact = fixture['manifest']['artifacts'][0]
        identity = uuid.UUID(artifact['id']); body = fixture['contents'][artifact['type']]
        part = api.incoming_path(identity)

        async def invoke():
            async def receive(): return {'type': 'http.request', 'body': body, 'more_body': False}
            native_request = Request({'type': 'http', 'headers': [(b'content-length', str(len(body)).encode())]}, receive)
            return await api.patch_artifact(identity, native_request, uuid.UUID(DEVICE), 0)

        with patch('server.safety.shutil.disk_usage', return_value=SimpleNamespace(free=0)):
            with self.assertRaises(HTTPException) as caught: asyncio.run(invoke())
        self.assertEqual(caught.exception.status_code, 507)
        self.assertFalse(part.exists())

        real_open = Path.open
        class DiskFullWriter:
            def __init__(self, output): self.output = output; self.wrote = False
            def __enter__(self): self.output.__enter__(); return self
            def __exit__(self, *args): return self.output.__exit__(*args)
            def write(self, data):
                if self.wrote: raise OSError(errno.ENOSPC, 'synthetic disk fault')
                self.wrote = True; return self.output.write(data[:2])
        def fail_writer(path, *args, **kwargs):
            output = real_open(path, *args, **kwargs)
            return DiskFullWriter(output) if path == part and args and args[0] == 'ab' else output
        with patch.object(Path, 'open', new=fail_writer):
            with self.assertRaises(HTTPException) as caught: asyncio.run(invoke())
        self.assertEqual(caught.exception.detail['code'], 'storage_full')
        self.assertEqual(part.read_bytes(), body[:2])
        with engine.connect() as connection:
            self.assertEqual(connection.execute(text('SELECT stored_size_bytes FROM artifacts WHERE id=:id'), {'id': identity}).scalar_one(), 0)
            self.assertIsNone(connection.execute(text('SELECT receipt_sha256 FROM recordings WHERE id=:id'), {'id': fixture['recording_id']}).scalar_one())
        self.assertEqual(request('HEAD', '/v1/artifacts/' + str(identity) + '/content')[1]['upload-offset'], '0')
        self.assertEqual(patch_bytes(str(identity), 0, body)[0], 204)
        self.assertEqual(request('POST', '/v1/artifacts/' + str(identity) + '/complete', {})[0], 200)
        downloaded = request('GET', '/v1/artifacts/' + str(identity) + '/content')[2]
        self.assertEqual(downloaded, body)
        self.assertEqual(hashlib.sha256(downloaded).hexdigest(), artifact['sha256'])

    def test_retired_metadata_and_parent_guards_with_coexisting_rows(self):
        fixture = self.fixture(); self.assertEqual(self.put(fixture)[0], 200)
        recording = fixture['recording_id']; dog = fixture['manifest']['dog']['id']
        profile = fixture['manifest']['dogProfileVersion']['id']
        artifact = fixture['manifest']['artifacts'][0]['id']
        def marker(kind, identity, add):
            with engine.begin() as connection:
                digest = hashlib.sha256(identity.encode()).hexdigest()
                if add: connection.execute(text('INSERT INTO retired_entities(kind,id_sha256) VALUES(:kind,:hash)'), {'kind': kind, 'hash': digest})
                else: connection.execute(text('DELETE FROM retired_entities WHERE kind=:kind AND id_sha256=:hash'), {'kind': kind, 'hash': digest})
        for kind, identity in [('artifact', artifact), ('profile', profile), ('recording', recording), ('dog', dog)]:
            marker(kind, identity, True)
            try:
                if kind == 'artifact':
                    detail = json.loads(request('GET', '/v1/recordings/' + recording)[2])
                    self.assertNotIn(artifact, [item['id'] for item in detail['artifacts']])
                else:
                    expect_http(410, 'GET', '/v1/recordings/' + recording)
                    expect_http(410, 'GET', '/v1/recordings/' + recording + '/sync-status')
                expect_http(410, 'GET', '/v1/artifacts/' + artifact + '/content')
                if kind in ('dog', 'profile'):
                    listed = json.loads(request('GET', '/v1/dogs?limit=200')[2])['items']
                    self.assertNotIn(dog, [item['id'] for item in listed])
                    expect_http(410, 'GET', '/v1/dogs/' + dog)
                if kind in ('recording', 'profile'):
                    listed = json.loads(request('GET', '/v1/dogs/' + dog + '/recordings')[2])['items']
                    self.assertNotIn(recording, [item['id'] for item in listed])
            finally: marker(kind, identity, False)
        self.assertEqual(request('GET', '/v1/recordings/' + recording)[0], 200)

        # A retired historical version is omitted even while its current dog
        # remains active; captures referencing it must not silently reappear.
        next_profile = fixture['profile']
        next_profile['dog']['expectedRevision'] = 1
        next_profile['profileVersion']['id'] = str(uuid.uuid4())
        next_profile['profileVersion']['questionnaire']['notes'] = 'Reviewed next version'
        request('PUT', '/v1/dogs/' + dog + '/profile-versions/' + next_profile['profileVersion']['id'], next_profile)
        marker('profile', profile, True)
        try:
            detail = json.loads(request('GET', '/v1/dogs/' + dog)[2])
            self.assertEqual(detail['profileVersion']['id'], next_profile['profileVersion']['id'])
            self.assertNotIn(profile, [item['id'] for item in detail['profileVersions']])
            expect_http(410, 'GET', '/v1/recordings/' + recording)
        finally: marker('profile', profile, False)

    def test_integrity_explicitly_reports_selected_scope_and_counts(self):
        for headers, scope in [({}, {'accountId': None, 'unassignedOnly': True, 'includesAllAccounts': False}),
                               ({'X-Woona-Account': 'qa-empty-' + uuid.uuid4().hex}, None)]:
            response = json.loads(request('GET', '/v1/integrity?mode=metadata', headers=headers)[2])
            expected = scope or {'accountId': headers['X-Woona-Account'], 'unassignedOnly': False, 'includesAllAccounts': False}
            self.assertEqual(response['checkedScope'], expected)
            self.assertGreaterEqual(response['checkedArtifacts'], response['hashedArtifacts'])
            self.assertGreaterEqual(response['hashedBytes'], 0)
            if headers: self.assertEqual(response['checkedArtifacts'], 0)
