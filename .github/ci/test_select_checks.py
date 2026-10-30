"""Hermetic policy, Git and ZIP64 gate tests; no SDK, network or third-party modules."""
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from select_checks import ALL, changed_paths, decision

ROOT = Path(__file__).resolve().parents[2]
BASE, HEAD, MERGE = "a" * 40, "b" * 40, "c" * 40


class PolicyTests(unittest.TestCase):
    def assert_selection(self, selected, jobs, large):
        self.assertEqual({job for job in ALL if selected[job]}, set(jobs))
        self.assertEqual(selected["zip64_large"], large)

    def test_changed_path_table_for_main_and_pull_requests(self):
        cases = [
            (["android/app/src/Main.kt"], {"android"}, False),
            (["ios/Woona/AppShell/AppShell.swift"], {"ios"}, False),
            (["shared/server/app.py", "shared/server/Dockerfile"], {"server"}, False),
            (["android/tools/check.sh", "ios/Woona/BLE/Manager.swift"], {"android", "ios"}, False),
            (["ios/Woona/Storage/CompleteDataArchive.swift"], {"ios"}, True),
            (["ios/Woona/Storage/Other.swift"], {"ios"}, True),
            (["ios/Woona/Data/Store.swift"], {"ios"}, True),
            (["ios/WoonaTests/StorageTests/CompleteDataArchiveTests.swift"], {"ios"}, True),
            (["ios/tools/test_complete_archive.py"], {"ios"}, True),
            (["ios/Woona.xcodeproj/project.pbxproj"], {"ios"}, True),
            (["shared/testdata/packet.bin"], ALL, True),
            (["shared/test-fixtures/questionnaire.json"], ALL, True),
            (["shared/UI_UX_CONTRACT.md"], ALL, True),
            (["shared/docs/target-server-plan/models/sqlite.sql"], ALL, True),
            (["shared/compose.yaml"], ALL, True),
            (["shared/tools/check_questionnaire_presentation.py"], ALL, True),
            ([".github/workflows/mobile.yml"], ALL, True),
            ([".github/workflows/testflight.yml"], ALL, True),
            ([".github/ci/select_checks.py"], ALL, True),
            (["README.md"], ALL, True),
            (["new-platform/code"], ALL, True),
            (["android/a", "unknown"], ALL, True),
            (["ios/a", "../android/a"], ALL, True),
            (["/android/a"], ALL, True),
            (["android/../ios/a"], ALL, True),
            (["ios\\a"], ALL, True),
            (None, ALL, True),
            ([], ALL, True),
        ]
        for event, ref in (("push", "refs/heads/main"), ("pull_request", "refs/pull/10/merge")):
            for paths, jobs, large in cases:
                with self.subTest(event=event, paths=paths):
                    self.assert_selection(decision(event, ref, paths), jobs, large)

    def test_tags_and_manual_do_not_use_path_optimization(self):
        for paths in (None, [], ["ios/Woona/AppShell/A.swift"]):
            self.assert_selection(decision("push", "refs/tags/android-v2", paths), {"android", "server"}, True)
            self.assert_selection(decision("push", "refs/tags/ios-v2", paths), ALL, True)
            for scope in ("all", "android", "ios", "server", "invalid"):
                with self.subTest(paths=paths, scope=scope):
                    self.assert_selection(decision("workflow_dispatch", "refs/heads/main", paths, scope),
                                          {scope} if scope in ALL else ALL, True)
        self.assert_selection(decision("schedule", "refs/heads/main", ["android/a"]), ALL, True)


