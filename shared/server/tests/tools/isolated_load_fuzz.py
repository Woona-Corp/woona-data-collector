#!/usr/bin/env python3
"""Bounded synthetic API load/fuzz test. Refuses every target except its isolated stack.

Run on the Docker host, after other E2E scenarios finish. No third-party Python
packages, production URL/token, redirect following, disk-fill or external traffic.
The synthetic account is retained for investigation until the isolated stack is
removed by its owner. This script never tears down containers or deletes data.
"""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import copy
from datetime import datetime, timezone, timedelta
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid

PROJECT = 'woona-incident-e2e-20261026'
ISOLATED_ROOT = Path('/opt/woona-incident-e2e-20261026')
MAX_READS = 1000
MAX_FIXTURES = 50
MAX_BINARY_BYTES = 100 * 1024 * 1024
MAX_JSON = 2 * 1024 * 1024


class SafetyError(RuntimeError):
    pass


def validate_target(base, project, enabled):
    target = urlsplit(base)
    if enabled != '1' or project != PROJECT:
        raise SafetyError('Explicit isolated test opt-in and exact Compose project are required')
    if (target.scheme != 'http' or target.hostname != '127.0.0.1' or target.port != 18088
            or target.username or target.password or target.query or target.fragment
            or target.path not in ('', '/')):
        raise SafetyError('Only http://127.0.0.1:18088 is permitted')
    return target


def inspect_guard(base, project, token):
    validate_target(base, project, os.environ.get('WOONA_ISOLATED_LOAD_TEST'))
    if not token:
        raise SafetyError('A separately supplied synthetic token is required')
    ids = subprocess.check_output(['docker', 'ps', '-q', '--filter',
        'label=com.docker.compose.project=' + project], text=True).split()
    if len(ids) != 2:
        raise SafetyError('Expected exactly the isolated API and PostgreSQL containers')
    containers = json.loads(subprocess.check_output(['docker', 'inspect', *ids], text=True))
    by_service = {}
    for container in containers:
        labels = container['Config'].get('Labels') or {}
        if labels.get('com.docker.compose.project') != project:
            raise SafetyError('Unexpected Compose project label')
        service = labels.get('com.docker.compose.service')
        if service not in ('api', 'postgres') or service in by_service:
            raise SafetyError('Unexpected or repeated service')
        networks = container['NetworkSettings'].get('Networks') or {}
        if not networks or any(not name.startswith(project + '_') for name in networks):
            raise SafetyError('Container has a non-isolated network')
        by_service[service] = container
    api, database = by_service['api'], by_service['postgres']
    ports = api['NetworkSettings']['Ports'].get('8080/tcp') or []
    if ports != [{'HostIp': '127.0.0.1', 'HostPort': '18088'}]:
        raise SafetyError('API port binding is not the reviewed loopback binding')
    storage = [m for m in api['Mounts'] if m['Destination'] == '/srv/woona']
    if len(storage) != 1 or storage[0]['Type'] != 'bind':
        raise SafetyError('Expected a dedicated synthetic storage bind')
    storage_root = Path(storage[0]['Source']).resolve()
    if not storage_root.is_relative_to(ISOLATED_ROOT.resolve()) or storage_root == ISOLATED_ROOT:
        raise SafetyError('Synthetic storage is outside the isolated directory')
    api_env = dict(value.split('=', 1) for value in api['Config']['Env'] if '=' in value)
    if api_env.get('WOONA_DEBUG_TOKEN') != token:
        raise SafetyError('Supplied token does not match isolated API environment')
    db_env = dict(value.split('=', 1) for value in database['Config']['Env'] if '=' in value)
    database_target = urlsplit(api_env.get('DATABASE_URL', ''))
    if (database_target.scheme != 'postgresql+psycopg' or database_target.hostname != 'postgres'
            or database_target.port not in (None, 5432)
            or database_target.path != '/' + db_env['POSTGRES_DB']
            or database_target.username != db_env['POSTGRES_USER']
            or database_target.password != db_env['POSTGRES_PASSWORD']
            or database_target.query or database_target.fragment
            or api_env.get('WOONA_STORAGE_ROOT') != '/srv/woona'):
        raise SafetyError('API database or storage does not match the isolated service')
    for mount in database['Mounts']:
        if mount.get('Name') and not mount['Name'].startswith(project + '_'):
            raise SafetyError('Database volume is outside the isolated project')
        if mount['Type'] == 'bind' and not Path(mount['Source']).resolve().is_relative_to(ISOLATED_ROOT.resolve()):
            raise SafetyError('Database bind is outside the isolated directory')
    return {'api_id': api['Id'], 'db_id': database['Id'], 'storage': storage_root,
            'db_user': db_env['POSTGRES_USER'], 'db_name': db_env['POSTGRES_DB'],
            'image_id': api['Image'], 'guards_passed': True}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def percentile(values, probability):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(len(ordered) * probability) - 1)], 3)


