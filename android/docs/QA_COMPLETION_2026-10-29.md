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
The total is counted once per refresh and reused while paging; new top inserts
need explicit refresh. Metadata and sync fields are selected in bulk. Artifact requests are chunked
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

- 269 JVM tests passed, including the complete current-form literal inventory,
  v1/v2 validation messages, account scope epochs, formatting, bounded parallel
  ordering, and fatal cancellation.
- Debug APK and instrumented APK assembled; debug v2 signature verified.
- Full API 31 native runner: 150 discovered; 146 passed, 4 assumption-skipped,
  zero failures, 135 seconds. Skips require an explicitly supplied local API or
  production diagnostic credential. No production credential was supplied.
- The executed native cases include the 18 new localization/migration/history
  checks, 5 storage parser/UI/request checks, and 2 restore HTTP concurrency/
  cancellation checks. Existing app recreation/navigation and file-safety tests
  passed as part of the full runner. This does not prove physical BLE or camera
  hardware behavior; emulator camera/video tests use synthetic inputs.
- After final wording, error language switching, and count-snapshot refinements,
  all 13 affected native cases passed again.
- `docker compose config -q` passed.
- Required `android/tools/check.sh fast` and `full` were attempted. Local lint
  cannot resolve existing Compose 1.7.0 desktop POM metadata from the offline
  dependency mirror; normal dependency resolution also stalled. No dependencies
  or tool versions were changed. Compilation, JVM tests, APK signing and the
  complete directly executed native suite above ran successfully. CI must supply
  the complete dependency metadata and run the repository lint/managed-device
  wrapper before claiming that wrapper green.
