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
Metadata and sync fields are selected in bulk. Artifact requests are chunked
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

## Validation so far

- JVM tests and debug/instrumented Kotlin compilation passed.
- Debug APK and instrumented APK assembled.
- 18 targeted native tests passed (8 schema inputs, 3 history database tests,
  4 questionnaire UI tests, 3 history/error UI tests).
- Full integration checks follow the final storage/restore changes.
