"""Hermetic audit regressions: never contact a database or recording store."""
import asyncio
from contextlib import contextmanager
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from starlette.requests import Request
from starlette.responses import Response
from server import app as api, dashboard


def chunk_request(reads, body=b'X'):
    async def receive():
        reads.append(1)
        return {'type': 'http.request', 'body': body, 'more_body': False}
    return Request({'type': 'http', 'headers': [(b'content-length', b'1'),
        (b'upload-offset', b'0')]}, receive)


class DashboardOffloadTest(unittest.TestCase):
    def exercise(self, post):
        loop_thread = threading.get_ident()
        calls, stalled = [], []
        entered, healthy = threading.Event(), threading.Event()
        identity, owner = uuid.uuid4(), uuid.uuid4()
        def blocked(*args, **kwargs):
            calls.append(threading.get_ident())
            entered.set()
            if not healthy.wait(1):
                stalled.append(True)
            return owner
        @contextmanager
        def connect():
            blocked()
            yield SimpleNamespace(execute=lambda *a, **k: SimpleNamespace(scalar_one_or_none=lambda: owner))
        async def exercise():
            async def fake_patch(*args):
                return Response(status_code=204)
            with patch.object(api, 'patch_artifact', side_effect=fake_patch):
                if post:
                    task = asyncio.create_task(dashboard.dashboard_add_reference(identity, chunk_request([])))
                else:
                    task = asyncio.create_task(dashboard.dashboard_reference_chunk(identity, chunk_request([])))
                while not entered.is_set():
                    await asyncio.sleep(.001)
                self.assertEqual(api.live(), {'status': 'ok'})
                healthy.set()
                await task
        with patch.object(api.engine, 'connect', side_effect=connect), \
             patch.object(dashboard, 'reference_owner', side_effect=blocked), \
             patch.object(api.ArtifactPayload, 'model_validate_json', return_value=object()), \
             patch.object(api, 'add_reference', side_effect=blocked):
            asyncio.run(exercise())
        self.assertFalse(stalled, 'Dashboard synchronous DB work blocked concurrent health progress')
        self.assertTrue(calls)
        self.assertTrue(all(t != loop_thread for t in calls), 'Whole DB lookup/persistence must be off-loop')

    def test_post_offloads_lookup_and_add_reference(self):
        self.exercise(True)

    def test_patch_offloads_owner_lookup(self):
        self.exercise(False)


class UploadAdmissionTest(unittest.TestCase):
    def test_excess_upload_does_not_read_body_and_body_cancellation_releases_slot(self):
        async def exercise():
            entered = [asyncio.Event() for _ in range(4)]
            reads = []
            async def waiting_receive(n):
                reads.append(n)
                entered[n].set()
                await asyncio.Event().wait()
                return {'type': 'http.disconnect'}
            tasks = []
            for n in range(4):
                request = Request({'type': 'http', 'headers': [(b'content-length', b'1')]},
                    lambda n=n: waiting_receive(n))
                tasks.append(asyncio.create_task(api.patch_artifact(uuid.uuid4(), request, uuid.uuid4(), 0)))
            try:
                await asyncio.wait_for(asyncio.gather(*(e.wait() for e in entered)), 2)
                rejected_reads = []
                # Without admission the original code reads and persists this fifth body.
                with self.assertRaises(api.HTTPException) as caught:
                    await api.patch_artifact(uuid.uuid4(), chunk_request(rejected_reads), uuid.uuid4(), 0)
                self.assertEqual(caught.exception.status_code, 503)
                self.assertEqual((caught.exception.headers or {})['Retry-After'], '1')
                self.assertEqual(rejected_reads, [], 'Busy upload consumed body before admission')
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
            result = await api.patch_artifact(uuid.uuid4(), chunk_request([]), uuid.uuid4(), 0)
            self.assertEqual(result.status_code, 204)
        with patch.object(api, 'persist_artifact_chunk', return_value=Response(status_code=204)):
            asyncio.run(exercise())

    def test_cancelled_persistence_keeps_slot_until_worker_finishes(self):
        entered, release = threading.Event(), threading.Event()
        def persist(*args):
            entered.set()
            release.wait(3)
            return Response(status_code=204)
        async def exercise():
            tasks = [asyncio.create_task(api.patch_artifact(uuid.uuid4(), chunk_request([]), uuid.uuid4(), 0))
                     for _ in range(4)]
            try:
                while not entered.is_set():
                    await asyncio.sleep(.001)
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                with self.assertRaises(api.HTTPException):
                    await api.patch_artifact(uuid.uuid4(), chunk_request([]), uuid.uuid4(), 0)
            finally:
                release.set()
                await asyncio.gather(*tasks, return_exceptions=True)
                await asyncio.sleep(.05)
            self.assertEqual((await api.patch_artifact(uuid.uuid4(), chunk_request([]), uuid.uuid4(), 0)).status_code, 204)
        with patch.object(api, 'persist_artifact_chunk', side_effect=persist):
            asyncio.run(exercise())
