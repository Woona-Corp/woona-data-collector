"""Offline SDK setup regression tests; all effects stay in a temporary workspace."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("setup-android-sdk.sh")
CHECKSUM = "4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583"
BASE_PACKAGES = [
    "platform-tools", "platforms;android-36.1",
    "build-tools;36.0.0", "build-tools;36.1.0",
]
FULL_PACKAGES = BASE_PACKAGES + [
    "emulator", "system-images;android-31;google_apis;x86_64",
]


class SetupAndroidSdkTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sdk-setup-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.android = self.root / "android"
        tools = self.android / "tools"
        tools.mkdir(parents=True)
        self.script = tools / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        self.sdk = self.root / "sdk with spaces"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = dict(os.environ, ANDROID_SDK_ROOT=str(self.sdk),
                        ANDROID_HOME=str(self.root / "unused-sdk"),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        CALL_LOG=str(self.log), TMPDIR=str(self.root))
        # These mocks fail closed: even an unexpected bootstrap cannot use network.
        self.mock("curl", "raise SystemExit('unexpected download')")
        self.mock("unzip", "raise SystemExit('unexpected extraction')")

    def mock(self, name, body):
        path = self.bin / name
        path.write_text(
            "#!/usr/bin/env python3\nimport json, os, pathlib, sys\n"
            "with open(os.environ['CALL_LOG'], 'a') as log:\n"
            "    log.write(json.dumps([pathlib.Path(sys.argv[0]).name] + sys.argv[1:]) + '\\n')\n"
            + body + "\n"
        )
        path.chmod(0o755)
        return path

    def manager(self):
        path = self.sdk / "cmdline-tools/latest/bin/sdkmanager"
        path.parent.mkdir(parents=True)
        shutil.copyfile(self.mock("sdkmanager", "pass"), path)
        path.chmod(0o755)

    def run_setup(self, *args):
        return subprocess.run(["bash", str(self.script), *args], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_exact_packages_and_default(self):
        self.manager()
        for args, packages in [((), FULL_PACKAGES), (("full",), FULL_PACKAGES),
                               (("fast",), BASE_PACKAGES)]:
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                result = self.run_setup(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.calls(), [
                    ["sdkmanager", f"--sdk_root={self.sdk}", "--licenses"],
                    ["sdkmanager", f"--sdk_root={self.sdk}", *packages],
                ])
                self.assertEqual((self.android / "local.properties").read_text(),
                                 f"sdk.dir={self.sdk}\n")

    def test_invalid_arguments_have_no_effects(self):
        for args in [("invalid",), ("",), ("fast", "extra")]:
            with self.subTest(args=args):
                result = self.run_setup(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("Usage:", result.stderr)
                self.assertFalse(self.sdk.exists())
                self.assertFalse(self.log.exists())
                self.assertFalse((self.android / "local.properties").exists())
        # Also preserve existing configuration/tools when rejecting input.
        self.manager()
        properties = self.android / "local.properties"
        properties.write_text("existing configuration\n")
        before = {p.relative_to(self.root): p.read_bytes()
                  for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(self.run_setup("invalid").returncode, 2)
        after = {p.relative_to(self.root): p.read_bytes()
                 for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def bootstrap_download(self):
        self.mock("curl", "pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(b'not a real SDK')")

    def test_real_checksum_mismatch_stops_before_extraction(self):
        self.bootstrap_download()
        result = self.run_setup("fast")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAILED", result.stdout)
        self.assertEqual([call[0] for call in self.calls()], ["curl"])
        self.assertFalse(self.sdk.exists())
        self.assertFalse((self.android / "local.properties").exists())
        self.assertFalse(list(self.root.glob("tmp.*")))

    def test_bootstrap_checksum_contract_and_order(self):
        self.bootstrap_download()
        # Simulate a verified archive, asserting the original pinned digest and -c.
        self.mock("sha256sum", f"""assert sys.argv[1:] == ['-c', '-']
line = sys.stdin.read()
digest, archive = line.strip().split('  ', 1)
assert digest == {CHECKSUM!r}
assert pathlib.Path(archive).read_bytes() == b'not a real SDK'
""")
        manager = self.mock("sdkmanager", "pass")
        self.mock("unzip", f"""import shutil
assert sys.argv[1] == '-q'
destination = pathlib.Path(sys.argv[sys.argv.index('-d') + 1]) / 'cmdline-tools/bin'
destination.mkdir(parents=True)
shutil.copy2({str(manager)!r}, destination / 'sdkmanager')
""")
        result = self.run_setup("fast")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call[0] for call in calls],
                         ["curl", "sha256sum", "unzip", "sdkmanager", "sdkmanager"])
        self.assertEqual(calls[0][-1],
                         "https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip")
        self.assertEqual(calls[-1][2:], BASE_PACKAGES)
        self.assertFalse(list(self.root.glob("tmp.*")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