class Client:
    def __init__(self, token, account, deadline):
        self.token, self.account, self.deadline = token, account, deadline
        self.lock = threading.Lock()
        self.metrics = []
        self.reads = 0
        self.binary_bytes = 0

    def request(self, method, path, payload=None, *, headers=None, account=None,
                token=None, phase='fixture', expected=None, binary=False):
        if not path.startswith('/') or path.startswith('//') or '://' in path:
            raise SafetyError('Requests must use a relative path on the fixed connection')
        if time.monotonic() > self.deadline:
            raise SafetyError('Time budget exhausted')
        if payload is not None and not isinstance(payload, bytes):
            body = json.dumps(payload, ensure_ascii=True, separators=(',', ':')).encode()
        else:
            body = payload
        outgoing = {'Authorization': 'Bearer ' + (self.token if token is None else token),
                    'X-Woona-Account': self.account if account is None else account,
                    'X-Request-ID': 'load-' + uuid.uuid4().hex,
                    'Content-Type': 'application/offset+octet-stream' if binary else 'application/json'}
        outgoing.update(headers or {})
        with self.lock:
            if method in ('GET', 'HEAD'):
                if self.reads >= MAX_READS:
                    raise SafetyError('Read request limit reached')
                self.reads += 1
            if binary:
                self.binary_bytes += len(body or b'')
                if self.binary_bytes > MAX_BINARY_BYTES:
                    raise SafetyError('Binary transfer limit reached')
        start = time.monotonic()
        connection = http.client.HTTPConnection('127.0.0.1', 18088, timeout=8)
        try:
            connection.request(method, path, body, outgoing)
            response = connection.getresponse()
            status = response.status
            response_headers = {key.lower(): value for key, value in response.getheaders()}
            data = response.read()
        finally:
            connection.close()
        elapsed = (time.monotonic() - start) * 1000
        with self.lock:
            self.metrics.append({'phase': phase, 'method': method, 'status': status,
                                 'latency_ms': elapsed, 'response_bytes': len(data)})
        if expected is not None and status not in expected:
            parsed = json.loads(data) if data.startswith(b'{') else {}
            raise AssertionError({'case': phase, 'method': method, 'path': path,
                                  'expected': sorted(expected), 'actual': status,
                                  'error_code': parsed.get('code')})
        if status >= 400 and data.startswith(b'{'):
            error = json.loads(data)
            assert error.get('requestId') == response_headers.get('x-request-id')
            assert not any(marker in data.lower() for marker in
                [b'traceback', b'postgresql://', b'postgresql+psycopg://', b'invalid-secret-canary'])
        return status, response_headers, data

    def summary(self):
        phases = {}
        for phase in sorted({item['phase'] for item in self.metrics}):
            selected = [item for item in self.metrics if item['phase'] == phase]
            values = [item['latency_ms'] for item in selected]
            phases[phase] = {'requests': len(selected), 'p50_ms': percentile(values, .5),
                'p95_ms': percentile(values, .95), 'max_ms': round(max(values), 3),
                'statuses': dict(Counter(str(item['status']) for item in selected))}
        return {'requests': len(self.metrics), 'read_requests': self.reads,
                'binary_bytes_sent': self.binary_bytes, 'phases': phases,
                'http_5xx': sum(item['status'] >= 500 for item in self.metrics)}


