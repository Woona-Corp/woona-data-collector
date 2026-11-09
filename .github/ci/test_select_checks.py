"""Hermetic policy, Git and ZIP64 gate tests; no SDK, network or third-party modules."""
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from select_checks import ALL, DOCS_ONLY, changed_paths, decision, git, required_gate

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
            (["README.md"], set(), False),
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

    def test_reviewed_docs_only_not_blanket_markdown(self):
        for path in DOCS_ONLY:
            self.assert_selection(decision("pull_request", "refs/pull/1/merge", [path]), set(), False)
        for path in ("new.md", "android/new.md", "shared/UI_UX_CONTRACT.md"):
            selected = decision("pull_request", "refs/pull/1/merge", [path])
            self.assertTrue(any(selected[job] for job in ALL))

    def test_reviewed_document_links_and_publication_boundary(self):
        # Narrative exemptions still receive cheap local-link and credential checks.
        for name in sorted(DOCS_ONLY):
            path = ROOT / name
            text = path.read_text()
            for link in re.findall(r"\]\(([^)\s]+)\)", text):
                target = link.split("#")[0]
                if target and ":" not in target:
                    self.assertTrue((path.parent / target).exists(), (name, target))
            self.assertIsNone(re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|"
                                        r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}", text), name)

    def test_modes_and_release_trust_boundary(self):
        for path, full in (("android/app/src/main/java/com/example/myapplication/protocol/Packet.kt", False),
                           ("android/app/src/main/java/com/example/myapplication/data/Store.kt", True),
                           ("unknown", True)):
            self.assertEqual(decision("pull_request", "refs/pull/1/merge", [path])["android_full"], full)
            self.assertFalse(decision("push", "refs/heads/main", [path])["android_full"])
        tag = decision("push", "refs/tags/android-v1.5.8")
        self.assertTrue(tag["android_full"] and tag["android_release"])
        for full in (False, True):
            manual = decision("workflow_dispatch", "refs/tags/android-v1.5.8", instrumentation=full)
            self.assertEqual(manual["android_full"], full)
            self.assertFalse(manual["android_release"])
            self.assertTrue(manual["zip64_large"])
        for enabled in (False, True):
            self.assertEqual(decision("push", "refs/heads/main", ["ios/a"], main_units_enabled=enabled)["ios_mode"],
                             "unit" if enabled else "full")
        self.assertEqual(decision("workflow_dispatch", "refs/heads/main", test_filter="WoonaTests")["ios_mode"], "diagnostic")
        self.assertEqual(decision("workflow_dispatch", "refs/heads/main", sanitizer="thread")["ios_mode"], "diagnostic")
        closed = decision("pull_request", "refs/pull/1/merge", action="closed")
        self.assertFalse(any(closed[job] for job in ALL))

    def test_main_fallback_modes_remain_canonical(self):
        for paths in (None, [], ["unknown"], ["../invalid"], ["ios/a"]):
            for enabled in (False, True):
                selected = decision("push", "refs/heads/main", paths, main_units_enabled=enabled)
                self.assertFalse(selected["android_full"])
                self.assertEqual(selected["android_mode"], "fast")
                self.assertEqual(selected["ios_mode"], "unit" if enabled else "full")

    def test_required_gate_rejects_failed_skipped_cancelled_and_missing(self):
        for selected in (True, False):
            needs = {"changes": {"result": "success", "outputs": {
                **{job: str(selected).lower() for job in ALL}, "android_release": "false"}},
                **{job: {"result": "success" if selected else "skipped"} for job in ALL},
                "release": {"result": "skipped"}}
            self.assertTrue(required_gate(needs))
            for job in (*ALL, "changes", "release"):
                for state in ("failure", "cancelled", None, "skipped" if selected else "success"):
                    if job == "release" and state == "skipped":
                        continue
                    changed = {**needs, job: {"result": state}}
                    self.assertFalse(required_gate(changed), (job, state))
            for job in (*ALL, "changes", "release"):
                self.assertFalse(required_gate({key: value for key, value in needs.items() if key != job}))

    def test_required_release_gate_and_invalid_selection(self):
        needs = {"changes": {"result": "success", "outputs": {
            "android": "true", "ios": "false", "server": "true", "android_release": "true"}},
            "android": {"result": "success"}, "ios": {"result": "skipped"},
            "server": {"result": "success"}, "release": {"result": "success"}}
        self.assertTrue(required_gate(needs))
        for state in ("skipped", "cancelled", "failure", None):
            self.assertFalse(required_gate({**needs, "release": {"result": state}}))
        for value in (None, "", "TRUE", "maybe"):
            outputs = {**needs["changes"]["outputs"], "ios": value}
            self.assertFalse(required_gate({**needs, "changes": {"result": "success", "outputs": outputs}}))

    def test_android_publish_and_server_export_wiring(self):
        mobile = (ROOT / ".github/workflows/mobile.yml").read_text()
        self.assertNotIn("--clobber", mobile)
        self.assertNotIn("inputs.android_instrumentation", mobile)
        self.assertIn("test '${{ needs.changes.outputs.android_full }}' = true", mobile)
        self.assertIn("test \"$actual_version\" = \"$expected_version\"", mobile)
        self.assertIn('WOONA_SERVER_TOKEN = "";', mobile)
        self.assertEqual(mobile.count("if: github.event_name == 'push' && needs.changes.outputs.android_release == 'true'"), 2)
        self.assertIn("CI_NEEDS: ${{ toJSON(needs) }}", mobile)
        self.assertIn("github.repository == 'Woona-Corp/woona-data-collector') || (github.event_name == 'workflow_dispatch'", mobile)


