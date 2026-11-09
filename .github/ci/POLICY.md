# Mobile CI selection and required gate

`mobile.yml` always runs the Linux `changes` policy/documentation gate and a
fail-closed aggregate. Only open PRs publish the protected `ci-required` context;
main/tag/manual/closed runs publish `ci-observed` instead. A focused manual or
closed-PR no-op therefore cannot substitute for the required PR gate on the same
commit. There is no workflow-level path filter. Configure
main protection to require `ci-required`, up-to-date PRs and no runtime direct-push
or bypass before setting repository variable `CI_MAIN_UNITS_ENABLED=true`.
This change does not itself configure GitHub branch protection.

## Reviewed paths, not a Markdown wildcard

`select_checks.py::DOCS_ONLY` is the exact reviewed narrative allowlist: root
README/release notes, iOS README, the named Android/iOS QA evidence and shared QA
and historical acceptance report. A new Markdown path is **not** automatically
safe. Shared UI/UX, API/data contracts, fixtures, models, workflows, selector,
unknown or malformed paths and unavailable/empty diffs select all platforms and
the full ZIP64 fixture. Android and iOS directories select their owner;
`shared/server/` selects server. Multiple paths form a union. Storage/Data,
storage tests, iOS tools and Xcode project inputs require full ZIP64.

PR diffs use merge-base(base SHA, head SHA)..head SHA. Main uses exact event
before..after. A bounded fetch of the two SHAs has depth 256; distant/missing
merge bases, deleted SHAs, invalid event/diff or fetch failures fail closed.
NUL-delimited `--no-renames` exposes both deleted and added rename paths.
Private fetch uses only a temporary GitHub-host-scoped token header in the fetch
child environment, never argv, URLs, repository config or artifacts.

## One mode per platform

- Android PR: full for runtime/UI/data/storage/BLE/video/sync/preferences,
  resources, manifests, instrumentation and build inputs. Only the explicitly
  listed pure protocol source/JVM test paths are fast. Main is fast; Android
  release **push** is full. Manual `android_instrumentation` selects fast/full
  debug diagnostics, even when the selected ref is a release tag.
- iOS PR is `full`. Main remains `full` unless the exact repository variable
  above is `true`, then `unit` (build + units, not UI acceptance). Manual filters
  or sanitizers are `diagnostic`; unfiltered manual runs are `full`.
- Tag/manual and shared-contract changes require the full independent ZIP64
  fixture. Ordinary non-storage iOS changes may explicitly omit only the >4 GiB
  fixture. The other ZIP/SQLite assertions and native test targets remain intact.

The selector emits `android_full`, `android_mode`, `android_release`, `ios_mode`
and `zip64_large` once. Android SDK/KVM/health/check steps consume that same
`android_full`. The existing single batched debug Gradle invocation is unchanged.
The iOS caller delegates to canonical `ios-native.yml` using `mode`,
`zip64-large`, `test-filter` and `sanitizer`; simulator logic is not duplicated.

## Android test identity proof

One stdlib verifier, `.github/ci/android_test_manifest.py`, runs after debug checks
and before signing secrets. It requires non-empty JVM XML and, in full mode,
API31 managed-device XML. It rejects malformed XML, contradictory counters,
missing identities, duplicates, failures/errors, all JVM skips and unexpected
instrumentation skips. Only the eight named opt-in identities reviewed in exact
run 42609790701 XML are allowed to skip; the allowlist is not a numerical skip
budget. Passing those opt-in cases is permitted. Fast runs reject stale full-mode
reports. No fixed suite count or CLI progress counter is treated as inventory.

`android-tests.json` records actual per-group case identities/statuses/counts,
each report path/SHA-256, mode, source SHA, run ID/attempt, verification result and
errors. It is kept with diagnostics, including a failed verification, and copied
to the APK artifact on success. Missing/bad XML cannot reach release signing.
This report binds the supplied workflow identity to reports from that checkout;
it is not a cross-run proof service or evidence of physical-device acceptance.

## Releases, exports and cancellation

Signing and Android publication require an Android tag **push**, not a manual
run on a tag ref **containing this workflow version**. Historical tags keep their
historical workflows: do not dispatch older release tags as diagnostics, because
those old definitions predate this separation. Do not move tags to retrofit CI;
use a branch containing the reviewed workflow instead.
Full debug tests finish before signing secrets enter the
release step. Release assembly remains a separate variant invocation. Certificate,
versionName/tag equality, empty generated release bearer token, APK size and SHA
checks precede publication. Existing releases are immutable: no `--clobber` or
replacement upload. Gradle cache writes remain main-only; tag refs disable the
cache, and signing secrets are never shared with tests/cache setup.

Ordinary branch/PR runs cancel stale runs in their own group. Closed PR events
cancel stale native work and select no native jobs. Release-tag and manual runs
use isolated groups with cancellation disabled; manual runs include run ID so
exports and diagnostics cannot replace one another. No release is cancelled by
ordinary CI. Successful Android reports are retained 7 days without duplicating
the debug APK in diagnostics; `android-apk` holds the built APK.

Server tests continue to use the same image built once in their job. That exact
verified image plus provenance is exported for trusted main pushes and explicit
manual server/all exports only, never PR or tag production exports. The
`server-verified-image` artifact is retained 7 days. This is an image artifact,
not a database/recording backup or authorization to deploy.

`ci-required` requires the selector/policy gate to succeed, every explicitly
selected job to succeed, every excluded job to be skipped, and a selected Android
release publisher to succeed. Missing outputs/results, selected skips,
cancellations and failures are errors. Diagnostic iOS results are not full native
release evidence. GitHub required-check configuration remains an owner action.

## Validation and evidence limits

```sh
python3 -m unittest discover -s .github/ci -p 'test_*.py' -v
actionlint .github/workflows/mobile.yml .github/workflows/ios-native.yml .github/workflows/testflight.yml
./android/tools/check.sh fast
```

Hermetic tests cover real temporary Git rename/delete/add boundaries, event and
path tables, unavailable/invalid diff fallback, release/manual trust, mode outputs,
required-job failures/skips/cancellations/missing results, action pins, cache and
reusable-workflow wiring. Linux policy checks do not prove Xcode behavior,
physical BLE/camera/synchronization or Apple processing/tester availability.
No CI run, release, upload or device acceptance is implied by local static tests.
The audit's latency estimates are forecasts, not measured optimization results.
