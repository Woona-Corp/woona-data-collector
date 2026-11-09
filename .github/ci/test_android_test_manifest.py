"""Hermetic Android signing gate tests; synthetic JUnit, never an emulator."""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from android_test_manifest import ALLOWED_INSTRUMENTATION_SKIPS, verify

SOURCE = "a" * 40
PATHS = {
    "jvm": "test-results/testDebugUnitTest/TEST-unit.xml",
    "instrumentation": "outputs/androidTest-results/managedDevice/debug/woonaApi31/TEST-device.xml",
}


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.build = Path(self.temporary.name)

    def report(self, group="jvm", cases=(("Unit#passes", "passed"),), name=None):
        root = ET.Element(
            "testsuite",
            tests=str(len(cases)),
            failures=str(sum(status == "failure" for _, status in cases)),
            errors=str(sum(status == "error" for _, status in cases)),
            skipped=str(sum(status == "skipped" for _, status in cases)),
        )
        for identity, status in cases:
            classname, method = identity.split("#", 1)
            case = ET.SubElement(root, "testcase", classname=classname, name=method)
            if status != "passed":
                ET.SubElement(case, status)
        path = self.build / PATHS[group]
        if name:
            path = path.with_name(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(ET.tostring(root))
        return path

    def check(self, mode="fast"):
        return verify(self.build, mode, SOURCE, "123", "2")

    def test_fast_records_actual_identities_counts_and_report_digest(self):
        path = self.report(
            cases=(("Unit#one", "passed"), ("Unit#two[parameter]", "passed"))
        )
        manifest = self.check()
        self.assertTrue(manifest["verified"], manifest["errors"])
        self.assertEqual(
            (
                manifest["mode"],
                manifest["source"],
                manifest["run_id"],
                manifest["run_attempt"],
            ),
            ("fast", SOURCE, "123", "2"),
        )
        unit = manifest["suites"]["jvm"]
        self.assertEqual(
            unit["cases"], {"Unit#one": "passed", "Unit#two[parameter]": "passed"}
        )
        self.assertEqual(
            unit["counts"],
            {"total": 2, "passed": 2, "failures": 0, "errors": 0, "skipped": 0},
        )
        self.assertEqual(
            unit["reports"],
            [
                {
                    "path": PATHS["jvm"],
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
            ],
        )

    def test_full_accepts_only_reviewed_opt_in_skip_identities(self):
        self.report()
        self.report(
            "instrumentation",
            tuple((identity, "skipped") for identity in ALLOWED_INSTRUMENTATION_SKIPS)
            + (("Device#passes", "passed"),),
        )
        manifest = self.check("full")
        self.assertTrue(manifest["verified"], manifest["errors"])
        counts = manifest["suites"]["instrumentation"]["counts"]
        self.assertEqual(counts["skipped"], len(ALLOWED_INSTRUMENTATION_SKIPS))
        self.assertEqual(counts["passed"], 1)

    def test_opt_in_tests_may_pass_instead_of_skipping(self):
        self.report()
        self.report(
            "instrumentation",
            tuple((identity, "passed") for identity in ALLOWED_INSTRUMENTATION_SKIPS),
        )
        self.assertTrue(self.check("full")["verified"])

    def test_missing_reports_and_empty_reports_fail(self):
        self.assertFalse(self.check()["verified"])
        self.report()
        self.assertFalse(self.check("full")["verified"])
        self.report(cases=())
        self.assertFalse(self.check()["verified"])
        self.report()
        self.report("instrumentation", ())
        self.assertFalse(self.check("full")["verified"])

    def test_jvm_skips_even_reviewed_instrumentation_identity_fail(self):
        for identity in ("Unit#skip", next(iter(ALLOWED_INSTRUMENTATION_SKIPS))):
            with self.subTest(identity=identity):
                self.report(cases=((identity, "skipped"),))
                self.assertFalse(self.check()["verified"])

    def test_unexpected_instrumentation_skip_fails(self):
        self.report()
        self.report("instrumentation", (("Device#newSkip", "skipped"),))
        self.assertFalse(self.check("full")["verified"])

    def test_failures_and_errors_fail_in_either_group(self):
        for group in PATHS:
            for status in ("failure", "error"):
                with self.subTest(group=group, status=status):
                    self.report()
                    self.report("instrumentation")
                    self.report(group, (("Case#bad", status),))
                    manifest = self.check("full")
                    self.assertFalse(manifest["verified"])
                    self.assertEqual(
                        manifest["suites"][group]["counts"][status + "s"], 1
                    )

    def test_duplicates_within_and_between_reports_fail(self):
        self.report(cases=(("Unit#duplicate", "passed"), ("Unit#duplicate", "passed")))
        self.assertFalse(self.check()["verified"])
        self.report()
        self.report(name="TEST-duplicate.xml")
        self.assertFalse(self.check()["verified"])

    def test_malformed_xml_counter_lies_missing_ids_and_ambiguous_status_fail(self):
        values = (
            b"<broken",
            b"<other/>",
            b'<testsuite tests="1"><testcase name="missingClass"/></testsuite>',
            b'<testsuite tests="2"><testcase classname="A" name="one"/></testsuite>',
            b'<testsuite tests="one"><testcase classname="A" name="one"/></testsuite>',
            b'<testsuite tests="1" skipped="1"><testcase classname="A" name="one"><skipped/><error/></testcase></testsuite>',
            b'<!DOCTYPE testsuite [<!ENTITY example "value">]><testsuite tests="0"/>',
            b'<testsuite tests="1"><failure/><testcase classname="A" name="one"/></testsuite>',
            b'<testsuite tests="1" skipped="1"><testcase classname="A" name="one"><skipped/><skipped/></testcase></testsuite>',
            b"\xff",
        )
        for value in values:
            with self.subTest(value=value):
                path = self.report()
                path.write_bytes(value)
                self.assertFalse(self.check()["verified"])

    def test_fast_rejects_stale_instrumentation(self):
        self.report()
        self.report("instrumentation")
        self.assertFalse(self.check()["verified"])

    def test_invalid_mode_source_and_run_binding_fail(self):
        self.report()
        for mode, source, run, attempt in (
            ("other", SOURCE, "1", "1"),
            ("fast", "bad", "1", "1"),
            ("fast", SOURCE, "", "1"),
            ("fast", SOURCE, "1", "0"),
        ):
            self.assertFalse(verify(self.build, mode, source, run, attempt)["verified"])

    def test_cli_writes_manifest_on_failure_and_blocks_signing(self):
        output = self.build / "proof/manifest.json"
        command = [
            sys.executable,
            str(Path(__file__).with_name("android_test_manifest.py")),
            "--build",
            str(self.build),
            "--mode",
            "fast",
            "--source",
            SOURCE,
            "--run-id",
            "123",
            "--attempt",
            "2",
            "--output",
            str(output),
        ]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(output.read_text())["verified"])
        self.report()
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(output.read_text())["verified"])

    def test_workflow_verifies_before_secrets_and_copies_proof_to_apk_artifact(self):
        workflow = (
            Path(__file__).resolve().parents[1] / "workflows/mobile.yml"
        ).read_text()
        gate = workflow.index("python3 .github/ci/android_test_manifest.py")
        signing = workflow.index(
            "KEYSTORE_BASE64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}"
        )
        self.assertLess(gate, signing)
        self.assertIn("android/app/build/ci-verification/", workflow)
        self.assertIn(
            "cp android/app/build/ci-verification/android-tests.json release-assets/",
            workflow,
        )
        self.assertIn(
            "ANDROID_MODE: ${{ needs.changes.outputs.android_mode }}", workflow
        )


if __name__ == "__main__":
    unittest.main()
