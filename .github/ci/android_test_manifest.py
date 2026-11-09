#!/usr/bin/env python3
"""Verify actual JUnit identities before Android signing; no SDK/dependencies."""

import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET  # nosec B405: UTF-8 only; DTD/entities rejected before parsing.
from pathlib import Path
from typing import Any

# Reviewed opt-in skips from API31 exact-tag XML, run 42609790701 (2026-11-09).
# These do not prove process-death, physical SAF, external API or production checks.
ALLOWED_INSTRUMENTATION_SKIPS = frozenset(
    (
        "com.example.myapplication.HeartProcessDeathDeviceTest#verifyRestartPromptsOnceAndKeepsOriginal",
        "com.example.myapplication.HeartProcessDeathDeviceTest#prepareActiveHeartRecording",
        "com.example.myapplication.storage.PhysicalSafArchiveDeviceTest#savesAndVerifiesSyntheticArchiveThroughSystemPicker",
        "com.example.myapplication.sync.ServerApiClientIntegrationTest#failedCaptureRecoveryArtifactUploadsAndDownloadsWithoutChangingOriginals",
        "com.example.myapplication.sync.ServerApiClientIntegrationTest#realWorkManager_invalidTokenIsVisibleAndManualRetrySucceeds",
        "com.example.myapplication.sync.ServerApiClientIntegrationTest#accountHeadersScopeDogsAndManualLink",
        "com.example.myapplication.sync.ServerApiClientIntegrationTest#uploadRestoreAndRangeDownload_roundTripAgainstDockerApi",
        "com.example.myapplication.sync.ServerConnectionDiagnosticTest#readProductionMetadata",
    )
)


def verify(build, mode, source, run_id, attempt):
    """Return an auditable manifest even on failure; counts come from testcase nodes."""
    build = Path(build)
    errors = []
    manifest: dict[str, Any] = {
        "schema": 1,
        "mode": mode,
        "source": source,
        "run_id": run_id,
        "run_attempt": attempt,
        "suites": {},
        "errors": errors,
    }
    if mode not in ("fast", "full"):
        errors.append("invalid mode")
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        errors.append("invalid source SHA")
    if not all(re.fullmatch(r"[1-9][0-9]*", value) for value in (run_id, attempt)):
        errors.append("invalid run identity")
    groups = {
        "jvm": sorted((build / "test-results/testDebugUnitTest").glob("TEST-*.xml")),
        "instrumentation": sorted(
            (build / "outputs/androidTest-results/managedDevice/debug/woonaApi31").glob(
                "TEST-*.xml"
            )
        ),
    }
    for group, paths in groups.items():
        cases = {}
        reports = []
        suite: dict[str, Any] = {"cases": cases, "reports": reports, "counts": {}}
        manifest["suites"][group] = suite
        required = group == "jvm" or mode == "full"
        if required and not paths:
            errors.append(f"{group}: missing JUnit reports")
        if group == "instrumentation" and mode == "fast" and paths:
            errors.append("fast mode has unexpected instrumentation reports")
        for path in paths:
            relative = path.relative_to(build).as_posix()
            try:
                raw = path.read_bytes()
                reports.append(
                    {"path": relative, "sha256": hashlib.sha256(raw).hexdigest()}
                )
                text = raw.decode("utf-8-sig")
                if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper():
                    raise ValueError("DTD/entity declarations are not accepted")
                # Stdlib-only gate: UTF-8 and no DTD/entities, enforced above.
                root = ET.fromstring(text)  # noqa: S314  # nosec B314
                if root.tag not in ("testsuite", "testsuites"):
                    raise ValueError("invalid JUnit root")
                nodes = list(root.iter("testcase"))
                if not nodes:
                    raise ValueError("empty JUnit report")
                for node in nodes:
                    classname, name = node.get("classname", ""), node.get("name", "")
                    if not classname or not name or "#" in classname:
                        raise ValueError("missing/ambiguous testcase identity")
                    identity = f"{classname}#{name}"
                    if identity in cases:
                        raise ValueError("duplicate testcase identity: " + identity)
                    statuses = [
                        status
                        for status in ("failure", "error", "skipped")
                        if node.find(status) is not None
                    ]
                    if len(statuses) > 1:
                        raise ValueError("ambiguous testcase status: " + identity)
                    status = statuses[0] if statuses else "passed"
                    cases[identity] = status
                    if status in ("failure", "error"):
                        errors.append(f"{group}: {status}: {identity}")
                    if status == "skipped" and (
                        group == "jvm" or identity not in ALLOWED_INSTRUMENTATION_SKIPS
                    ):
                        errors.append(f"{group}: unexpected skip: {identity}")
                for status in ("failure", "error", "skipped"):
                    if len(list(root.iter(status))) != sum(
                        node.find(status) is not None for node in nodes
                    ):
                        raise ValueError("unbound/duplicate JUnit status: " + status)
                # Do not trust counters over identities, but reject contradictory XML.
                for element in root.iter("testsuite"):
                    children = list(element.iter("testcase"))
                    observed = {
                        "tests": len(children),
                        "failures": sum(
                            c.find("failure") is not None for c in children
                        ),
                        "errors": sum(c.find("error") is not None for c in children),
                        "skipped": sum(c.find("skipped") is not None for c in children),
                    }
                    for key, count in observed.items():
                        if int(element.get(key, "0")) != count:
                            raise ValueError("JUnit counter mismatch: " + key)
            except (OSError, UnicodeError, ET.ParseError, ValueError) as error:
                errors.append(f"{relative}: {error}")
        suite["cases"] = dict(sorted(cases.items()))
        suite["counts"] = {
            "total": len(cases),
            "passed": sum(s == "passed" for s in cases.values()),
            "skipped": sum(s == "skipped" for s in cases.values()),
            "failures": sum(s == "failure" for s in cases.values()),
            "errors": sum(s == "error" for s in cases.values()),
        }
        if required and not cases:
            errors.append(f"{group}: no testcase identities")
    manifest["verified"] = not errors
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, default=Path("android/app/build"))
    parser.add_argument("--mode", required=True, choices=("fast", "full"))
    parser.add_argument("--source", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = verify(args.build, args.mode, args.source, args.run_id, args.attempt)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    print(
        json.dumps(
            {key: value for key, value in manifest.items() if key != "suites"},
            sort_keys=True,
        )
    )
    for name, suite in manifest["suites"].items():
        print(name + ": " + json.dumps(suite["counts"], sort_keys=True))
    return 0 if manifest["verified"] else 1


if __name__ == "__main__":
    sys.exit(main())