def make_fixture(index, run, device):
    dog_id, profile_id, recording_id = [str(uuid.uuid4()) for _ in range(3)]
    animal = run + '-' + str(index)
    dog = {'schemaVersion': 2, 'animalId': animal, 'numberOrName': 'Synthetic load ' + str(index)}
    stamp = '2026-10-26T12:00:00Z'
    profile = {'dog': {'id': dog_id, 'numberOrName': dog['numberOrName'], 'expectedRevision': 0},
        'profileVersion': {'id': profile_id, 'schemaVersion': 2, 'validationState': 'complete',
            'questionnaire': dog, 'contentSha256': digest(canonical(dog)), 'clientCreatedAtUtc': stamp}}
    session = {'schemaVersion': 2, 'animalId': animal, 'sessionLabel': 'Synthetic load ' + str(index),
               'plannedActivities': ['Активность'], 'videoRequested': False}
    contents = {'packet': (b'packet:' + animal.encode()) * 100,
                'raw': (b'raw:' + animal.encode()) * 150,
                'packet_timeline': b'timeline:' + animal.encode(),
                'diagnostic': b'Synthetic diagnostics only\n', 'sync': b'{"synthetic":true}'}
    names = {'packet': 'пёс "нагрузка".bin' if index == 1 else 'packets.bin',
             'raw': 'raw.binlog', 'packet_timeline': 'packet_timeline.bin',
             'diagnostic': 'diagnostics.log', 'sync': 'sync.json'}
    artifacts = [{'id': str(uuid.uuid4()), 'type': kind, 'fileName': names[kind],
        'mimeType': 'text/plain' if kind == 'diagnostic' else 'application/json' if kind == 'sync' else 'application/octet-stream',
        'sizeBytes': len(data), 'sha256': digest(data), 'clientCreatedAtUtc': stamp}
        for kind, data in contents.items()]
    manifest = {'schemaVersion': 1, 'captureDeviceId': device, 'dog': profile['dog'],
        'dogProfileVersion': profile['profileVersion'],
        'recording': {'source': 'live', 'captureStatus': 'completed', 'startedAtUtc': stamp,
            'endedAtUtc': '2026-10-26T12:01:00Z', 'timezone': 'UTC', 'sessionLabel': session['sessionLabel'],
            'questionnaireSchemaVersion': 2, 'questionnaireValidationState': 'complete',
            'sessionQuestionnaire': session, 'videoRequested': False, 'appVersion': 'isolated-load-test'},
        'sync': {'schemaVersion': 2, 'monotonicClock': 'android.elapsedRealtimeNanos',
            'sessionZeroAtUtc': stamp, 'sessionZeroWallClockMs': 1793016000000,
            'sessionZeroMonotonicNs': 1000000000, 'sessionZeroUncertaintyNs': 1,
            'firstSensorPacketMonotonicNs': 1001000000, 'lastSensorPacketMonotonicNs': 1050000000,
            'cameraClockQuality': 'unavailable', 'sensorClockQuality': 'first_packet_arrival',
            'overallSyncQuality': 'unavailable', 'calibrationOffsetNs': 0},
        'artifacts': artifacts}
    return {'profile': profile, 'manifest': manifest, 'contents': contents, 'recording_id': recording_id}


def profile_path(fixture):
    p = fixture['profile']
    return '/v1/dogs/' + p['dog']['id'] + '/profile-versions/' + p['profileVersion']['id']