class DiffTests(unittest.TestCase):
    def event(self, event):
        return ({"before": BASE, "after": HEAD} if event == "push" else
                {"pull_request": {"base": {"sha": BASE}, "head": {"sha": HEAD}}})

    def test_push_exact_endpoints_and_pr_merge_base(self):
        for event in ("push", "pull_request"):
            calls = []
            def run(*args, calls=calls):
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
                def run(*args, failing=failing, error=error):
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
            def run(*args, output=output):
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
            self.assertEqual(dict(line.split("=", 1) for line in output.read_text().splitlines()),
                             {"android": "true", "ios": "true", "server": "true", "zip64_large": "true",
                              "android_full": "false", "android_mode": "fast",
                              "android_release": "false", "ios_mode": "full"})
            self.assertIn("unavailable/empty diff", summary.read_text())


class WorkflowHardeningTests(unittest.TestCase):
    def test_private_fetch_uses_only_temporary_host_scoped_credentials(self):
        token = 'synthetic-private-fetch-token'
        with patch.dict(os.environ, {'WOONA_CI_FETCH_TOKEN': token,
                                     'GIT_CONFIG_COUNT': '1',
                                     'GIT_CONFIG_KEY_0': 'advice.detachedHead',
                                     'GIT_CONFIG_VALUE_0': 'false'}, clear=True), \
                patch('select_checks.subprocess.run') as run:
            run.return_value.stdout = b'output'
            self.assertEqual(git('fetch', 'origin', BASE), b'output')
            call = run.call_args
            self.assertNotIn(token, repr(call.args))
            env = call.kwargs['env']
            self.assertNotIn('WOONA_CI_FETCH_TOKEN', env)
            self.assertEqual(env['GIT_CONFIG_COUNT'], '2')
            self.assertEqual(env['GIT_CONFIG_KEY_0'], 'advice.detachedHead')
            self.assertEqual(env['GIT_CONFIG_KEY_1'], 'http.https://github.com/.extraheader')
            self.assertTrue(env['GIT_CONFIG_VALUE_1'].startswith('AUTHORIZATION: basic '))
            git('diff', '--no-ext-diff', BASE, HEAD, '--')
            env = run.call_args.kwargs['env']
            self.assertNotIn('WOONA_CI_FETCH_TOKEN', env)
            self.assertNotIn('GIT_CONFIG_KEY_1', env)
            self.assertEqual(env['GIT_CONFIG_COUNT'], '1')

    def test_publish_workflows_pin_actions_and_do_not_persist_checkout_credentials(self):
        for name in ('mobile.yml', 'testflight.yml', 'secrets-check.yml'):
            with self.subTest(workflow=name):
                content = (ROOT / '.github/workflows' / name).read_text()
                references = re.findall(r'\buses:\s*([^\s]+)', content)
                self.assertTrue(references)
                self.assertTrue(all(ref.startswith('./.github/workflows/') or re.fullmatch(r'[^@]+@[0-9a-f]{40}', ref) for ref in references))
                self.assertEqual(content.count('uses: actions/checkout@'),
                                 content.count('persist-credentials: false'))
        mobile = (ROOT / '.github/workflows/mobile.yml').read_text()
        self.assertIn("cache-disabled: ${{ startsWith(github.ref, 'refs/tags/') }}", mobile)
        self.assertIn("cache-read-only: ${{ github.ref != 'refs/heads/main' }}", mobile)


class ZIP64GateTests(unittest.TestCase):
    def test_workflow_and_scheme_keep_all_xctest_targets_and_release_large_fixture(self):
        mobile = (ROOT / ".github/workflows/mobile.yml").read_text()
        distribution = (ROOT / ".github/workflows/testflight.yml").read_text()
        native = (ROOT / ".github/workflows/ios-native.yml").read_text()
        self.assertIn("uses: ./.github/workflows/ios-native.yml", mobile)
        self.assertIn("mode: ${{ needs.changes.outputs.ios_mode }}", mobile)
        self.assertIn("zip64-large: ${{ needs.changes.outputs.zip64_large == 'true' }}", mobile)
        self.assertIn("zip64-large: true", distribution)
        self.assertIn("cancel-in-progress: false", distribution)
        self.assertIn("cancel-in-progress: ${{", mobile)
        self.assertNotIn("-skip-testing", native)
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
