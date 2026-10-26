"""Native Share recovery validates source bytes, identity and atomic DB publication."""
import copy
import hashlib
import importlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import uuid
import zipfile

from sqlalchemy import text
from server.archive_import import inspect_archive, apply_plan, preflight, validate_questionnaires
from server.tests.test_api import canonical_hash
from server.tests.test_heart import heart_manifest, request


def make_archive(directory):
    manifest, contents = heart_manifest()
    dog_id, recording_id = manifest['dog']['id'], str(uuid.uuid4())
    session = manifest['recording']['sessionQuestionnaire']
    session['sessionKind'] = 'activity'
    session['animalId'] = manifest['dogProfileVersion']['questionnaire']['animalId']
    session.pop('heartQuestionnaire')
    sync = {'schemaVersion': 2, 'recordingId': recording_id, 'profileId': dog_id,
        'source': 'live', 'timezone': 'UTC', 'selectedSessionStartUtc': '2026-10-05T10:00:00Z',
        'firstSensorDeviceTimerMillis': 1, 'lastSensorPacketMonotonicNs': 20,
        'dogQuestionnaire': manifest['dogProfileVersion']['questionnaire'],
        'sessionQuestionnaire': session,
        'sensor': {'absoluteUtc': '2026-10-05T10:00:00Z', 'wallClockEpochMillis': 1791194400000,
            'monotonicTimeNs': 10, 'monotonicClock': 'android.elapsedRealtimeNanos', 'samplingUncertaintyNs': 1},
        'video': None}
    names = {'packet': 'packets.bin', 'packet_timeline': 'packet_timeline.bin', 'raw': 'raw_fragments.binlog',
             'diagnostic': 'diagnostics.log', 'sync': 'sync.json', 'video': 'video.mp4'}
    files = {names[kind]: content for kind, content in contents.items()}
    files['sync.json'] = json.dumps(sync).encode()
    share = {'createdAtMillis': 1791194460000, 'sessionStartMillis': 1791194400000,
        'profile': {'id': dog_id, 'questionnaire': sync['dogQuestionnaire']},
        'recording': {'id': recording_id, 'source': 'live', 'status': 'completed',
                      'sessionLabel': session['sessionLabel'], 'timezone': 'UTC', 'questionnaire': session},
        'synchronization': sync, 'files': [{'name': name, 'size': len(content)} for name, content in files.items()]}
    files['manifest.json'] = json.dumps(share).encode()
    path = Path(directory) / 'source.zip'
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as bundle:
        for name, content in files.items():bundle.writestr(name, content)
    return manifest, share, path


class ArchiveValidationTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manifest, self.share, self.archive = make_archive(self.root)

    def inspect(self, **overrides):
        args = {'expected_sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            'recording_id': self.share['recording']['id'], 'dog_id': self.share['profile']['id'],
            'source_id': 'synthetic:test', 'staging': self.root / 'staging', 'reserve_bytes': 0}
        args.update(overrides)
        return inspect_archive(self.archive, **args)

    def test_verified_bytes_original_snapshots_and_unknowns_are_preserved(self):
        plan = self.inspect()
        validate_questionnaires(plan)
        self.assertEqual(plan['sync'], self.share['synchronization'])
        self.assertEqual(plan['manifest'], self.share)
        self.assertEqual(len(plan['artifacts']), 6)
        self.assertIn('hardware_calibration_not_measured', plan['unknowns'])
        for item in plan['artifacts']:
            self.assertEqual(hashlib.sha256(Path(item['stagedPath']).read_bytes()).hexdigest(), item['sha256'])
        # A rerun checks the extracted originals and remains deterministic.
        self.assertEqual(self.inspect(), plan)

    def test_wrong_archive_digest_or_mapping_is_rejected_before_publication(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            self.inspect(expected_sha256='0' * 64)
        with self.assertRaisesRegex(ValueError, 'Recording identity'):
            self.inspect(recording_id=str(uuid.uuid4()))
        with self.assertRaisesRegex(ValueError, 'profile UUID'):
            self.inspect(dog_id=str(uuid.uuid4()))

    def test_zip_slip_duplicate_and_unlisted_entries_are_rejected(self):
        for name in ['../escape', '/absolute', 'manifest.json']:
            with self.subTest(name=name):
                _, _, archive = make_archive(self.root)
                with zipfile.ZipFile(archive, 'a') as bundle:
                    bundle.writestr(name, b'bad')
                with self.assertRaisesRegex(ValueError, 'duplicate, unsafe or unsupported'):
                    self.inspect()
        self.assertFalse((self.root.parent / 'escape').exists())

    def test_changed_extracted_file_is_not_trusted_by_size(self):
        plan = self.inspect()
        path = Path(plan['artifacts'][0]['stagedPath'])
        path.write_bytes(b'x' * path.stat().st_size)
        with self.assertRaisesRegex(ValueError, 'CRC/size mismatch'):
            self.inspect()

    def test_missing_original_clock_does_not_get_an_invented_zero(self):
        with zipfile.ZipFile(self.archive) as bundle:
            data = {name: bundle.read(name) for name in bundle.namelist()}
        share = json.loads(data['manifest.json'])
        share['synchronization']['sensor'].pop('monotonicTimeNs')
        data['sync.json'] = json.dumps(share['synchronization']).encode()
        share['files'] = [dict(item, size=len(data[item['name']])) for item in share['files']]
        data['manifest.json'] = json.dumps(share).encode()
        with zipfile.ZipFile(self.archive, 'w') as bundle:
            for name, content in data.items():bundle.writestr(name, content)
        with self.assertRaisesRegex(ValueError, 'monotonic value missing'):
            self.inspect()

    def test_no_room_fails_without_removing_archive(self):
        usage = type('Disk', (), {'free': 1})()
        with patch('server.archive_import.shutil.disk_usage', return_value=usage):
            with self.assertRaisesRegex(OSError, 'Insufficient space'):
                self.inspect()
        self.assertTrue(self.archive.is_file())


class ArchiveImportApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from server.tests.test_api import ApiIntegrationTest
        ApiIntegrationTest.setUpClass()

    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manifest, self.share, self.archive = make_archive(self.root)
        profile = {'dog': self.manifest['dog'], 'profileVersion': self.manifest['dogProfileVersion']}
        request('PUT', '/v1/dogs/' + self.manifest['dog']['id'], profile)
        self.plan = inspect_archive(self.archive, expected_sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            recording_id=self.share['recording']['id'], dog_id=self.share['profile']['id'],
            source_id='synthetic:test', staging=self.root / 'staging', reserve_bytes=0)

    def test_import_is_idempotent_preserves_current_profile_and_old_wire_decoder(self):
        from server.app import engine, STORAGE_ROOT
        dog_path = '/v1/dogs/' + self.plan['dogId']
        before = json.loads(request('GET', dog_path)[2])
        with engine.connect() as connection:
            self.assertEqual(preflight(connection, self.plan)['state'], 'ready')
        result = apply_plan(engine, STORAGE_ROOT, self.plan)
        self.assertEqual(result['state'], 'imported')
        self.assertEqual(apply_plan(engine, STORAGE_ROOT, self.plan)['state'], 'already_imported')
        after = json.loads(request('GET', dog_path)[2])
        self.assertEqual({k:after[k] for k in ['id','accountId','revision','numberOrName','profileVersion']},
                         {k:before[k] for k in ['id','accountId','revision','numberOrName','profileVersion']})
        detail = json.loads(request('GET', '/v1/recordings/' + self.plan['recordingId'])[2])
        self.assertEqual(detail['sync']['calibrationOffsetNs'], 0)
        self.assertIsInstance(detail['sync']['calibrationOffsetNs'], int)  # Installed Android getLong still works.
        self.assertFalse(detail['sync']['calibration']['measured'])
        self.assertIsNone(detail['sync']['calibration']['offsetNs'])
        self.assertTrue(detail['sync']['calibration']['compatibilityPlaceholder'])
        with engine.connect() as connection:
            self.assertIsNone(connection.execute(text('SELECT calibration_offset_ns FROM recording_sync WHERE recording_id=:id'),
                {'id': uuid.UUID(self.plan['recordingId'])}).scalar_one())
        progress = json.loads(request('GET', '/v1/recordings/' + self.plan['recordingId'] + '/sync-status')[2])
        self.assertTrue(progress['transfer']['receiptVerified'])
        self.assertEqual(len(detail['artifacts']), 6)

    def test_failed_publication_rolls_back_database_and_keeps_originals(self):
        from server.app import engine, STORAGE_ROOT
        original_link = __import__('os').link
        calls = 0
        def failure(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:raise OSError('synthetic publication failure')
            return original_link(source, target)
        with patch('server.archive_import.os.link', side_effect=failure):
            with self.assertRaisesRegex(OSError, 'publication failure'):
                apply_plan(engine, STORAGE_ROOT, self.plan)
        with engine.connect() as connection:
            self.assertEqual(connection.execute(text('SELECT count(*) FROM recordings WHERE id=:id'),
                {'id': uuid.UUID(self.plan['recordingId'])}).scalar_one(), 0)
        self.assertTrue(self.archive.exists())
        self.assertTrue(all(Path(item['stagedPath']).is_file() for item in self.plan['artifacts']))
        self.assertEqual(apply_plan(engine, STORAGE_ROOT, self.plan)['state'], 'imported')

    def test_nonexistent_animal_and_conflicting_existing_recording_are_not_overwritten(self):
        from server.app import engine, STORAGE_ROOT
        fake = copy.deepcopy(self.plan)
        fake['dogId'] = str(uuid.uuid4())
        with engine.connect() as connection:
            with self.assertRaisesRegex(ValueError, 'does not exist'):
                preflight(connection, fake)
        apply_plan(engine, STORAGE_ROOT, self.plan)
        fake = copy.deepcopy(self.plan)
        fake['artifacts'][0]['sha256'] = '0' * 64
        with engine.connect() as connection:
            with self.assertRaisesRegex(ValueError, 'differs'):
                preflight(connection, fake)