def upload(client, fixture, *, special=False):
    manifest = fixture['manifest'];path = '/v1/recordings/' + fixture['recording_id']
    client.request('PUT', path, manifest, expected={200})
    client.request('POST', path + '/complete', {}, expected={409}, phase='false-receipt-guard')
    for artifact in manifest['artifacts']:
        resource = '/v1/artifacts/' + artifact['id'];content = fixture['contents'][artifact['type']]
        if special and artifact['type'] == 'packet':
            client.request('PATCH', resource + '/content', b'x' * len(content),
                           headers={'Upload-Offset': '0'}, binary=True, expected={204}, phase='fault-recovery')
            client.request('POST', resource + '/complete', {}, expected={422}, phase='fault-recovery')
            assert client.request('HEAD', resource + '/content', expected={200}, phase='fault-recovery')[1]['upload-offset'] == '0'
            half = len(content) // 2
            client.request('PATCH', resource + '/content', content[:half], headers={'Upload-Offset': '0'}, binary=True, expected={204}, phase='fault-recovery')
            client.request('PATCH', resource + '/content', content[:half], headers={'Upload-Offset': '0'}, binary=True, expected={409}, phase='fault-recovery')
            client.request('POST', resource + '/complete', {}, expected={409}, phase='false-receipt-guard')
            state = json.loads(client.request('GET', path + '/sync-status', expected={200}, phase='false-receipt-guard')[2])
            assert state['ingestStatus'] != 'complete' and state['receiptSha256'] is None
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(client.request, 'PATCH', resource + '/content', content[half:],
                    headers={'Upload-Offset': str(half)}, binary=True, expected={204, 409}, phase='concurrent-offset') for _ in range(2)]
                assert sorted(f.result()[0] for f in futures) == [204, 409]
        else:
            client.request('PATCH', resource + '/content', content, headers={'Upload-Offset': '0'}, binary=True, expected={204})
        client.request('POST', resource + '/complete', {}, expected={200})
    first = json.loads(client.request('POST', path + '/complete', {}, expected={200})[2])
    second = json.loads(client.request('POST', path + '/complete', {}, expected={200}, phase='idempotency')[2])
    assert first['receiptSha256'] == second['receiptSha256']
    client.request('PUT', path, manifest, expected={200}, phase='idempotency')
    state = json.loads(client.request('GET', path + '/sync-status', expected={200}, phase='verify')[2])
    assert state['ingestStatus'] == 'complete' and state['receiptSha256'] == first['receiptSha256']
    artifact = manifest['artifacts'][0];resource = '/v1/artifacts/' + artifact['id'] + '/content'
    result = client.request('GET', resource, expected={200}, phase='verify')
    assert digest(result[2]) == artifact['sha256']
    ranged = client.request('GET', resource, headers={'Range': 'bytes=0-15'}, expected={206}, phase='verify')
    assert ranged[2] == fixture['contents'][artifact['type']][:16]
    ranged[1]['content-disposition'].encode('ascii')
    return fixture


