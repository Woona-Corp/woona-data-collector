"""Offline dependency/image regressions; deliberately separate from runtime tests."""
from pathlib import Path
import tempfile
import unittest

from server.check_dependency_lock import ROOT, parse_lock, validate, validate_compose


class DependencyLockTests(unittest.TestCase):
    def test_checked_in_contract(self):
        validate()

    def test_compose_digest_or_production_target_drift_is_rejected(self):
        if not (ROOT.parent / 'compose.yaml').is_file():
            self.skipTest('Compose contracts run before image build, not in the runtime image')
        for filename, old, new in (
                ('compose.yaml', 'postgres:18@sha256:', 'postgres:18 # sha256:'),
                ('compose.production.yaml', 'target: verified', 'target: runtime'),
                ('compose.label.yaml', 'target: verified', 'target: runtime')):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as temporary:
                shared = Path(temporary)
                for name in ('compose.yaml', 'compose.production.yaml', 'compose.label.yaml'):
                    content = (ROOT.parent / name).read_text()
                    (shared / name).write_text(content.replace(old, new) if name == filename else content)
                with self.assertRaises(ValueError):
                    validate_compose(shared)

    def test_rejects_unhashed_unpinned_or_external_requirements(self):
        for text in ("fastapi==0.143.0", "fastapi>=0.143.0", "-r other.lock", "--index-url https://example.org", "foo @ https://example.org/foo.whl", ""):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_lock(text)

    def test_rejects_duplicate_package(self):
        pin = "typing_extensions==4.16.0 --hash=sha256:" + "a" * 64
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            parse_lock(pin + "\n" + pin.replace("typing_extensions", "typing-extensions"))

    def test_verified_stage_cannot_silently_lose_gates(self):
        for fragment in ('--expected-source-id "$WOONA_SOURCE_ID"', 'test "$(id -u)" = 10001',
                         '--manifest /app/deployment-source-manifest.json --uid 10001',
                         'FROM runtime-base AS runtime'):
            with self.subTest(fragment=fragment), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for source in ("pyproject.toml", "requirements.lock", "requirements-test.lock", "Dockerfile"):
                    text = (ROOT / source).read_text()
                    (root / source).write_text(text.replace(fragment, "REMOVED") if source == "Dockerfile" else text)
                with self.assertRaises(ValueError):
                    validate(root)

    def test_ci_and_context_integration(self):
        shared = ROOT.parent
        workflow_path = shared.parent / ".github/workflows/mobile.yml"
        if not workflow_path.is_file():
            self.skipTest("CI/context contracts run in source checkout; not copied to runtime image")
        validate_compose()
        workflow = workflow_path.read_text()
        server = workflow.split("\n  server:\n", 1)[1].split("\n  release:\n", 1)[0]
        for fragment in ("WOONA_BUILD_TARGET: verified", "git status --porcelain --untracked-files=all",
                         "git rev-parse --verify HEAD", "--schema-revision 0009", "get_heads() == [\"0009\"]",
                         "uid = os.getuid()", "verify_tree(\"/app\", manifest, uid, sys.argv[1])",
                         "--require-hashes --only-binary=:all:", "-r /app/server/requirements-test.lock",
                         "docker image save \"$WOONA_CANDIDATE_IMAGE\"", "--no-build --wait",
                         "github.event_name == 'workflow_dispatch' && inputs.export_server_image == true",
                         "inputs.scope == 'server' || inputs.scope == 'all'", "retention-days: 1"):
            self.assertIn(fragment, server)
        self.assertNotIn("pip install -e", server)
        self.assertIn("!build-provenance/source-manifest.json", (shared / ".dockerignore").read_text())
        self.assertIn("shared/build-provenance/", (shared.parent / ".gitignore").read_text())
        compose = (shared / "compose.yaml").read_text()
        self.assertIn("target: ${WOONA_BUILD_TARGET:-runtime}", compose)
        self.assertIn("WOONA_SOURCE_ID: ${WOONA_SOURCE_ID:-}", compose)

    def test_detects_direct_and_test_lock_drift(self):
        for name, old, new in (("requirements.lock", "fastapi==0.143.0", "fastapi==0.142.0"), ("requirements-test.lock", "psycopg-binary==3.2.9", "psycopg-binary==3.2.8")):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for source in ("pyproject.toml", "requirements.lock", "requirements-test.lock", "Dockerfile"):
                    text = (ROOT / source).read_text()
                    (root / source).write_text(text.replace(old, new) if source == name else text)
                with self.assertRaisesRegex(ValueError, "drift"):
                    validate(root)


if __name__ == "__main__":
    unittest.main()
