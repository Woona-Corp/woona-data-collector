from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import MagicMock, patch
import unittest
from fastapi import FastAPI, HTTPException
import asyncio
import json
from starlette.exceptions import HTTPException as StarletteHTTPException
from server.app import app as application, ready, request_id_middleware, http_error, unexpected_error
from server.errors import ERRORS, error_guidance


class AsgiClient:
    """Exercise the actual middleware stack using only runtime/stdlib dependencies."""
    def __init__(self, app):
        self.app = app

    def get(self, path, headers=None):
        return self.request('GET', path, headers=headers)

    def request(self, method, path, payload=None, headers=None):
        async def dispatch():
            sent = []
            request_sent = False
            async def receive():
                nonlocal request_sent
                if not request_sent:
                    request_sent = True
                    return {'type': 'http.request', 'body': json.dumps(payload).encode() if payload is not None else b'', 'more_body': False}
                await asyncio.Event().wait()
            async def send(message):
                sent.append(message)
            scope = {'type': 'http', 'asgi': {'version': '3.0'}, 'http_version': '1.1',
                'method': method, 'scheme': 'http', 'path': path, 'raw_path': path.encode(),
                'query_string': b'', 'root_path': '', 'server': ('testserver', 80),
                'client': ('127.0.0.1', 1234),
                'headers': [(key.lower().encode(), value.encode()) for key, value in (headers or {}).items()]}
            try:
                await self.app(scope, receive, send)
            except RuntimeError:
                # ServerErrorMiddleware rethrows after emitting its safe 500 response.
                if not any(message['type'] == 'http.response.start' and message['status'] == 500 for message in sent):
                    raise
            start = next(message for message in sent if message['type'] == 'http.response.start')
            body = b''.join(message.get('body', b'') for message in sent if message['type'] == 'http.response.body')
            class Response:
                status_code = start['status']
                headers = {key.decode().lower(): value.decode() for key, value in start['headers']}
                text = body.decode()
                def json(self):
                    return json.loads(body)
            return Response()
        return asyncio.run(dispatch())


