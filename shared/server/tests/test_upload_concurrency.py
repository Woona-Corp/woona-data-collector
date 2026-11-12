"""Hermetic HTTP regressions: persistence cannot block the ASGI event loop."""
import asyncio
from contextlib import contextmanager
import gc
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid
import weakref

import httpx

from server import app as api


class UploadConcurrencyTest(unittest.TestCase):
    def test_blocked_write_leaves_http_health_responsive_and_ack_follows_commit(self):
        identity, device = uuid.uuid4(), uuid.uuid4()
        event_loop_thread = threading.get_ident()
        entered, healthy = threading.Event(), threading.Event()
        calls, stalled = [], []
        row = {'capture_device_id': device, 'storage_status': 'pending',
               'stored_size_bytes': 0, 'expected_size_bytes': 1}
        original_append = api.append_upload

        @contextmanager
        def transaction():
            calls.append(('begin', threading.get_ident()))
            yield SimpleNamespace(execute=lambda *args: calls.append(('update', threading.get_ident())))
            calls.append(('commit', threading.get_ident()))

        def blocked_append(part, body, offset):
            calls.append(('write', threading.get_ident()))
            entered.set()
            # Old code blocks this same event loop until this bounded wait ends.
            # No watchdog thread may fake health progress for the application.
            if not healthy.wait(timeout=2):
                stalled.append(True)
            original_append(part, body, offset)

        async def exercise():
            transport = httpx.ASGITransport(app=api.app)
            async with httpx.AsyncClient(transport=transport, base_url='http://isolated.test') as client:
                upload = asyncio.create_task(client.patch(
                    f'/v1/artifacts/{identity}/content', content=b'X', headers={'Upload-Offset': '0'}))
                try:
                    async def wait_for_write():
                        while not entered.is_set():
                            await asyncio.sleep(0.001)
                    await asyncio.wait_for(wait_for_write(), timeout=4)
                    response = await asyncio.wait_for(client.get('/health/live'), timeout=1)
                    self.assertEqual(response.status_code, 200)
                    healthy.set()
                    result = await asyncio.wait_for(upload, timeout=4)
                    self.assertEqual(result.status_code, 204)
                    self.assertEqual(result.headers['upload-offset'], '1')
                    self.assertEqual([name for name, _ in calls], ['begin', 'write', 'update', 'commit'])
                finally:
                    healthy.set()
                    await asyncio.gather(upload, return_exceptions=True)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(api, 'STORAGE_ROOT', Path(directory)), \
                patch.object(api.engine, 'begin', side_effect=transaction), \
                patch.object(api, 'artifact_row', return_value=row), \
                patch.object(api, 'append_upload', side_effect=blocked_append), \
                patch.dict(api.app.dependency_overrides, {api.authenticated_device: lambda: device}), \
                patch.dict('os.environ', {'WOONA_UPLOAD_FREE_SPACE_RESERVE_BYTES': '0'}):
            asyncio.run(exercise())
            self.assertEqual(api.incoming_path(identity).read_bytes(), b'X')
        self.assertFalse(stalled, 'Blocked persistence stalled the concurrent HTTP health request')
        self.assertTrue(all(thread != event_loop_thread for _, thread in calls),
                        'Lock/transaction/write/commit must all execute off the event loop')

    def test_idle_artifact_locks_do_not_accumulate(self):
        identities = [uuid.uuid4() for _ in range(100)]
        for identity in identities:
            with api.artifact_lock(identity):
                self.assertIs(api.artifact_lock(identity), api.artifact_lock(identity))
        gc.collect()
        self.assertFalse(any(identity in api.artifact_locks for identity in identities),
                         'Idle artifact locks are retained indefinitely')

    def test_waiter_retains_the_same_lock_until_it_finishes(self):
        identity = uuid.uuid4()
        lock = api.artifact_lock(identity)
        reference = weakref.ref(lock)
        lock.acquire()
        ready, acquired = threading.Event(), threading.Event()
        same_lock = []
        def wait():
            waiting = api.artifact_lock(identity)
            same_lock.append(waiting is reference())
            ready.set()
            with waiting:
                acquired.set()
        worker = threading.Thread(target=wait, daemon=True)
        worker.start()
        try:
            self.assertTrue(ready.wait(timeout=2))
            del lock
            gc.collect()
            self.assertIsNotNone(reference())
            self.assertIs(api.artifact_lock(identity), reference())
            self.assertFalse(acquired.is_set())
        finally:
            held = reference()
            if held is not None and held.locked():
                held.release()
            del held
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(same_lock, [True])
        self.assertTrue(acquired.is_set())
        gc.collect()
        self.assertIsNone(reference(), 'Completed waiter left an idle lock cached')

    def test_content_length_errors_never_start_persistence(self):
        async def exercise():
            for headers, content, expected in [({}, None, 411),
                    ({'Content-Length': '0'}, b'', 413),
                    ({'Content-Length': str(api.MAX_CHUNK_BYTES + 1)}, b'', 413),
                    ({'Content-Length': '2'}, b'X', 400)]:
                with self.subTest(expected=expected):
                    sent = False
                    async def receive(content=content):
                        nonlocal sent
                        if sent:
                            return {'type': 'http.disconnect'}
                        sent = True
                        return {'type': 'http.request', 'body': content or b'', 'more_body': False}
                    request = api.Request({'type': 'http', 'headers':
                        [(key.lower().encode(), value.encode()) for key, value in headers.items()]}, receive)
                    with self.assertRaises(api.HTTPException) as caught:
                        await api.patch_artifact(uuid.uuid4(), request, uuid.uuid4(), 0)
                    self.assertEqual(caught.exception.status_code, expected)
        with patch.object(api.engine, 'begin') as begin:
            asyncio.run(exercise())
        begin.assert_not_called()


