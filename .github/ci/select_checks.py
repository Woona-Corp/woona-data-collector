#!/usr/bin/env python3
"""Dependency-aware CI selection. Stdlib only; uncertainty always runs full checks."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ALL = frozenset(("android", "ios", "server"))
# Narrow ownership boundaries only. Everything else (including shared contracts,
# fixtures, CI and new top-level directories) deliberately fans out to all jobs.
PATH_JOBS = (("android/", frozenset(("android",))),
             ("ios/", frozenset(("ios",))),
             ("shared/server/", frozenset(("server",))))
ZIP64_PATHS = ("ios/Woona/Storage/", "ios/Woona/Data/",
               "ios/WoonaTests/StorageTests/", "ios/tools/",
               "ios/Woona.xcodeproj/")


# Reviewed non-executable narrative only. New Markdown is NOT automatically safe.
DOCS_ONLY = frozenset((
    "README.md", "RELEASE_NOTES.md", "ios/README.md",
    "android/docs/PHONE_CHECKS.md", "android/docs/QA_COMPLETION_2026-10-29.md",
    "ios/QA-EVIDENCE-2026-10-29.md", "shared/docs/qa-identity-sync-20261107.md",
    "shared/docs/target-server-plan/acceptance-report.md",
))
ANDROID_FAST_PATHS = (
    "android/app/src/main/java/com/example/myapplication/protocol/",
    "android/app/src/test/java/com/example/myapplication/protocol/",
)


def decision(event_name, ref, paths=None, scope="all", *, instrumentation=False,
             action="", main_units_enabled=False, test_filter="", sanitizer="none"):
    """Compute modes once; callers must consume these outputs, not re-derive them."""
    main = event_name == "push" and ref == "refs/heads/main"
    ios_mode = "unit" if main and main_units_enabled is True else "full"
    release = event_name == "push" and ref.startswith("refs/tags/android-v")
    if event_name == "pull_request" and action == "closed":
        return result((), False, "closed PR: cancel stale work", False, False, "full")
    if event_name == "workflow_dispatch":
        jobs = ALL if scope not in ALL else frozenset((scope,))
        return result(jobs, True, "manual debug diagnostics; full ZIP64",
                      instrumentation is True, False,
                      "diagnostic" if test_filter or sanitizer not in ("", "none") else "full")
    if ref.startswith("refs/tags/"):
        jobs = frozenset(("android", "server")) if release else ALL
        return result(jobs, True, "release tag", True, release, "full")
    if event_name not in ("push", "pull_request") or not paths:
        return result(ALL, True, "unavailable/empty diff or unsupported event", not main, False, ios_mode)
    jobs = set()
    large = False
    full = False
    for path in paths:
        if (not isinstance(path, str) or not path or path.startswith("/")
                or any(part in ("", ".", "..") for part in path.split("/"))
                or "\\" in path or any(ord(char) < 32 for char in path)):
            return result(ALL, True, "unrecognized path", not main, False, ios_mode)
        if path in DOCS_ONLY:
            continue
        matched = next((owners for prefix, owners in PATH_JOBS if path.startswith(prefix)), None)
        if matched is None:
            return result(ALL, True, "shared dependency or unrecognized path", not main, False, ios_mode)
        jobs.update(matched)
        large |= path.startswith(ZIP64_PATHS)
        full |= path.startswith("android/") and not path.startswith(ANDROID_FAST_PATHS)
    return result(jobs, large, "changed-path ownership", full and event_name == "pull_request", False, ios_mode)


def required_gate(needs):
    """Selected skipped/cancelled/missing results are failures, never green skips."""
    changes = needs.get("changes", {})
    if changes.get("result") != "success":
        return False
    outputs = changes.get("outputs", {})
    for job in sorted(ALL):
        selected = outputs.get(job)
        if selected not in ("true", "false"):
            return False
        status = needs.get(job, {}).get("result")
        if status != ("success" if selected == "true" else "skipped"):
            return False
    release = outputs.get("android_release")
    return (release in ("true", "false") and
            needs.get("release", {}).get("result") == ("success" if release == "true" else "skipped"))


def result(jobs, large, reason, full=True, release=False, ios_mode="full"):
    return {**{job: job in jobs for job in sorted(ALL)}, "zip64_large": large,
            "android_full": full, "android_mode": "full" if full else "fast",
            "android_release": release, "ios_mode": ios_mode, "reason": reason}


def git(*args):
    env = dict(os.environ)
    token = env.pop('WOONA_CI_FETCH_TOKEN', '')
    if args and args[0] == 'fetch' and token:
        # One child process only: no credential in argv, URL, Git config or artifacts.
        count = int(env.get('GIT_CONFIG_COUNT', '0'))
        if not 0 <= count < 100:
            raise ValueError('Unsupported temporary Git configuration')
        encoded = base64.b64encode(('x-access-token:' + token).encode()).decode('ascii')
        env.update({'GIT_CONFIG_COUNT': str(count + 1),
                    f'GIT_CONFIG_KEY_{count}': 'http.https://github.com/.extraheader',
                    f'GIT_CONFIG_VALUE_{count}': 'AUTHORIZATION: basic ' + encoded})
    return subprocess.run(["git", *args], check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=90, env=env).stdout


def changed_paths(event_name, event, run=git):
    """PR: merge-base..head (not synthetic merge). Main: before..after.

    Fetch only two event SHAs with bounded history, never an unbounded clone.
    A distant/missing merge base, force-push deletion or fetch/diff failure runs all.
    --no-renames exposes both old and new paths for dependency-boundary renames.
    """
    try:
        if event_name == "pull_request":
            base = event["pull_request"]["base"]["sha"]
            head = event["pull_request"]["head"]["sha"]
        elif event_name == "push":
            base, head = event["before"], event["after"]
        else:
            return None
        if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-fA-F]{40}", sha)
                   and int(sha, 16) != 0 for sha in (base, head)):
            return None
        run("fetch", "--no-tags", "--depth=256", "origin", base, head)
        if event_name == "pull_request":
            base = run("merge-base", base, head).decode("ascii").strip()
            if not re.fullmatch(r"[0-9a-fA-F]{40}", base):
                return None
        raw = run("diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, head, "--")
        if raw and not raw.endswith(b"\0"):
            return None
        return [path.decode("utf-8") for path in raw.split(b"\0") if path]
    except (KeyError, TypeError, ValueError, UnicodeError, OSError, subprocess.SubprocessError):
        return None


def main():
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    ref = os.environ.get("GITHUB_REF", "")
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        if not isinstance(event, dict):
            event = {}
    except (KeyError, OSError, ValueError):
        event = {}
    paths = None
    if (event_name != "workflow_dispatch" and not ref.startswith("refs/tags/")
            and not (event_name == "pull_request" and event.get("action") == "closed")):
        paths = changed_paths(event_name, event)
    inputs = event.get("inputs")
    scope = inputs.get("scope", "all") if isinstance(inputs, dict) else "all"
    selection = decision(event_name, ref, paths, scope,
                         instrumentation=isinstance(inputs, dict) and inputs.get("android_instrumentation") in (True, "true"),
                         action=event.get("action", ""),
                         main_units_enabled=os.environ.get("CI_MAIN_UNITS_ENABLED") == "true",
                         test_filter=inputs.get("ios_test_filter", "") if isinstance(inputs, dict) else "",
                         sanitizer=inputs.get("sanitizer", "none") if isinstance(inputs, dict) else "none")
    print(json.dumps({"selection": selection, "changed_paths": paths}, sort_keys=True))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key, value in selection.items():
                if key != "reason":
                    stream.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write("### CI selection\n\n```json\n" + json.dumps(selection, indent=2) + "\n```\n")


if __name__ == "__main__":
    if sys.argv[1:] == ["--required-gate"]:
        sys.exit(0 if required_gate(json.loads(os.environ["CI_NEEDS"])) else 1)
    else:
        main()