class ErrorStatusTest(unittest.TestCase):
    def client(self):
        app = FastAPI()
        app.middleware('http')(request_id_middleware)
        app.add_exception_handler(StarletteHTTPException, http_error)
        app.add_exception_handler(Exception, unexpected_error)
        @app.get('/failure')
        def failure():
            raise RuntimeError('sensitive-connection-password-must-not-appear')
        @app.get('/auth')
        def auth():
            raise HTTPException(401, detail={'code': 'invalid_bearer_token'})
        @app.get('/conflict')
        def conflict():
            raise HTTPException(409, detail={'code': 'animal_id_already_exists', 'existingDogId': 'test-id'})
        return AsgiClient(app)

    def test_unexpected_failure_is_json_with_request_id_without_private_exception(self):
        response = self.client().get('/failure', headers={'X-Request-ID': 'field-request-123'})
        self.assertEqual(response.status_code, 500)
        self.assertEqual(response.headers['x-request-id'], 'field-request-123')
        result = response.json()
        self.assertEqual(result['requestId'], 'field-request-123')
        self.assertTrue(result['retryable'])
        self.assertEqual(result['nextAction'], 'retry_later')
        self.assertNotIn('sensitive-connection', response.text)

    def test_auth_and_identity_conflicts_have_different_recovery(self):
        client = self.client()
        auth = client.get('/auth').json()
        self.assertFalse(auth['retryable'])
        self.assertEqual(auth['nextAction'], 'update_server_token')
        conflict = client.get('/conflict').json()
        self.assertFalse(conflict['retryable'])
        self.assertEqual(conflict['nextAction'], 'resolve_animal_identity')
        self.assertEqual(conflict['existingDogId'], 'test-id')
        self.assertIn('historical identity', conflict['message'])
        self.assertIn('does not rewrite an existing recording', conflict['message'])

    def test_route_not_found_is_structured_and_bad_correlation_id_is_replaced(self):
        response = self.client().get('/absent', headers={'X-Request-ID': 'a' * 1000})
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.json()['nextAction'], 'check_account_and_restore')
        self.assertLess(len(response.headers['x-request-id']), 129)
        self.assertEqual(response.headers['x-request-id'], response.json()['requestId'])

    def test_every_catalog_code_explains_a_recovery_action(self):
        for code in ERRORS:
            with self.subTest(code=code):
                value = error_guidance(code, 409)
                self.assertGreater(len(value['message']), 30)
                self.assertTrue(value['nextAction'])
        self.assertTrue(error_guidance('database_unavailable', 503)['retryable'])
        self.assertFalse(error_guidance('resource_not_found', 404)['retryable'])

    def assert_readiness_failure(self, response, code, request_id, private_path, private_text):
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.headers['x-request-id'], request_id)
        result = response.json()
        self.assertEqual(result['requestId'], request_id)
        self.assertEqual(result['code'], code)
        self.assertNotIn(private_path, response.text)
        self.assertNotIn(private_text, response.text)

    def test_database_connect_failure_is_safe_and_skips_storage_probe(self):
        private_path = '/private/woona/postgresql.conf'
        private_text = 'sensitive database credentials'
        engine = MagicMock()
        engine.connect.side_effect = RuntimeError(f'{private_path}: {private_text}')
        with patch('server.app.engine', engine), patch('server.app.tempfile.NamedTemporaryFile') as storage_probe:
            response = AsgiClient(application).get('/health/ready', headers={'X-Request-ID': 'ready-db-connect'})
        storage_probe.assert_not_called()
        self.assert_readiness_failure(response, 'database_unavailable', 'ready-db-connect', private_path, private_text)

    def test_database_select_failure_is_safe_and_skips_storage_probe(self):
        private_path = '/private/woona/query.sql'
        private_text = 'sensitive SELECT failure'
        engine = MagicMock()
        engine.connect.return_value.__enter__.return_value.execute.side_effect = RuntimeError(f'{private_path}: {private_text}')
        with patch('server.app.engine', engine), patch('server.app.tempfile.NamedTemporaryFile') as storage_probe:
            response = AsgiClient(application).get('/health/ready', headers={'X-Request-ID': 'ready-db-select'})
        storage_probe.assert_not_called()
        self.assert_readiness_failure(response, 'database_unavailable', 'ready-db-select', private_path, private_text)

    def test_storage_temporary_file_create_failure_is_safe(self):
        private_path = '/private/woona/storage'
        private_text = 'sensitive temp create failure'
        with patch('server.app.engine', MagicMock()), patch('server.app.tempfile.NamedTemporaryFile',
                side_effect=OSError(f'{private_path}: {private_text}')):
            response = AsgiClient(application).get('/health/ready', headers={'X-Request-ID': 'ready-storage-create'})
        self.assert_readiness_failure(response, 'storage_unavailable', 'ready-storage-create', private_path, private_text)

    def test_storage_temporary_file_write_and_read_failures_are_safe(self):
        for operation in ('write', 'read'):
            with self.subTest(operation=operation):
                private_path = f'/private/woona/{operation}.tmp'
                private_text = f'sensitive temp {operation} failure'
                probe_file = MagicMock()
                getattr(probe_file, operation).side_effect = OSError(f'{private_path}: {private_text}')
                storage_probe = MagicMock()
                storage_probe.return_value.__enter__.return_value = probe_file
                request_id = f'ready-storage-{operation}'
                with patch('server.app.engine', MagicMock()), patch('server.app.tempfile.NamedTemporaryFile', storage_probe):
                    response = AsgiClient(application).get('/health/ready', headers={'X-Request-ID': request_id})
                self.assert_readiness_failure(response, 'storage_unavailable', request_id, private_path, private_text)

    def test_concurrent_readiness_probes_use_independent_files(self):
        with TemporaryDirectory() as directory, patch('server.app.STORAGE_ROOT', Path(directory)), patch('server.app.engine', MagicMock()):
            with ThreadPoolExecutor(max_workers=12) as pool:
                results = list(pool.map(lambda _: ready(), range(100)))
            self.assertTrue(all(result == {'status': 'ready'} for result in results))
            self.assertEqual(list(Path(directory).iterdir()), [])