class ObservabilityTest(unittest.TestCase):
    def test_client_cancellation_logs_sanitized_abort_and_propagates(self):
        path = f'/v1/artifacts/{uuid.uuid4()}/content'
        request = api.Request({
            'type': 'http', 'scheme': 'http', 'server': ('isolated.test', 80),
            'method': 'PATCH', 'path': path, 'query_string': b'token=query-secret',
            'headers': [(b'x-request-id', b'cancel-test'),
                        (b'authorization', b'Bearer header-secret'),
                        (b'cookie', b'session=cookie-secret')],
        })

        async def cancelled(_):
            raise asyncio.CancelledError

        async def exercise():
            with self.assertRaises(asyncio.CancelledError):
                await api.request_id_middleware(request, cancelled)

        with patch.object(api, 'log_event') as event:
            asyncio.run(exercise())
        event.assert_called_once()
        self.assertEqual(event.call_args.args, ('request_aborted',))
        self.assertEqual(set(event.call_args.kwargs), {
            'requestId', 'method', 'path', 'durationMs',
        })
        self.assertEqual(event.call_args.kwargs['requestId'], 'cancel-test')
        self.assertEqual(event.call_args.kwargs['method'], 'PATCH')
        self.assertEqual(event.call_args.kwargs['path'], path)
        self.assertIsInstance(event.call_args.kwargs['durationMs'], float)
        self.assertGreaterEqual(event.call_args.kwargs['durationMs'], 0)

    def test_durable_chunk_commit_is_info_and_contains_no_payload(self):
        identity, device = uuid.uuid4(), uuid.uuid4()
        row = {'capture_device_id': device, 'storage_status': 'uploading',
               'stored_size_bytes': 0, 'expected_size_bytes': 6}

        @contextmanager
        def transaction():
            yield SimpleNamespace(execute=lambda *args, **kwargs: None)

        with tempfile.TemporaryDirectory() as directory, \
                patch.object(api, 'STORAGE_ROOT', Path(directory)), \
                patch.object(api.engine, 'begin', side_effect=transaction), \
                patch.object(api, 'artifact_row', return_value=row), \
                patch.object(api, 'log_event') as event:
            response = api.persist_artifact_chunk_locked(
                identity, device, 0, bytearray(b'SECRET'), 'chunk-request')
        self.assertEqual(response.headers['Upload-Offset'], '6')
        event.assert_called_once()
        self.assertEqual(event.call_args.args, ('chunk_committed',))
        self.assertEqual(event.call_args.kwargs.pop('level'), api.logging.INFO)
        self.assertEqual(event.call_args.kwargs, {
            'requestId': 'chunk-request', 'artifactId': str(identity),
            'uploadOffset': 6, 'bytes': 6,
        })

    def test_caddy_access_log_uses_normalized_response_id_and_excludes_unsafe_request_data(self):
        config = Path(api.__file__).with_name('Caddyfile').read_text(encoding='utf-8')
        for expected in (
            'log {', 'format filter {', 'wrap json',
            'request>headers delete', 'resp_headers delete',
            r'request>uri regexp \?.*$ ""',
            'log_append requestId {http.response.header.X-Request-ID}',
        ):
            self.assertIn(expected, config)
        for forbidden in (
            'log_append authorization', 'log_append cookie',
            '{http.request.header.Authorization}', '{http.request.header.Cookie}',
            '{http.request.header.X-Request-ID}',
        ):
            self.assertNotIn(forbidden, config, 'Malformed request IDs must not be logged')
