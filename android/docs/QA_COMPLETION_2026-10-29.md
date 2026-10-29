# Android QA completion, 2026-10-29

Scope: synthetic Android API 31 emulator and JVM checks. No physical phone or
clinic recordings were used. This is internal QA, not tester/public distribution.

## Questionnaire presentation (QA07)

The shared RU-to-EN presentation catalog covers dog, session, heart, and reference
forms, including labels, canonical option titles, and validation. Field values,
free text, canonical option strings, JSON, and hashes retain their original values.
The Android catalog also includes the 18 existing iOS presentation variants.
Native tests traverse long forms and save Russian names and option values under
English UI. JVM catalog checks cover every entry and heart option title.

## Schema compatibility (QA15)

The migration test creates actual old table structures from the text SQL fixtures
and migrates/reopens each version 1 through 8. It checks identity, questionnaire
text, unknown recording end, capture errors, file bytes and SHA-256, upload
progress, and account/revision metadata where the old version supports them.

Versions 5–8 derive from the published Git source cited in the fixture README.
The earliest published source in all local refs is already version 5 (`73a0beb`).
Versions 1–4 are reconstructed compatibility inputs based on the published
migrator and the existing legacy fixture. They are not claimed to be original
release schemas or a test of a real historical installation.

## Large history (QA16)

History opens with 10 rows, then loads 100 at a time with a keyset cursor. The
history screen is a native LazyColumn with each recording as a separate keyed
item. Explicit refresh loads the first 100 again, including newer records.
The total is counted once per refresh and reused while paging. Cursors retain a
first-page rowid watermark, excluding later imports beyond that boundary. Paging
is also capped at the opening count, because SQLite can reuse a deleted highest
rowid. The header explains that the count describes the opening snapshot. If
rows disappear before the cursor ends, the screen offers explicit refresh and a
membership-change explanation instead of a nonfunctional More action. Metadata and sync fields are selected in bulk. Artifact requests are chunked
below SQLite's variable limit. History queries run on a background executor.

The additive expression index sorts mixed historical ISO date formats by SQLite
milliseconds and UUID. Submillisecond differences are stable UUID ties. Invalid
and missing dates remain visible after valid dates. Original timestamp text is
never rewritten. Cursor predicates use the same normalized key as ORDER BY.

API 31 native tests used 1,205 synthetic records with 2 artifacts each. They
verify pages without duplicates, exact metadata equivalence with the individual
record lookup, mixed precision/offset ordering and null/invalid times, concurrent
newer inserts, index use without temporary sort, and lazy UI composition (fewer
than 20 capture rows composed, including after reaching the last row).

One emulator timing sample: all 1,205 records read in bulk pages in 186 ms versus
423 ms using the prior individual metadata lookups. This is a reproducible
synthetic comparison, not a physical-device latency guarantee.

## Restore and server storage status

Restore list pages remain at 200. Dog/recording detail reads use at most four
concurrent requests and keep list order. Metadata is applied serially after the
complete fetch. A fatal error cancels sibling requests belonging to that restore;
it does not advance the global transfer epoch or cancel unrelated uploads.
Deletion markers are fetched last. HTTP 410 by itself is no longer described as a
confirmed retirement: a fresh exact marker (or its parent dog marker) is required.
Unknown 404/410 remains an explicit partial-restore warning.

Byte/count fields require nonnegative signed-64 JSON integers. Fractional values,
numeric strings, NaN strings, and overflow numeric representations are rejected;
valid integers above 2^53 retain their exact value. A native test consumes the
actual captured 200/flat 413/flat 507 response fixture in shared test data
(server commit `1f97ba7`) and checks scope, request IDs, error explanations,
retryability, and next actions.

Settings has a manual authenticated server-storage check with separate unchecked,
loading, checked, unsupported-old-backend (404), and failure/retry states. It
validates the exact account scope, invalidates results when URL/token/account or
transfer epoch changes, and rejects callbacks from an older request. Account
quotas and whole-server disk/reservation values have explicit scope labels and
two-decimal GiB units. Zero configured limits and null remaining quota are
Unlimited; actual zero capacity remains zero. Received-byte volumes never claim
SHA-256 or receipt verification. Existing accepted uploads may resume. Error
technical details are selectable, and the configured token is redacted if echoed
by an error response.

New error/action explanations cover storage quotas, unavailable reserved space,
and the already-running server integrity check. Presentation wording matches iOS.

## Validation

The final repository gate is green: [Android full CI 40896118469](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40896118469)
on `3004aaae8e8fed16ddd45118ed605deb88dc0b0e`, version 1.5.1 (code 14).
The Android job completed in 11m34s and ran the required
`android/tools/check.sh full` tasks: JVM tests, lint, debug build, and managed
API 31 native tests. The debug APK and diagnostic artifacts were uploaded;
its Android Debug certificate and v2 signature were verified. This is a CI debug
artifact, not proof of a signed release or tester distribution.

