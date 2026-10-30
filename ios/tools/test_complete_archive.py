#!/usr/bin/env python3
"""Independent ZIP64 compatibility / failure tests. Requires macOS Swift + SQLite3.

Compiles the production exporter unchanged, then validates its archives with Python's
standard ZIP reader and SQLite (not another copy of the production ZIP parser).
The >4 GiB fixture runs by default. Only ordinary dependency-selected CI may
explicitly set WOONA_SKIP_ZIP64_LARGE=1; storage/exporter and release checks must
leave it enabled. This gate does not skip any XCTest target or archive assertions.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

MAIN = r'''
import Foundation
import SQLite3

enum WoonaStoreError: LocalizedError {
    case sqlite(String), invalidData(String)
    var errorDescription: String? { switch self { case .sqlite(let value), .invalidData(let value): return value } }
}
let mode = CommandLine.arguments[1]
let base = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let root = base.appendingPathComponent("Woona", isDirectory: true)
let output = base.appendingPathComponent("out.zip")
let exporter = CompleteDataArchive(dataDirectory: root)
do {
    if mode == "entry-count" {
        let zip = try StreamingZIP64(output)
        for index in 0..<65_537 {
            try zip.add(name: "file-\(index).bin", size: 0) { Data() }
        }
        try zip.finish()
    } else if mode == "large-file" {
        let zip = try StreamingZIP64(output)
        let size: UInt64 = 4_294_967_296 + 65_537
        var remaining = size
        let block = Data(repeating: 0x5a, count: 65_536)
        try zip.add(name: "large-video.mp4", size: size) {
            guard remaining > 0 else { return Data() }
            let count = Int(min(remaining, UInt64(block.count)))
            remaining -= UInt64(count)
            return count == block.count ? block : Data(block.prefix(count))
        }
        try zip.finish()
    } else if mode == "paths" {
        for path in ["../escape", "/absolute", "a/../b", "a\\b", "a//b", "C:/file"] {
            do { try CompleteDataArchive.validateName(path); fatalError("Unsafe path accepted") }
            catch {}
        }
        let zip = try StreamingZIP64(output)
        var pending = Data("123456789".utf8)
        try zip.add(name: "unicode/собака.bin", size: 9) { defer { pending = Data() }; return pending }
        do { try zip.add(name: "unicode/собака.bin", size: 0) { Data() }; fatalError("Duplicate name accepted") }
        catch {}
        try zip.finish()
    } else {
        var calls = 0
        _ = try exporter.create(in: output, checkCancelled: {
            calls += 1
            if mode == "cancel" && calls > 4 { throw CancellationError() }
        }, onProgress: { progress in
            if mode == "mutate-file" && progress.completedBytes > 0 {
                try? Data("changed".utf8).write(to: root.appendingPathComponent("new.bin"))
            }
            if mode == "mutate-db" && progress.completedBytes > 0 && calls < 100_000 {
                calls = 100_000
                var connection: OpaquePointer?
                sqlite3_open(root.appendingPathComponent("woona.sqlite").path, &connection)
                sqlite3_exec(connection, "INSERT INTO history(value) VALUES ('concurrent change')", nil, nil, nil)
                sqlite3_close(connection)
            }
        })
    }
    print("OK")
} catch is CancellationError { print("FAILED: CancellationError"); exit(3) }
catch { print("FAILED: \(error.localizedDescription)"); exit(3) }
'''


class CompleteArchiveCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin" or not shutil.which("swiftc"):
            raise unittest.SkipTest("Requires macOS Swift; Linux checks cannot verify iOS code")
        cls.compiled = tempfile.TemporaryDirectory(prefix="woona-zip-compat-")
        base = Path(cls.compiled.name)
        (base / "main.swift").write_text(MAIN)
        source = Path(__file__).resolve().parents[1] / "Woona/Storage/CompleteDataArchive.swift"
        cls.binary = base / "exporter"
        subprocess.run(["swiftc", "-O", str(source), str(base / "main.swift"), "-lsqlite3", "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "compiled"):
            cls.compiled.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="woona-export-test-")
        self.base = Path(self.directory.name)
        self.root = self.base / "Woona"
        self.root.mkdir()
        self.db = sqlite3.connect(self.root / "woona.sqlite")
        self.db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE recordings(id TEXT PRIMARY KEY, status TEXT);
        CREATE TABLE artifacts(id TEXT,recording_id TEXT,relative_path TEXT,size_bytes INTEGER,sha256 TEXT);
        CREATE TABLE history(value TEXT);
        INSERT INTO history VALUES ('historical version');
        INSERT INTO recordings VALUES ('old-session','completed');
        INSERT INTO artifacts VALUES ('missing','old-session','recordings/server-only.mp4',999,'not-local');
        """)
        self.db.commit()

    def tearDown(self):
        self.db.close()
        self.directory.cleanup()

    def run_export(self, mode="normal", success=True, reason=None):
        result = subprocess.run([str(self.binary), mode, str(self.base)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if success else 3, result.stdout + result.stderr)
        if reason is not None:
            self.assertIn(reason, result.stdout + result.stderr)
        if not success:
            self.assertFalse((self.base / "out.zip").exists())
            self.assertFalse((self.base / "out.zip.part").exists())
        return result.stdout

    def test_full_archive_and_wal_snapshot_are_readable_by_standard_tools(self):
        folder = self.root / "recordings/собака"
        folder.mkdir(parents=True)
        payload = bytes(range(251)) * 1000
        (folder / "video.mp4.part").write_bytes(payload)
        (self.root / "ble_dump_old.bin").write_bytes(b"old")
        (self.root / "reference-ECG: 100%.csv").write_bytes(b"reference")
        self.run_export()
        with zipfile.ZipFile(self.base / "out.zip") as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {
                "manifest.json", "data/Woona/woona.sqlite", "data/Woona/ble_dump_old.bin",
                "data/Woona/reference-ECG%3A 100%25.csv", "data/Woona/recordings/собака/video.mp4.part",
            })
            self.assertEqual(archive.read("data/Woona/reference-ECG%3A 100%25.csv"), b"reference")
            self.assertEqual(archive.read("data/Woona/recordings/собака/video.mp4.part"), payload)
            manifest = json.loads(archive.read("manifest.json"))
            self.assertEqual(manifest["database"]["counts"]["history"], 1)
            self.assertEqual(manifest["database"]["unavailableLocalArtifactCount"], 1)
            self.assertEqual(manifest["database"]["unavailableLocalArtifacts"][0]["recordingId"], "old-session")
            entry = next(f for f in manifest["files"] if f["path"].endswith("video.mp4.part"))
            self.assertEqual(entry["sha256"], hashlib.sha256(payload).hexdigest())
            snapshot = self.base / "readback.sqlite"
            snapshot.write_bytes(archive.read("data/Woona/woona.sqlite"))
            with sqlite3.connect(snapshot) as db:
                self.assertEqual(db.execute("PRAGMA quick_check").fetchone()[0], "ok")
                self.assertEqual(db.execute("SELECT value FROM history").fetchone()[0], "historical version")
        self.assertTrue((folder / "video.mp4.part").exists())

    def test_zip64_handles_more_than_65535_entries(self):
        self.run_export("entry-count")
        with zipfile.ZipFile(self.base / "out.zip") as archive:
            self.assertEqual(len(archive.infolist()), 65_537)
            self.assertEqual(archive.read("file-65536.bin"), b"")

    def test_path_traversal_duplicates_unicode_and_known_crc(self):
        self.run_export("paths")
        with zipfile.ZipFile(self.base / "out.zip") as archive:
            self.assertEqual(archive.read("unicode/собака.bin"), b"123456789")
            self.assertEqual(archive.infolist()[0].CRC, 0xCBF43926)
            self.assertEqual(archive.infolist()[0].extract_version, 45)

    def test_cancellation_removes_partial_and_preserves_sources(self):
        (self.root / "video.mp4").write_bytes(b"v" * 2_000_000)
        self.run_export("cancel", success=False, reason="CancellationError")
        self.assertEqual((self.root / "video.mp4").stat().st_size, 2_000_000)

    def test_concurrent_files_fail_instead_of_publishing_partial_history(self):
        self.run_export("mutate-file", success=False, reason="Files changed during export")

    def test_database_change_after_snapshot_fails(self):
        self.run_export("mutate-db", success=False, reason="Local database changed during export")

    def test_symlink_cannot_escape_export_roots(self):
        (self.root / "unsafe").symlink_to(self.base / "outside")
        (self.base / "outside").write_text("secret outside data root")
        self.run_export(success=False, reason="Symbolic link")

    @unittest.skipIf(os.environ.get("WOONA_SKIP_ZIP64_LARGE") == "1", "Ordinary CI explicitly omitted the 4+ GiB streaming fixture")
    def test_file_larger_than_4_gib_is_readable(self):
        self.run_export("large-file")
        with zipfile.ZipFile(self.base / "out.zip") as archive:
            self.assertEqual(archive.getinfo("large-video.mp4").file_size, 4_294_967_296 + 65_537)
            count = 0
            with archive.open("large-video.mp4") as stream:
                while chunk := stream.read(1_048_576):
                    self.assertEqual(chunk, b"Z" * len(chunk))
                    count += len(chunk)
            self.assertEqual(count, 4_294_967_296 + 65_537)

    def test_insufficient_space_preserves_sources_without_creating_partial_archive(self):
        source = self.root / "large-video.mp4"
        size = 2 * 1024 ** 4
        with source.open("wb") as stream:
            stream.truncate(size)  # Sparse file: no large disk allocation or copy.
        self.run_export(success=False, reason="Not enough free space")
        self.assertEqual(source.stat().st_size, size)

    def test_unfinalized_history_from_previous_crash_is_exportable_and_explicit(self):
        self.db.execute("UPDATE recordings SET status='recording'")
        self.db.commit()
        self.run_export()
        with zipfile.ZipFile(self.base / "out.zip") as archive:
            metadata = json.loads(archive.read("manifest.json"))["database"]
            self.assertEqual(metadata["unfinalizedRecordingCount"], 1)
            self.assertEqual(metadata["unfinalizedRecordings"][0]["savedStatus"], "recording")


if __name__ == "__main__":
    unittest.main(verbosity=2)