def fuzz(client, fixture):
    path = '/v1/recordings/' + fixture['recording_id'];artifact = fixture['manifest']['artifacts'][0]
    resource = '/v1/artifacts/' + artifact['id'] + '/content';checks=[];failures=[]
    def case(name, method, route, payload=None, expected=(400, 403, 404, 405, 409, 411, 413, 416, 422), **kwargs):
        status, headers, body = client.request(method, route, payload, phase='negative-fuzz', **kwargs)
        ok = status in expected
        checks.append({'case': name, 'status': status, 'passed': ok})
        if not ok:failures.append({'case': name, 'status': status, 'error_code': json.loads(body).get('code') if body.startswith(b'{') else None})
    case('missing_or_invalid_token', 'GET', '/v1/me', token='invalid-secret-canary', expected=(401,))
    for target in [path, path + '/sync-status', resource, '/v1/dogs/' + fixture['manifest']['dog']['id']]:
        case('cross_account_' + target.rsplit('/', 1)[-1], 'GET', target, account=client.account + '-other', expected=(404,))
    case('cross_account_recording_write', 'PUT', path, fixture['manifest'], account=client.account + '-other', expected=(404,))
    case('cross_account_profile_write', 'PUT', profile_path(fixture), fixture['profile'], account=client.account + '-other', expected=(404,))
    case('cross_account_complete', 'POST', path + '/complete', {}, account=client.account + '-other', expected=(404,))
    case('cross_account_file_write', 'PATCH', resource, b'x', headers={'Upload-Offset':'0'}, account=client.account + '-other', binary=True, expected=(404,))
    foreign = json.loads(client.request('GET', '/v1/dogs', account=client.account + '-other', expected={200}, phase='negative-fuzz')[2])
    assert not foreign['items']
    for value in ['bad id', 'x' * 1000]:
        status, h, body = client.request('GET', '/v1/missing', headers={'X-Request-ID': value}, expected={404}, phase='negative-fuzz')
        assert len(h['x-request-id']) <= 128 and h['x-request-id'] != value
    for route in ['/v1/recordings/not-a-uuid', '/v1/recordings/' + '9' * 1024, '/v1/artifacts/%2e%2e%2fetc%2fpasswd/content', '/v1/recordings/../../health/ready', '/.env', '/server/app.py']:
        case('adversarial_path', 'GET', route, expected=(400, 404, 422))
    for data in [b'{', b'{"x":', b'null', b'[]', b'{"x":"\xff"}', b'[' * 1200 + b'0' + b']' * 1200]:
        case('malformed_json', 'PUT', path, data, expected=(400, 422))
    case('oversized_json', 'PUT', path, b'{"oversized":"' + b'x' * MAX_JSON + b'"}', expected=(413,))
    for value in ['bytes=3-1', 'items=0-1', 'bytes=-1', 'bytes=0-1,4-5', 'bytes=999999999999-', 'bytes=' + '9' * 5000 + '-']:
        case('invalid_download_range', 'GET', resource, headers={'Range': value}, expected=(416,))
    for value in ['-1', 'not-a-number', '9' * 5000]:
        case('invalid_upload_offset', 'PATCH', resource, b'x', headers={'Upload-Offset': value}, binary=True, expected=(422,))
    case('declared_oversized_chunk', 'PATCH', resource, b'', headers={'Upload-Offset': '0', 'Content-Length': str(16 * 1024 * 1024 + 1)}, binary=True, expected=(413,))
    for filename in ['../escape.bin', '/absolute.bin', 'bad\\path.bin', 'nul\x00.bin', 'crlf\r\nHeader.bin']:
        manifest = copy.deepcopy(fixture['manifest']);manifest['artifacts'][0]['fileName'] = filename
        case('unsafe_filename', 'PUT', path, manifest, expected=(422,))
    duplicate = copy.deepcopy(fixture['manifest']);duplicate['artifacts'].append(copy.deepcopy(duplicate['artifacts'][0]))
    case('duplicate_artifact', 'PUT', path, duplicate, expected=(422,))
    naive = copy.deepcopy(fixture['manifest']);naive['recording']['startedAtUtc'] = '2026-10-26T12:00:00'
    case('timezone_missing', 'PUT', path, naive, expected=(422,))
    surrogate = copy.deepcopy(fixture['manifest']);surrogate['dogProfileVersion']['questionnaire']['numberOrName'] = '\ud800'
    case('invalid_unicode_scalar', 'PUT', path, surrogate, expected=(422,))
    for name, value in [('nan', float('nan')), ('infinity', float('inf')), ('exponent_overflow', float('inf'))]:
        manifest = copy.deepcopy(fixture['manifest']);manifest['sync']['estimatedDriftPpm'] = value
        body = json.dumps(manifest).encode()
        if name == 'exponent_overflow':
            body = body.replace(b'Infinity', b'1e999')
        case('nonfinite_' + name, 'PUT', path, body, expected=(400,422))
    for name, field, value in [('monotonic_overflow', 'sessionZeroMonotonicNs', 2**63),
                              ('calibration_underflow', 'calibrationOffsetNs', -(2**63)-1)]:
        manifest = copy.deepcopy(fixture['manifest']);manifest['sync'][field] = value
        case(name, 'PUT', path, manifest, expected=(422,))
    schema = copy.deepcopy(fixture['manifest']);schema['schemaVersion'] = 2**31
    case('schema_integer_overflow', 'PUT', path, schema, expected=(422,))
    revision = copy.deepcopy(fixture['profile']);revision['dog']['expectedRevision'] = 2**63
    case('revision_integer_overflow', 'PUT', profile_path(fixture), revision, expected=(422,))
    for value in ['0001-01-01T00:00:00+14:00', '9999-12-31T23:59:59-14:00', '2026-13-01T12:00:00Z', '2026-10-26']:
        manifest = copy.deepcopy(fixture['manifest']);manifest['sync']['sessionZeroAtUtc'] = value
        case('timestamp_boundary', 'PUT', path, manifest, expected=(422,))
    for key, value in [('numberOrName', '\x00'), ('\ud800', 'invalid-key')]:
        manifest = copy.deepcopy(fixture['manifest']);manifest['dogProfileVersion']['questionnaire'][key] = value
        case('invalid_database_text', 'PUT', path, manifest, expected=(422,))
    nested = copy.deepcopy(fixture['manifest']);value = 0
    for _ in range(100):value = {'nested':value}
    nested['dogProfileVersion']['questionnaire']['notes'] = value
    case('deep_metadata', 'PUT', path, nested, expected=(400,422))
    duplicate_content = copy.deepcopy(fixture['profile']);duplicate_content['profileVersion']['id'] = str(uuid.uuid4());duplicate_content['dog']['expectedRevision'] = 1
    route = '/v1/dogs/' + duplicate_content['dog']['id'] + '/profile-versions/' + duplicate_content['profileVersion']['id']
    case('new_profile_uuid_same_content', 'PUT', route, duplicate_content, expected=(409,))
    return {'checks': checks, 'failures': failures}


