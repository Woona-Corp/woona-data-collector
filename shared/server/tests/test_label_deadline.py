"""Real loopback LS reads: caller deadline, bounded ownership and raw budgets."""
import json
import os
import socket
import threading
import time
import unittest
from contextlib import contextmanager
from unittest.mock import patch

from server import label_sync


@contextmanager
def loopback(reply, requests=1):
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    listener.settimeout(3)
    errors = []

    def serve():
        try:
            for _ in range(requests):
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(3)
                    conn.recv(4096)
                    reply(conn)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The deadline/body cap may close a response early.
        except Exception as error:
            errors.append(error)
        finally:
            listener.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    with patch.dict(os.environ, LABEL_STUDIO_URL=f'http://127.0.0.1:{listener.getsockname()[1]}',
                    LABEL_STUDIO_HOST_HEADER='synthetic.local', LABEL_STUDIO_API_TOKEN='synthetic-offline'):
        try:
            yield
        finally:
            thread.join(4)
            assert not thread.is_alive(), 'Synthetic server failed to stop'
            assert not errors, errors
            # Wait for the network worker to finish closing its response.
            gate = getattr(label_sync, '_deadline_request_gate', None)
            if gate is not None:
                assert gate.acquire(timeout=2), 'Network worker did not release capacity'
                gate.release()


def response(conn, body):
    conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: ' + str(len(body)).encode() +
                 b'\r\nConnection: close\r\n\r\n' + body)


class LabelDeadlineTest(unittest.TestCase):
    def test_trickled_headers_return_by_deadline_and_hold_single_worker_until_io_finishes(self):
        def reply(conn):
            conn.sendall(b'HTTP/1.1 200 OK\r\nX-Synthetic: ')
            for _ in range(12):
                time.sleep(.1)
                conn.sendall(b'a')
            conn.sendall(b'\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}')

        with loopback(reply), patch.object(label_sync, 'urlopen', wraps=label_sync.urlopen) as opened:
            start = time.monotonic()
            with self.assertRaises(RuntimeError):
                label_sync.request_json('GET', '/synthetic', timeout=.3, deadline=start + .5)
            elapsed = time.monotonic() - start
            print(f'trickled headers: budget=.5 elapsed={elapsed:.3f}s', flush=True)
            self.assertLess(elapsed, .7)
            self.assertEqual(opened.call_count, 1)
            for _ in range(8):
                start = time.monotonic()
                with self.assertRaisesRegex(RuntimeError, 'in progress'):
                    label_sync.request_json('GET', '/synthetic', deadline=start + .5)
                self.assertLess(time.monotonic() - start, .1)
            self.assertEqual(opened.call_count, 1, 'Timed-out I/O must retain sole capacity')
            workers = [t for t in threading.enumerate() if t.name == 'label-studio-deadline']
            self.assertEqual(len(workers), 1)
            self.assertTrue(workers[0].daemon)
        with loopback(lambda conn: response(conn, b'{}')):
            self.assertEqual(label_sync.request_json('GET', '/', deadline=time.monotonic() + 1), {})

    def test_stalled_body_and_dns_do_not_extend_caller_wait(self):
        def reply(conn):
            conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{')
            time.sleep(.5)
            conn.sendall(b'}')
        with loopback(reply):
            start = time.monotonic()
            with self.assertRaises(RuntimeError):
                label_sync.request_json('GET', '/', timeout=1, deadline=start + .15)
            self.assertLess(time.monotonic() - start, .35)
        original = socket.getaddrinfo
        def delayed_dns(*args, **kwargs):
            time.sleep(.5)
            return original(*args, **kwargs)
        with loopback(lambda conn: response(conn, b'{}')), patch('socket.getaddrinfo', side_effect=delayed_dns):
            start = time.monotonic()
            with self.assertRaises(RuntimeError):
                label_sync.request_json('GET', '/', timeout=1, deadline=start + .15)
            self.assertLess(time.monotonic() - start, .35)

    def test_expired_and_mutating_optional_deadlines_start_no_io(self):
        with patch.object(label_sync, 'urlopen') as opened:
            with self.assertRaisesRegex(RuntimeError, 'deadline'):
                label_sync.request_json('GET', '/', deadline=time.monotonic() - 1)
            with self.assertRaisesRegex(ValueError, 'GET'):
                label_sync.request_json('POST', '/', {}, deadline=time.monotonic() + 1)
            opened.assert_not_called()

    def test_normal_malformed_and_byte_cap(self):
        # Default sync/import mutation callers retain their synchronous API.
        with loopback(lambda conn: response(conn, b'{"created":true}')):
            self.assertEqual(label_sync.request_json('POST', '/', {'task': 1}), {'created': True})
        for body, expected in ((b'{"ok":true}', {'ok': True}), (b'', None)):
            for deadline in (None, time.monotonic() + 3):
                with loopback(lambda conn: response(conn, body)):
                    self.assertEqual(label_sync.request_json('GET', '/', maximum_bytes=32, deadline=deadline), expected)
        with loopback(lambda conn: response(conn, b'{broken')):
            with self.assertRaises(json.JSONDecodeError):
                label_sync.request_json('GET', '/', deadline=time.monotonic() + 1)
        with loopback(lambda conn: response(conn, b'{}' + b' ' * 100)):
            with self.assertRaisesRegex(RuntimeError, 'budget'):
                label_sync.request_json('GET', '/', maximum_bytes=32, deadline=time.monotonic() + 1)

    def test_raw_bytes_charged_before_parse_including_malformed(self):
        for body in (b'{}' + b' ' * 100, b'{bad' + b' ' * 100):
            charged = []
            with loopback(lambda conn: response(conn, body)):
                try:
                    label_sync.request_json('GET', '/', maximum_bytes=512, deadline=time.monotonic() + 1,
                                            consume_bytes=charged.append)
                except json.JSONDecodeError:
                    pass
            self.assertEqual(sum(charged), len(body))

    def test_dashboard_aggregate_counts_padded_raw_bytes(self):
        from server import dashboard
        # Actual project discovery, list page and detail all use the shared raw
        # budget. Each response alone fits 512; their compact JSON sum fits too.
        # Only their cumulative padded raw size exhausts it, on the detail read.
        bodies = [json.dumps(value).encode() + b' ' * 80 for value in (
            {'id': 21, 'title': 'Synthetic', 'label_config':
             '<View><Video name="video" value="$video"/><TimelineLabels name="labels" toName="video"/></View>'},
            {'tasks': [{'id': 1, 'data': {'source_id': 'synthetic'}, 'is_labeled': True}], 'total': 1},
            {'id': 1, 'annotations': []},
        )]
        self.assertTrue(all(len(body) < 512 for body in bodies))
        self.assertGreater(sum(map(len, bodies)), 512)
        self.assertLess(sum(len(body.rstrip()) for body in bodies), 512)
        replies = iter(bodies)
        dashboard.clear_label_summary_cache()
        with loopback(lambda conn: response(conn, next(replies)), requests=3), \
             patch.object(dashboard, 'LABEL_RESPONSE_LIMIT', 4096), \
             patch.object(dashboard, 'LABEL_REFRESH_BYTES', 512):
            with self.assertRaisesRegex(RuntimeError, 'budget'):
                dashboard.load_label_summary()
        self.assertIsNone(dashboard._label_summary_cache)


if __name__ == '__main__':
    unittest.main()
