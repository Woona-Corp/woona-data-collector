"""Reviewed loose-export recovery must preserve provenance and reject guesses."""
import copy
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import uuid
import zipfile

from sqlalchemy import text
from server.archive_import import apply_plan, preflight
from server.directory_import import inspect_directory, verify_directory_plan
from server.tests.test_archive_import import make_archive
from server.tests.test_heart import request


class DirectoryInspectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.api_manifest, _, archive = make_archive(self.root)
        self.source = self.root / 'original'
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(self.source)
        self.share = json.loads((self.source / 'manifest.json').read_bytes())
        self.sync = json.loads((self.source / 'sync.json').read_bytes())
        self.source_profile = str(uuid.uuid4())
        self.sync['profileId'] = self.source_profile
        self.sync['sessionQuestionnaire']['videoRequested'] = False
        self.share['profile']['id'] = self.source_profile
        self.share['recording']['questionnaire']['videoRequested'] = False
        self.share['synchronization'] = copy.deepcopy(self.sync)
        self.share['files'] = [f for f in self.share['files'] if f['name'] != 'video.mp4']
        (self.source / 'video.mp4').unlink()
        self.review = {'schemaVersion': 1, 'recordingId': self.share['recording']['id'],
            'sourceProfileId': self.source_profile, 'dogId': self.api_manifest['dog']['id'],
            'sourceId': 'synthetic:original-directory', 'reason': 'Synthetic explicit identity review',
            'approvedSyncDifferences': []}
        self.write_metadata()

    def write_metadata(self):
        (self.source / 'sync.json').write_text(json.dumps(self.sync))
        for item in self.share['files']:
            item['size'] = (self.source / item['name']).stat().st_size
        (self.source / 'manifest.json').write_text(json.dumps(self.share))
        self.review['expectedManifestSha256'] = hashlib.sha256((self.source / 'manifest.json').read_bytes()).hexdigest()
        self.review['expectedSyncSha256'] = hashlib.sha256((self.source / 'sync.json').read_bytes()).hexdigest()

    def test_original_ids_and_both_reviewed_session_labels_are_preserved(self):
        self.share['synchronization']['sessionQuestionnaire']['sessionLabel'] = 'renamed later'
        self.share['recording']['questionnaire']['sessionLabel'] = 'renamed later'
        self.share['recording']['sessionLabel'] = 'renamed later'
        self.review['approvedSyncDifferences'] = ['sessionQuestionnaire.sessionLabel']
        self.write_metadata()
        before = {p.name: p.read_bytes() for p in self.source.iterdir()}
        plan = inspect_directory(self.source, self.review)
        self.assertEqual(plan['dogId'], self.api_manifest['dog']['id'])
        self.assertEqual(plan['manifest']['profile']['id'], self.source_profile)
        self.assertEqual(plan['sync'], self.sync)
        self.assertEqual(plan['manifest'], self.share)
        self.assertIsNone(plan['archiveSha256'])
        self.assertEqual(plan['metadataReview']['sessionDifferences'], ['sessionLabel'])
        self.assertEqual(len(plan['sourceInventory']), 6)
        verify_directory_plan(plan)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.source.iterdir()})

    def test_unreviewed_clock_label_or_identity_changes_are_rejected(self):
        for path in ['sessionLabel', 'clock', 'identity']:
            with self.subTest(path=path):
                original = copy.deepcopy(self.share)
                if path == 'sessionLabel':
                    self.share['synchronization']['sessionQuestionnaire']['sessionLabel'] = 'changed'
                elif path == 'clock':
                    self.share['synchronization']['sensor']['monotonicTimeNs'] += 1
                else:
                    self.share['profile']['id'] = str(uuid.uuid4())
                self.write_metadata()
                with self.assertRaises(ValueError):
                    inspect_directory(self.source, self.review)
                self.share = original
                self.write_metadata()
        self.review['approvedSyncDifferences'] = ['sensor.monotonicTimeNs']
        with self.assertRaisesRegex(ValueError, 'cannot be approved'):
            inspect_directory(self.source, self.review)

    def test_missing_symlink_extra_and_changed_source_files_are_rejected(self):
        plan = inspect_directory(self.source, self.review)
        packet = self.source / 'packets.bin'
        original = packet.read_bytes()
        packet.write_bytes(b'x' * len(original))
        with self.assertRaisesRegex(ValueError, 'changed before publication'):
            verify_directory_plan(plan)
        packet.unlink()
        with self.assertRaisesRegex(ValueError, 'entries differ'):
            inspect_directory(self.source, self.review)
        outside = self.root / 'outside.bin'
        outside.write_bytes(original)
        packet.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            inspect_directory(self.source, self.review)
        packet.unlink()
        packet.write_bytes(original)
        (self.source / 'extra.bin').write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'entries differ'):
            inspect_directory(self.source, self.review)

    def test_stale_metadata_digest_and_invented_completion_are_rejected(self):
        (self.source / 'sync.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'differs from the operator review'):
            inspect_directory(self.source, self.review)
        self.share['recording']['status'] = 'recording'
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, 'final capture status'):
            inspect_directory(self.source, self.review)


class DirectoryImportApiTest(unittest.TestCase):
    write_metadata = DirectoryInspectionTest.write_metadata
    @classmethod
    def setUpClass(cls):
        from server.tests.test_api import ApiIntegrationTest
        ApiIntegrationTest.setUpClass()

    def setUp(self):
        DirectoryInspectionTest.setUp(self)
        profile = {'dog': self.api_manifest['dog'], 'profileVersion': self.api_manifest['dogProfileVersion']}
        request('PUT', '/v1/dogs/' + profile['dog']['id'] + '/profile-versions/' + profile['profileVersion']['id'], profile)

    def test_reviewed_import_preserves_current_profile_and_original_metadata(self):
        from server.app import engine, STORAGE_ROOT
        path = '/v1/dogs/' + self.api_manifest['dog']['id']
        before = json.loads(request('GET', path)[2])
        plan = inspect_directory(self.source, self.review)
        self.assertEqual(apply_plan(engine, STORAGE_ROOT, plan)['state'], 'imported')
        self.assertEqual(apply_plan(engine, STORAGE_ROOT, plan)['state'], 'already_imported')
        after = json.loads(request('GET', path)[2])
        for key in ['id', 'revision', 'accountId', 'profileVersion']:
            self.assertEqual(before[key], after[key])
        with engine.connect() as c:
            alignment = c.execute(text('SELECT alignment FROM recording_sync WHERE recording_id=:id'),
                {'id': uuid.UUID(plan['recordingId'])}).scalar_one()
        self.assertEqual(alignment['original_capture_sync'], self.sync)
        self.assertEqual(alignment['archive_import']['source_kind'], 'native_directory')
        self.assertEqual(alignment['archive_import']['identity_review'], self.review)
        self.assertIsNone(alignment['archive_import']['archive_sha256'])

    def test_unreviewed_merge_and_wrong_external_identity_are_rejected(self):
        from server.app import engine
        plan = inspect_directory(self.source, self.review)
        unreviewed = copy.deepcopy(plan)
        del unreviewed['identityReview']
        with engine.connect() as c:
            with self.assertRaisesRegex(ValueError, 'explicit hash-bound'):
                preflight(c, unreviewed)
            plan['manifest']['profile']['questionnaire']['animalId'] = 'different-identity'
            with self.assertRaisesRegex(ValueError, 'existing canonical external'):
                preflight(c, plan)
