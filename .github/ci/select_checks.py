#!/usr/bin/env python3
"""Dependency-aware CI selection. Stdlib only; uncertainty always runs full checks."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess


ALL = frozenset(("android", "ios", "server"))
# Narrow ownership boundaries only. Everything else (including shared contracts,
# fixtures, CI and new top-level directories) deliberately fans out to all jobs.
PATH_JOBS = (("android/", frozenset(("android",))),
             ("ios/", frozenset(("ios",))),
             ("shared/server/", frozenset(("server",))))
ZIP64_PATHS = ("ios/Woona/Storage/", "ios/Woona/Data/",
               "ios/WoonaTests/StorageTests/", "ios/tools/",
               "ios/Woona.xcodeproj/")


def decision(event_name, ref, paths=None, scope="all"):
    """paths=None means unavailable diff, not no changes. Manual scopes stay explicit."""
    if event_name == "workflow_dispatch":
        jobs = ALL if scope not in ALL else frozenset((scope,))
        return result(jobs, True, "manual scope; full ZIP64")
    if ref.startswith("refs/tags/"):
        # mobile.yml has always left iOS distribution to testflight.yml.
        jobs = frozenset(("android", "server")) if ref.startswith("refs/tags/android-v") else ALL
        return result(jobs, True, "release tag")
    if event_name not in ("push", "pull_request") or not paths:
        return result(ALL, True, "unavailable/empty diff or unsupported event")
    jobs = set()
    large = False
    for path in paths:
        if (not path or path.startswith("/") or ".." in path.split("/")
                or "\\" in path):
            return result(ALL, True, "unrecognized path")
        matched = next((owners for prefix, owners in PATH_JOBS if path.startswith(prefix)), None)
        if matched is None:
            return result(ALL, True, "shared dependency or unrecognized path")
        jobs.update(matched)
        large |= path.startswith(ZIP64_PATHS)
    return result(jobs, large, "changed-path ownership")


def result(jobs, large, reason):
    return {**{job: job in jobs for job in sorted(ALL)}, "zip64_large": large, "reason": reason}


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
    if event_name != "workflow_dispatch" and not ref.startswith("refs/tags/"):
        paths = changed_paths(event_name, event)
    inputs = event.get("inputs")
    scope = inputs.get("scope", "all") if isinstance(inputs, dict) else "all"
    selection = decision(event_name, ref, paths, scope)
    print(json.dumps({"selection": selection, "changed_paths": paths}, sort_keys=True))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            for key, value in selection.items():
                if isinstance(value, bool):
                    stream.write(f"{key}={str(value).lower()}\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as stream:
            stream.write("### CI selection\n\n```json\n" + json.dumps(selection, indent=2) + "\n```\n")


if __name__ == "__main__":
    main()