- JVM: 269 passed, zero failures/errors/skips. Coverage includes the complete
  current-form literal inventory, v1/v2 validation messages, scope epochs,
  formatting, bounded parallel ordering, and fatal cancellation.
- Managed API 31: 157 discovered; 153 passed, 4 assumption-skipped, zero
  failures/errors. The skipped cases are the three external API/WorkManager
  integration methods and the production-credential diagnostic. This CI job
  deliberately does not start an API or supply credentials.
- The executed native cases include all eight migration inputs, four long-form
  localization cases, four history database cases, four history UI cases, six
  storage/parser/shared-wire cases, two restore HTTP concurrency/cancellation
  cases, and all four post-stop MainActivity heart-prompt cases. App recreation, navigation and file-safety tests also passed.
- Lint: zero errors, 61 nonblocking warnings. The green gate does not mean a
  warning-free report.
- Separately, on an exclusively owned disposable API/PostgreSQL fixture, all
  three real external API/WorkManager cases passed. The same four-case class also
  passed its embedded-default settings case. These results are independent of
  the three CI assumption-skips, not additional external cases run by that CI.
  This separate backend/transfer proof used `632925e`; the final `3004aaa` gate
  also covers the subsequent post-stop MainActivity fix. The API cases cover
  account/other/unassigned storage scope, invalid/revoked/secondary
  auth, real worker 401 UI and Retry, persisted injected 503 and automatic retry,
  timeout recovery, upload/restore, range/ETag resumption and downloaded bytes.
  Production credential diagnostics remain unexecuted.
- The existing WorkManager UI case initially produced a harness false positive:
  Thread.sleep/UiAutomation polling did not advance the Compose test clock;
  an old hardcoded lazy-list index and global error matcher then targeted the
  wrong card or two independent 401 messages. Clock-driven waiting uses the
  original 10-second deadline; semantic card scrolling/scoping proves the actual
  queue error and Retry action. Product startup locking was not changed.
- `docker compose config -q` passed locally. Earlier local `fast`/`full` wrapper
  attempts were blocked by missing existing Compose 1.7.0 desktop POM metadata
  in the offline dependency mirror; normal resolution also stalled. The final
  online CI full gate above resolves that local verification limitation. No
  dependencies or tool versions were changed to work around the cache.

No physical BLE, camera hardware, or synchronization accuracy is proved by these
emulator checks. Emulator camera/video tests use synthetic inputs.

## Follow-up: post-stop heart questionnaire

Independent review found an asynchronous regression after the earlier green gate:
`handleRecordingChanged` scheduled a history refresh, then immediately searched
the previous `recentRecordings` list. A just-stopped heart capture could still
appear as recording in that list, so its required questionnaire did not open;
an older unfilled heart session could be selected instead.

The recording-change callback now records a target ID, account scope and event
generation. Only an accepted current history result may consume that event and
open the target's fresh terminal heart record. The target is read on the history
worker even when outside the visible first ten rows. Pending events survive
superseding stop/WorkManager refreshes and activity recreation. Ordinary history
browsing never creates such an event. Editing an existing questionnaire reports
its displayed recording ID instead of using the latest capture ID.

All `refreshProfilesAndRecordings`/`loadRecordingHistory` callers were checked.
The immediate stale-list read existed only in `handleRecordingChanged`; profile
selection remains synchronous for the other callers. Four native fake-BLE cases
exercise the real MainActivity/SQLite/finalization path: correct heart target,
activity stop with an older missing-heart record, ordinary history open/refresh,
and recreation while the history worker is deliberately queued.

The runtime and instrumented sources compile and 269 JVM tests pass. All four
new native cases passed locally in 6.339s and in the final full CI above. As a
negative control, the exact heart-stop test failed against the previous
MainActivity (`1495d68`, equivalent to the pre-fix runtime): after filling and
saving the opened heart form, the changed recording's questionnaire remained
null for the test's 10-second bound. The same test passes with `921d3d5`.

The final full CI includes this fix: 157 native cases, 153 passed and four
explicit credential/API skips, plus all 269 JVM tests and lint. The earlier green
`75cb00d` gate alone did not validate the follow-up.

One local broad run lacked the shared captured fixture in its isolated Android
worktree. Its other 156 cases completed (152 passed, four skipped). Restoring the
exact Git fixture and rebuilding the test APK made the isolated parser case pass
in 0.398s. Final CI packages the committed fixture and passes the entire suite.
