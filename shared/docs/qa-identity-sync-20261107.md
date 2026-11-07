# Identity/sync candidate verification — 2026-11-07

Candidate: Android/iOS 1.5.8, branch `fix/identity-sync-ux-20261107`,
[PR #19](https://github.com/Woona-Corp/woona-data-collector/pull/19).
This is verification evidence, **not a release or distribution announcement**.

## Implemented safeguards

- Transactional, global local identity reservations include historical profile
  versions and other data accounts; editing the same dog UUID remains possible.
  No automatic merging, recording reassignment or immutable-payload rewrite.
- Full case folding and whitespace rules are pinned to the observed deployed
  Python 3.13 / Unicode 15.1 behavior, not platform ICU. The authoritative
  comparison contained 1,530 fold mappings and 29 whitespace scalars. Unicode
  16-only case pairs remain distinct, as on that deployed runtime.
- V2 validation mirrors schema text lengths using scalar counts, required-text
  whitespace, bounded activity/surface arrays and numeric measurement bounds.
  Validation leaves original stored text unchanged.
- Durable local work survives absent server configuration. Actual attempts,
  profile-version acknowledgement and account-link invalidation remain separate.
- Credentials and URL userinfo/query/fragment data are redacted before HTTP
  exception construction/persistence and before technical-details presentation.
  Repeated sanitization is idempotent.
- Actual activity events are bounded best-effort diagnostics (128 installation
  events, 20 displayed matching events), not an audit or durable domain queue.
  Read-only capture previews are bounded and reject untrusted paths/symlinks.

## Completed local software checks

- Combined Android `tools/check.sh full`: **passed**, including 368 JVM tests
  with zero failures and the managed API 31 suite: 245 test cases, zero failures,
  eight opt-in cases skipped. Those skips are not physical/API verification.
- Android cleanup-only test-harness follow-up:
  `:app:compileDebugAndroidTestKotlin` passed. It preserves the original failure
  and independently restores keyboard/accessibility/orientation/font state;
  it does not change assertions, setup timing, coverage or retries.
- iOS Python tooling: 32 cases, one macOS-only class skipped on Linux.
- Workspace documentation checks and 22 script unit tests passed.
- `git diff --check` passed. Kotlin/Swift LSP probes were inconclusive, not proof
  of clean compilation. Native iOS requires macOS evidence below.

## Initial native CI findings and follow-up

[Initial full CI, source d04ec05](https://github.com/Woona-Corp/woona-data-collector/actions/runs/42397884937):

- Server job passed. Native iOS compiled and ran 349 unit cases plus 18 UI cases;
  three assertions failed. In particular, the new journal's ten cases and the
  capture-preview helper's four cases passed, but this was **not a green suite**.
- One unit assertion still required raw unknown errors in the primary summary;
  the revised presentation deliberately puts technical payloads in collapsed
  Details. The assertion now checks their absence from the summary.
- One UI test used the old “Error details” label; it now uses the existing stable
  recording identifier and checks collapsed/expanded technical evidence.
- Native accessibility evidence showed the identity card identifier propagating
  over the status leaf (`overview.identity`, label `Offline`), so the large-text
  test could not find `identity.status` and never reached landscape. The unused
  container identifier was removed; large-text, landscape and action assertions
  remain, with an additional status-hittability assertion.
- Android CI had five IME/focus failures. Logcat established the first failure
  immediately after an emulator `com.android.systemui` navigation-bar NPE during
  rotation/accessibility changes. Teardown then masked the original error and
  prevented other restorations. Cleanup now preserves both primary and suppressed
  failures. **Prevention of that emulator crash is not claimed**; no assertions
  were removed and no speculative timing workaround was introduced.

The corrected source needs a complete native CI rerun. A previous failure must
not be reported as a final pass merely because individual causes were explained.

## Physical-device and integration limitations

- A separate `com.woona.drivetest.review20261107` / “Woona UI Review” installation
  was created with eight explicitly synthetic replay fixtures, no device token
  and no claim of sensor/camera verification. The existing manual-QA installation
  and signed field installation were not cleared or replaced.
- An initial build override ran too early and produced the field package ID.
  Android rejected its install attempt with signature mismatch. Field version,
  installation and update timestamps were compared unchanged. The override was
  corrected to `androidComponents.finalizeDsl`, and both application ID and test
  target were then independently checked before installing the isolated build.
  [Phone instructions](../../android/docs/PHONE_CHECKS.md) now require these
  independent guards; signature rejection is not an acceptable protection plan.
- Physical visual review was not completed: the phone was locked, then USB
  disconnected. A new isolated loopback API/proxy became ready, but **zero**
  phone API regressions executed before disconnection. Its own containers,
  PostgreSQL volume, network and proxy were removed; existing services remained.
- No physical Android/iPhone BLE, camera, background/process-death or sensor
  quality evidence is supplied by these software runs. No backup job was enabled.

## Release gate

Keep the PR as a candidate until corrected-source Android/native iOS checks and
required visual/integration checks pass. Publish Android and iOS independently
only after their distribution gates; a prepared version number is not a release,
TestFlight upload, tester invitation or physical-device verification.
