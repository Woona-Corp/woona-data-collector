"""Crash-copy retries with fake transactions and synthetic source bytes only."""
from contextlib import contextmanager
import errno
import hashlib
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from server import archive_import
from server.directory_import import inspect_directory, verify_directory_plan
from server.tests.test_directory_import import DirectoryInspectionTest


class ImportRetryTest(unittest.TestCase):
    source: Path
    root: Path
    review: dict
    setUp = DirectoryInspectionTest.setUp
    write_metadata = DirectoryInspectionTest.write_metadata

    def exercise(self, cross_device=False, process_stop=False):
        plan = inspect_directory(self.source, self.review)
        if cross_device:
            plan['sourceKind'] = 'native_archive'
        root = self.root / 'canonical'
        root.mkdir()
        target = root / 'recordings' / plan['dogId'] / '2026-10-05' / plan['recordingId'] / plan['artifacts'][0]['fileName']
        partial = target.with_suffix(target.suffix + '.import-part')
        before = {p.name: p.read_bytes() for p in self.source.iterdir()}
        commits = []
        @contextmanager
        def transaction():
            yield SimpleNamespace(execute=lambda *a, **k: SimpleNamespace(
                scalar_one=lambda: 'YES', scalar_one_or_none=lambda: uuid.UUID(plan['manifest']['profile']['id'])))
            commits.append(True)
        original_link = archive_import.os.link
        def link(source, destination):
            if cross_device and Path(source).parent == self.source:
                raise OSError(errno.EXDEV, 'synthetic cross-device')
            return original_link(source, destination)
        def interrupted(source, output, length):
            output.write(source.read(1))
            if process_stop:
                raise KeyboardInterrupt('synthetic process stop')
            raise OSError(errno.ENOSPC, 'synthetic full disk')
        engine = SimpleNamespace(begin=transaction)
        with patch.object(archive_import, 'preflight', return_value={'state': 'ready', 'dogRevision': 1}), \
             patch.object(archive_import.os, 'link', side_effect=link):
            with patch.object(archive_import.shutil, 'copyfileobj', side_effect=interrupted):
                with self.assertRaises(KeyboardInterrupt if process_stop else OSError):
                    archive_import.apply_plan(engine, root, plan)
            self.assertEqual(commits, [], 'Failed copy published a DB transaction')
            self.assertTrue(partial.is_file())
            prefix = partial.read_bytes()
            self.assertFalse(target.exists())
            # Exact reviewed plan, with the original interrupted attempt retained.
            self.assertEqual(archive_import.apply_plan(engine, root, plan)['state'], 'imported')
        self.assertEqual(partial.read_bytes(), prefix, 'Retry overwrote interrupted/unknown original')
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.source.iterdir()})
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), plan['artifacts'][0]['sha256'])
        self.assertNotEqual(target.stat().st_ino, Path(plan['artifacts'][0]['stagedPath']).stat().st_ino)
        if cross_device:
            plan['sourceKind'] = 'native_directory'
        verify_directory_plan(plan)

    def test_enospc_directory_copy_retries_exact_plan(self):
        self.exercise()

    def test_process_stop_directory_copy_retries_exact_plan(self):
        self.exercise(process_stop=True)

    def test_enospc_cross_filesystem_archive_copy_retries_exact_plan(self):
        self.exercise(cross_device=True)