def verify_database(guard, client, fixtures):
    assert re.fullmatch(r'loadtest-[0-9a-f]{32}', client.account)
    sql = """BEGIN READ ONLY;
    SELECT json_build_object(
      'dogs',(SELECT count(*) FROM dogs WHERE account_id='{account}'),
      'profiles',(SELECT count(*) FROM dog_profile_versions p JOIN dogs d ON d.id=p.dog_id WHERE d.account_id='{account}'),
      'recordings',(SELECT count(*) FROM recordings r JOIN dogs d ON d.id=r.dog_id WHERE d.account_id='{account}'),
      'complete',(SELECT count(*) FROM recordings r JOIN dogs d ON d.id=r.dog_id WHERE d.account_id='{account}' AND r.ingest_status='complete'),
      'false_receipts',(SELECT count(*) FROM recordings r JOIN dogs d ON d.id=r.dog_id WHERE d.account_id='{account}' AND r.ingest_status='complete' AND EXISTS(SELECT 1 FROM artifacts a WHERE a.recording_id=r.id AND a.storage_status<>'available')),
      'wrong_profile_dog',(SELECT count(*) FROM recordings r JOIN dogs d ON d.id=r.dog_id JOIN dog_profile_versions p ON p.id=r.dog_profile_version_id WHERE d.account_id='{account}' AND p.dog_id<>r.dog_id),
      'missing_sync',(SELECT count(*) FROM recordings r JOIN dogs d ON d.id=r.dog_id LEFT JOIN recording_sync s ON s.recording_id=r.id WHERE d.account_id='{account}' AND s.recording_id IS NULL),
      'artifacts',(SELECT coalesce(json_agg(json_build_object('id',a.id,'recording_id',a.recording_id,'path',a.server_relative_path,'sha256',a.sha256,'size',a.expected_size_bytes,'state',a.storage_status)),'[]') FROM artifacts a JOIN recordings r ON r.id=a.recording_id JOIN dogs d ON d.id=r.dog_id WHERE d.account_id='{account}')
    ); COMMIT;""".format(account=client.account)
    result = json.loads(subprocess.check_output(['docker', 'exec', guard['db_id'], 'psql', '-XAtq', '-U', guard['db_user'], '-d', guard['db_name'], '-c', sql], text=True))
    count = len(fixtures)
    assert result['dogs'] == result['profiles'] == result['recordings'] == result['complete'] == count, {k:v for k,v in result.items() if k != 'artifacts'}
    assert result['false_receipts'] == result['wrong_profile_dog'] == result['missing_sync'] == 0
    assert len(result['artifacts']) == count * 5
    root = guard['storage'].resolve();total = 0
    for artifact in result['artifacts']:
        path = (root / artifact['path']).resolve()
        assert path.is_relative_to(root) and path.is_file() and artifact['state'] == 'available'
        assert path.stat().st_size == artifact['size'] and digest(path.read_bytes()) == artifact['sha256']
        assert not (root / 'incoming' / (artifact['id'] + '.part')).exists()
        total += artifact['size']
    return {k:v for k,v in result.items() if k != 'artifacts'} | {'verified_artifacts': count * 5, 'verified_bytes': total}