class DiffTests(unittest.TestCase):
    def event(self, event):
        return ({"before": BASE, "after": HEAD} if event == "push" else
                {"pull_request": {"base": {"sha": BASE}, "head": {"sha": HEAD}}})

    def test_push_exact_endpoints_and_pr_merge_base(self):
        for event in ("push", "pull_request"):
            calls = []
            def run(*args):
                calls.append(args)
                if args[0] == "merge-base":
                    return (MERGE + "\n").encode()
                return b"ios/new name.swift\0android/deleted.kt\0" if args[0] == "diff" else b""
            self.assertEqual(changed_paths(event, self.event(event), run),
                             ["ios/new name.swift", "android/deleted.kt"])
            self.assertEqual(calls[0], ("fetch", "--no-tags", "--depth=256", "origin", BASE, HEAD))
            self.assertEqual(calls[-1], ("diff", "--no-ext-diff", "--no-renames", "--name-only", "-z",
                                         MERGE if event == "pull_request" else BASE, HEAD, "--"))

    def test_any_diff_fetch_or_merge_base_failure_falls_back(self):
        for failing in ("fetch", "merge-base", "diff"):
            for error in (OSError("unavailable"), subprocess.CalledProcessError(1, "git"),
                          subprocess.TimeoutExpired("git", 90)):
                def run(*args):
                    if args[0] == failing:
                        raise error
                    return (MERGE + "\n").encode() if args[0] == "merge-base" else b""
                with self.subTest(failing=failing, error=type(error)):
                    self.assertIsNone(changed_paths("pull_request", self.event("pull_request"), run))

    def test_missing_zero_or_untrusted_shas_never_reach_git(self):
        def forbidden(*args):
            self.fail("invalid event must not reach git")
        for event in ({}, {"before": "0" * 40, "after": HEAD},
                      {"before": "--upload-pack=unsafe", "after": HEAD},
                      {"before": None, "after": HEAD}):
            self.assertIsNone(changed_paths("push", event, forbidden))
        self.assertIsNone(changed_paths("workflow_dispatch", {}, forbidden))

    def test_invalid_diff_output_is_conservative(self):
        for output in (b"android/a", b"android/\xff\0"):
            def run(*args):
                return output if args[0] == "diff" else b""
            self.assertIsNone(changed_paths("push", self.event("push"), run))

    def test_real_git_pr_excludes_base_only_changes_and_rename_keeps_both_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "origin"
            repo.mkdir()
            env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_AUTHOR_NAME": "CI", "GIT_AUTHOR_EMAIL": "ci@example.invalid",
                   "GIT_COMMITTER_NAME": "CI", "GIT_COMMITTER_EMAIL": "ci@example.invalid"}
            def git_at(where, *args):
                return subprocess.run(["git", "-C", str(where), *args], check=True, env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
            git_at(repo, "init", "-b", "main")
            (repo / "android").mkdir()
            (repo / "android/a").write_text("same data")
            git_at(repo, "add", ".")
            git_at(repo, "commit", "-m", "base")
            ancestor = git_at(repo, "rev-parse", "HEAD").decode().strip()
            (repo / "shared").mkdir()
            (repo / "shared/contract").write_text("base branch only")
            git_at(repo, "add", ".")
            git_at(repo, "commit", "-m", "main advances")
            base = git_at(repo, "rev-parse", "HEAD").decode().strip()
            git_at(repo, "checkout", "-b", "topic", ancestor)
            (repo / "ios").mkdir()
            git_at(repo, "mv", "android/a", "ios/a")
            git_at(repo, "commit", "-m", "rename across owners")
            head = git_at(repo, "rev-parse", "HEAD").decode().strip()
            clone = Path(temporary) / "clone"
            git_at(repo, "clone", "--depth=1", repo.as_uri(), str(clone))
            run = lambda *args: git_at(clone, *args)
            event = {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}
            self.assertEqual(changed_paths("pull_request", event, run), ["android/a", "ios/a"])
            self.assertEqual(changed_paths("push", {"before": base, "after": head}, run),
                             ["android/a", "ios/a", "shared/contract"])

    def test_cli_output_contract_and_bad_event_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            event, output, summary = (base / name for name in ("event", "output", "summary"))
            event.write_text("invalid JSON")
            env = {**os.environ, "GITHUB_EVENT_PATH": str(event), "GITHUB_OUTPUT": str(output),
                   "GITHUB_STEP_SUMMARY": str(summary), "GITHUB_EVENT_NAME": "push",
                   "GITHUB_REF": "refs/heads/main"}
            subprocess.run(["python3", str(ROOT / ".github/ci/select_checks.py")], env=env,
                           check=True, stdout=subprocess.PIPE)
            self.assertEqual(output.read_text(), "android=true\nios=true\nserver=true\nzip64_large=true\n")
            self.assertIn("unavailable/empty diff", summary.read_text())


class ZIP64GateTests(unittest.TestCase):
    def test_workflow_and_scheme_keep_all_xctest_targets_and_release_large_fixture(self):
        mobile = (ROOT / ".github/workflows/mobile.yml").read_text()
        distribution = (ROOT / ".github/workflows/testflight.yml").read_text()
        self.assertIn("WOONA_SKIP_ZIP64_LARGE: ${{ needs.changes.outputs.zip64_large == 'true' && '0' || '1' }}", mobile)
        self.assertIn("WOONA_SKIP_ZIP64_LARGE: '0'", distribution)
        self.assertIn("run: python3 ios/tools/test_complete_archive.py", distribution)
        self.assertIn("cancel-in-progress: false", distribution)
        self.assertNotIn("cancel-in-progress: true", mobile)
        for workflow in (mobile, distribution):
            # The Python >4 GiB fixture is NOT an XCTest. Never use broad
            # -skip-testing here: that could drop the entire storage/UI suite.
            self.assertNotIn("-skip-testing", workflow)
            self.assertIn("-scheme Woona", workflow)
            self.assertIn("python3 ios/tools/check-recording-export.py", workflow)
        scheme = ET.parse(ROOT / "ios/Woona.xcodeproj/xcshareddata/xcschemes/Woona.xcscheme")
        references = scheme.findall("./TestAction/Testables/TestableReference")
        targets = set()
        for ref in references:
            buildable = ref.find("BuildableReference")
            assert buildable is not None, "Scheme test target must have a buildable reference"
            targets.add(buildable.get("BlueprintName"))
        self.assertEqual(targets, {"WoonaTests", "WoonaUITests"})
        self.assertTrue(all(ref.get("skipped") == "NO" for ref in references))

    def test_only_explicit_skip_omits_large_fixture_and_other_tests_stay_enabled(self):
        path = ROOT / "ios/tools/test_complete_archive.py"
        for value, skipped in ((None, False), ("0", False), ("1", True), ("true", False), ("", False)):
            with self.subTest(value=value), patch.dict(os.environ, {}, clear=True):
                if value is not None:
                    os.environ["WOONA_SKIP_ZIP64_LARGE"] = value
                namespace = runpy.run_path(str(path), run_name="zip64_gate_test")
                cls = namespace["CompleteArchiveCompatibilityTests"]
                method = cls.test_file_larger_than_4_gib_is_readable
                self.assertEqual(getattr(method, "__unittest_skip__", False), skipped)
                others = [getattr(cls, name) for name in dir(cls) if name.startswith("test_")
                          and name != method.__name__]
                self.assertEqual(len(others), 9)
                self.assertFalse(any(getattr(test, "__unittest_skip__", False) for test in others))


if __name__ == "__main__":
    unittest.main()
