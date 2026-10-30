"""Hermetic stdlib tests: no app imports, database, Docker, network or production paths."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

# Load only the owned standalone tool, independent of app import paths/dependencies.
TOOL = Path(__file__).resolve().parents[1] / "deployment_provenance.py"
_spec = importlib.util.spec_from_file_location("deployment_provenance", TOOL)
if _spec is None or _spec.loader is None:
    raise RuntimeError("standalone provenance tool unavailable")
provenance = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(provenance)


class DeploymentProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "public"
        self.root.mkdir(mode=0o755)
        self.inputs = ["server/app.py", "docs/target-server-plan/models/model.json", "testdata/vector.json"]
        for path in self.inputs:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("synthetic public input\n", encoding="utf-8")
            target.chmod(0o644)
        self.source = "a" * 40
        self.image = "sha256:" + "b" * 64
        self.manifest = self.create()

    def create(self):
        return provenance.create_manifest(self.root, self.inputs, self.source, "0009")

    def observation(self):
        return {"image_digest": self.image, "source_id": self.source,
                "manifest_sha256": provenance.manifest_id(self.manifest),
                "schema_revision": "0009", "uid": 10001}

    def test_deterministic_round_trip(self):
        other = provenance.create_manifest(self.root, list(reversed(self.inputs)), self.source, "0009")
        self.assertEqual(provenance.canonical(other), provenance.canonical(self.manifest))
        self.assertEqual(provenance.verify_tree(self.root, self.manifest, 10001),
                         provenance.manifest_id(self.manifest))
        provenance.compare_observation(self.manifest, self.observation(), self.source, self.image)

    def test_expected_source_checked_before_hashing(self):
        for source in ("b" * 40, "", "main", "A" * 40):
            with self.subTest(source=source), patch.object(provenance, "hash_file", side_effect=AssertionError("must not hash")):
                with self.assertRaises(provenance.Rejected):
                    provenance.verify_tree(self.root, self.manifest, expected_source_id=source)
        self.assertEqual(provenance.verify_tree(self.root, self.manifest, expected_source_id=self.source),
                         provenance.manifest_id(self.manifest))

    def test_all_current_tracked_copy_names_are_supported(self):
        # Names only: dirty operational files must never be opened for this test.
        shared = TOOL.parents[1]
        if not (shared.parent / ".git").exists():
            self.skipTest("tracked-name check runs in the source checkout, not the runtime image")
        result = subprocess.run(["git", "ls-files", "-z", "--", *provenance.SCOPES],
                                cwd=shared, check=True, capture_output=True)
        paths = [p.decode("utf-8") for p in result.stdout.split(b"\0") if p]
        self.assertGreaterEqual(len(paths), 78)
        for path in paths:
            with self.subTest(path=path):
                provenance.public_path(path)

    def test_changed_bytes_same_size_rejected(self):
        (self.root / self.inputs[0]).write_text("X" * self.manifest["files"][self.inputs[0]]["size"])
        with self.assertRaisesRegex(provenance.Rejected, "hash/size"):
            provenance.verify_tree(self.root, self.manifest)

    def test_missing_input(self):
        (self.root / self.inputs[0]).unlink()
        with self.assertRaises(provenance.Rejected):
            provenance.verify_tree(self.root, self.manifest)

    def test_extra_public_input_never_hashed(self):
        (self.root / "server/extra.py").write_text("not reviewed")
        with patch.object(provenance, "hash_file", side_effect=AssertionError("must not hash")):
            with self.assertRaises(provenance.Rejected):
                provenance.verify_tree(self.root, self.manifest)
            with self.assertRaises(provenance.Rejected):
                self.create()

    def test_sensitive_or_unsupported_input_never_hashed(self):
        for name in (".env", "private.db", "capture.bin", "credentials", "storage"):
            with self.subTest(name=name):
                path = self.root / "server" / name
                if name in {"credentials", "storage"}:
                    path.mkdir()
                else:
                    path.write_text("synthetic secret must not be read")
                with patch.object(provenance, "hash_file", side_effect=AssertionError("must not hash")):
                    with self.assertRaises(provenance.Rejected):
                        provenance.verify_tree(self.root, self.manifest)
                if path.is_dir():
                    path.rmdir()
                else:
                    path.unlink()

    def test_outside_scopes_not_opened(self):
        (self.root / ".env").write_text("synthetic secret")
        (self.root / "data").mkdir()
        (self.root / "data/private.db").write_text("synthetic data")
        provenance.verify_tree(self.root, self.manifest)

    def test_symlinks_files_directories_and_root_rejected(self):
        for directory in (False, True):
            with self.subTest(directory=directory):
                link = self.root / "server/link.py"
                link.symlink_to(self.root / ("testdata" if directory else self.inputs[0]), target_is_directory=directory)
                with self.assertRaises(provenance.Rejected):
                    provenance.verify_tree(self.root, self.manifest)
                link.unlink()
        alias = self.root.parent / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            provenance.verify_tree(alias, self.manifest)
        # Intermediate symlink must also fail, not only the terminal root.
        with self.assertRaises(OSError):
            provenance.verify_tree(alias / "server", self.manifest)

    def test_fifo_not_opened(self):
        os.mkfifo(self.root / "server/pipe.py")
        with self.assertRaises(provenance.Rejected):
            provenance.verify_tree(self.root, self.manifest)

    def test_bytecode_directory_explicitly_excluded_but_symlink_rejected(self):
        cache = self.root / "server/__pycache__"
        cache.mkdir()
        (cache / "app.pyc").write_bytes(b"synthetic")
        provenance.verify_tree(self.root, self.manifest)
        (cache / "app.pyc").unlink()
        cache.rmdir()
        cache.symlink_to(self.root / "testdata", target_is_directory=True)
        with self.assertRaises(provenance.Rejected):
            provenance.verify_tree(self.root, self.manifest)

    def test_uid_and_directory_readability(self):
        target = self.root / self.inputs[0]
        target.chmod(0o600)
        provenance.verify_tree(self.root, self.manifest)  # bytes independent of modes
        with self.assertRaises(provenance.Rejected):
            provenance.verify_tree(self.root, self.manifest, os.getuid() + 12345)
        target.chmod(0o644)
        parent = self.root / "docs"
        parent.chmod(0o700)
        try:
            with self.assertRaises(provenance.Rejected):
                provenance.verify_tree(self.root, self.manifest, os.getuid() + 12345)
        finally:
            parent.chmod(0o755)
        with self.assertRaises(provenance.Rejected):
            provenance.verify_tree(self.root, self.manifest, 0)

    def test_each_observed_identity_mismatch(self):
        changes = {"image_digest": "sha256:" + "c" * 64, "source_id": "d" * 40,
                   "manifest_sha256": "0" * 64, "schema_revision": "0010", "uid": 0}
        for field, value in changes.items():
            with self.subTest(field=field):
                observed = self.observation()
                observed[field] = value
                with self.assertRaises(provenance.Rejected):
                    provenance.compare_observation(self.manifest, observed, self.source, self.image)
        with self.assertRaises(provenance.Rejected):
            provenance.compare_observation(self.manifest, self.observation(), "e" * 40, self.image)
        with self.assertRaises(provenance.Rejected):
            provenance.compare_observation(self.manifest, self.observation(), self.source, "latest")

    def test_strict_manifest_validation(self):
        invalid = []
        for field, value in (("format", True), ("format", 2), ("source_id", "main"),
                             ("schema_revision", ""), ("files", {})):
            manifest = copy.deepcopy(self.manifest)
            manifest[field] = value
            invalid.append(manifest)
        for path in ("../server/app.py", "/server/app.py", "server/../app.py", "server//app.py",
                     "server/.env", "server/credentials/key.json", "data/vector.json", "server/x.bin"):
            manifest = copy.deepcopy(self.manifest)
            manifest["files"][path] = {"sha256": "0" * 64, "size": 0}
            invalid.append(manifest)
        for entry in ({"sha256": "oops", "size": 0}, {"sha256": "0" * 64, "size": True},
                      {"sha256": "0" * 64, "size": -1}, {"sha256": "0" * 64, "size": 0, "extra": 1}):
            manifest = copy.deepcopy(self.manifest)
            manifest["files"][self.inputs[0]] = entry
            invalid.append(manifest)
        for manifest in invalid:
            with self.subTest(manifest=manifest):
                with self.assertRaises(provenance.Rejected):
                    provenance.validate_manifest(manifest)

    def test_duplicate_json_keys(self):
        evidence = self.root.parent / "duplicate.json"
        evidence.write_text('{"format":1,"format":1}')
        with self.assertRaises(provenance.Rejected):
            provenance.load_json(evidence)

    def test_evidence_symlink_fifo_and_non_json_rejected(self):
        target = self.root.parent / "evidence.json"
        target.write_text("{}")
        alias = self.root.parent / "alias.json"
        alias.symlink_to(target)
        with self.assertRaises(OSError):
            provenance.load_json(alias)
        alias.unlink()
        os.mkfifo(alias)
        with self.assertRaises(provenance.Rejected):
            provenance.load_json(alias)
        with self.assertRaises(provenance.Rejected):
            provenance.load_json(self.root / ".env")
        with self.assertRaises(provenance.Rejected):
            provenance.load_json(self.root / "../evidence.json")

    def test_missing_observation_field(self):
        observed = self.observation()
        del observed["source_id"]
        with self.assertRaises(provenance.Rejected):
            provenance.compare_observation(self.manifest, observed, self.source, self.image)

    def test_duplicate_reviewed_input(self):
        with self.assertRaises(provenance.Rejected):
            provenance.create_manifest(self.root, self.inputs * 2, self.source, "0009")

    def test_cli_failure_does_not_echo_sensitive_content(self):
        evidence = self.root.parent / "manifest.json"
        evidence.write_text("synthetic-do-not-echo")
        result = subprocess.run([sys.executable, "-B", str(TOOL), "verify", "--root", str(self.root),
                                 "--manifest", str(evidence)], capture_output=True, text=True, check=False, env={})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("synthetic-do-not-echo", result.stderr)
        self.assertNotIn(str(evidence), result.stderr)

    def test_cli_rejects_wrong_or_missing_build_source(self):
        evidence = self.root.parent / "manifest.json"
        evidence.write_bytes(provenance.canonical(self.manifest))
        for source in ("", "b" * 40):
            result = subprocess.run([sys.executable, "-B", str(TOOL), "verify", "--root", str(self.root),
                                     "--manifest", str(evidence), "--expected-source-id", source],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")

    def test_cli_success(self):
        evidence = self.root.parent / "manifest.json"
        evidence.write_bytes(provenance.canonical(self.manifest))
        result = subprocess.run([sys.executable, "-B", str(TOOL), "verify", "--root", str(self.root),
                                 "--manifest", str(evidence), "--uid", "10001", "--expected-source-id", self.source],
                                capture_output=True, text=True, check=False, env={})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "manifest_sha256": provenance.manifest_id(self.manifest)})


if __name__ == "__main__":
    unittest.main()