def run(args):
    token = os.environ.get('WOONA_TEST_TOKEN', '')
    guard = inspect_guard(args.base_url, args.project, token)
    if not args.execute or not 1 <= args.fixtures <= MAX_FIXTURES or not 0 <= args.reads <= 600 or not 1 <= args.concurrency <= 8:
        raise SafetyError('Explicit execution and bounded fixtures/reads/concurrency are required')
    started = time.monotonic();account = args.existing_account or 'loadtest-' + uuid.uuid4().hex
    if not re.fullmatch(r'loadtest-[0-9a-f]{32}', account):
        raise SafetyError('Only a generated synthetic loadtest workspace may be reused')
    client = Client(token, account, started + 300)
    report = {'project': args.project, 'base_url': args.base_url, 'account': account,
              'guard': {'passed': True, 'api_image': guard['image_id']}, 'started_at_utc': datetime.now(timezone.utc).isoformat()}
    try:
        device = json.loads(client.request('GET', '/v1/me', expected={200}, phase='preflight')[2])['deviceId']
        client.request('GET', '/health/ready', expected={200}, phase='preflight')
        if args.existing_account:
            # Rerun after a fix without creating another fifty profiles or rewriting bytes.
            listed = json.loads(client.request('GET', '/v1/dogs?limit=200', expected={200}, phase='reuse-fixtures')[2])
            fixtures = []
            for dog in listed['items']:
                index = int(dog['profileVersion']['questionnaire']['animalId'].rsplit('-', 1)[1])
                fixture = make_fixture(index, account, device)
                records = json.loads(client.request('GET', '/v1/dogs/' + dog['id'] + '/recordings', expected={200}, phase='reuse-fixtures')[2])
                if len(records['items']) != 1:
                    raise SafetyError('Reused synthetic animal must own exactly one recording')
                recording_id = records['items'][0]['id']
                detail = json.loads(client.request('GET', '/v1/recordings/' + recording_id, expected={200}, phase='reuse-fixtures')[2])
                fixture['recording_id'] = recording_id
                fixture['profile']['dog']['id'] = dog['id']
                fixture['profile']['profileVersion']['id'] = detail['profileVersion']['id']
                fixture['manifest']['dog'] = fixture['profile']['dog']
                fixture['manifest']['dogProfileVersion'] = fixture['profile']['profileVersion']
                ids_by_type = {item['type']: item['id'] for item in detail['artifacts']}
                for artifact in fixture['manifest']['artifacts']:
                    artifact['id'] = ids_by_type[artifact['type']]
                fixtures.append(fixture)
            fixtures.sort(key=lambda f: int(f['profile']['profileVersion']['questionnaire']['animalId'].rsplit('-', 1)[1]))
            if len(fixtures) != args.fixtures:
                raise SafetyError('Reused fixture count differs from the reviewed bound')
            report['fixture_mode'] = 'reuse_existing_without_new_entities'
            for fixture in fixtures:
                client.request('PUT', '/v1/recordings/' + fixture['recording_id'], fixture['manifest'], expected={200}, phase='idempotency')
        else:
            client.request('PUT', '/v1/accounts/' + account, {}, expected={200})
            fixtures = [make_fixture(i, account, device) for i in range(args.fixtures)]
            first, competing = fixtures[0], make_fixture(0, account, device)
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda fixture: client.request('PUT', profile_path(fixture), fixture['profile'], expected={200,409}, phase='concurrent-identity'), [first, competing]))
            assert sorted(result[0] for result in results) == [200,409]
            fixtures[0] = first if results[0][0] == 200 else competing
            upload(client, fixtures[0], special=True)
            def prepare(fixture):
                client.request('PUT', profile_path(fixture), fixture['profile'], expected={200})
                return upload(client, fixture)
            with ThreadPoolExecutor(max_workers=min(args.concurrency, 4)) as pool:
                list(pool.map(prepare, fixtures[1:]))
            report['fixture_mode'] = 'created_bounded_synthetic_entities'
        report['negative_fuzz'] = fuzz(client, fixtures[0])
        paths = ['/v1/recordings/' + fixture['recording_id'] + suffix for fixture in fixtures for suffix in ['', '/sync-status']]
        paths += ['/v1/dogs?limit=20', '/health/ready']
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            list(pool.map(lambda i: client.request('GET', paths[i % len(paths)], expected={200}, phase='read-load'), range(args.reads)))
        report['invariants'] = verify_database(guard, client, fixtures)
        client.request('GET', '/health/ready', expected={200}, phase='postflight')
        report['passed'] = not report['negative_fuzz']['failures'] and not client.summary()['http_5xx']
    except Exception as error:
        report['passed'] = False
        report['failure_type'] = type(error).__name__
        report['failure'] = str(error)[:800]
    report['duration_seconds'] = round(time.monotonic() - started, 3)
    report['metrics'] = client.summary()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--project', required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--fixtures', type=int, default=50)
    parser.add_argument('--reads', type=int, default=600)
    parser.add_argument('--concurrency', type=int, default=6)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--existing-account', help='Reuse only the generated loadtest workspace from an earlier report')
    raise SystemExit(run(parser.parse_args()))


if __name__ == '__main__':
    main()
