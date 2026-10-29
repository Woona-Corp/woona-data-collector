# iOS QA evidence — 2026-10-29

## Historical database migrations

`WoonaDataTests.testEveryDocumentedHistoricalSchemaMigratesWithoutChangingOriginalDataOrFiles`
creates SQLite files from historical DDL below. It never creates the current schema and
only lowers `user_version`. `HistoricalIOSSchema` retains the SQL in source, including
three genuinely different schema-5 revisions.

| Fixture | Historical source | Stored version | Relevant schema difference |
| --- | --- | --- | --- |
| initial5 | `73a0beb` | 5 | First published iOS storage schema |
| reference5 | `c6a6a5a` | 5 | `artifacts.reference_metadata_json` |
| appVersion5 | `0109d3a` | 5 | `recordings.app_version` |
| accounts6 | `d584261` | 6 | `dogs.account_id`, questionnaire revision/dirty flag |
| profileQueue7 | `f83fa3b` | 7 | Durable per-version profile upload queue |
| retirement8 | `860cc2b` | 8 | Local deletion outbox and deferred retirements |

The earliest available iOS source already uses version 5. Authentic DDL for versions
1–4 is absent from the available Git history; these versions are **not proven** by
these fixtures. No guessed version-1–4 schema or blanket rejection was introduced.
Structurally compatible older databases keep the existing migration behavior.

Each fixture includes current and historical profile versions/canonical questionnaire
hashes, an original completed recording and active capture, original packet/sync files,
artifact SHA-256/path/progress, nullable capture end, device clock integer above 2^53
and negative offset, account when present, upload receipts, questionnaire revision,
and reference metadata/file where its historical column existed. The test opens the
store twice and compares rows, data, files and hashes; checks version 8 and
`PRAGMA integrity_check`; and checks queue/deferred states where historically present.
A read-only artifacts view forces a real ALTER failure; a separate regression verifies
that schema changes and version updates roll back together without replacing originals.

## Large local history and restore

The source tests cover 1,205 local recordings with page-100 keyset boundaries, exact
preservation of raw time strings (0/3/6 fractional digits and +03 offset), same-instant
UUID ties and malformed legacy timestamps visible last. The SQL expression/index uses
normalized UTC milliseconds; submillisecond values are retained verbatim and ties are
ordered by UUID. Artifact lookups use IN chunks of at most 500; query-count budgets
prevent per-record sync/artifact reads. The UI reads at most 100 rows per worker chunk,
keeps stable recording IDs, renders separate lazy cards and reports loading/retry/error.
Explicit Refresh starts at the newest 100. Counts freeze during appended pages and the
UI explains that new recordings appear after Refresh.

Separate tests cover IO off MainActor, retained rows on read failure without creating an
empty database, rejected late results after changing animal, and all-account queue
visibility when the selected account has no animal. Restore tests fetch 205 recording
details over two pages and measure a maximum of four concurrent requests. Details are
applied serially in list order, preserving clock precision and unknown capture end.
Cancellation stops the current batch before late results can apply. Existing partial
404/410, fresh deletion marker, authorization, local-original and repeated-cursor tests
remain in the suite.

## Presentation and server metadata

Native questionnaire presentation translates labels, canonical choices and validation
messages only. Russian model/wire values and user text remain unchanged. A shared
Android/iOS exact translation catalog is copied into native code; UI testing switches
a saved English form to Russian and checks the original canonical size answer.

The Settings storage card separates account quota and whole-server volumes. Accepted
byte volume is not called SHA verification. Limit 0 and null remaining quota render
Unlimited; zero free capacity renders 0.00 GiB (RU 0,00 ГиБ). A bounded metadata gate
provides the 15-second storage deadline and immediate cancellation even when
waitsForConnectivity ignores URLSession's ordinary request timeout. Responses must
match account/unassignedOnly/includesAllAccounts=false and server scope; configuration
generations reject late URL/token/account results. HTTP 404 means unsupported storage
metadata; it does not change the independent connection-check status. Error reasons
413 quota, 507 reservation and 429 integrity busy have RU/EN actions, while raw request
IDs and allowlisted quota details remain available for diagnosis.

## Verification boundary

At initial localization CI `40882781582`, all 269 unit tests and 13 of 14 UI tests
passed, including the new English→Russian canonical-options UI test. Its sole failure
was a pre-existing blank-new-profile assertion that still expected the Russian
placeholder in English. It now accepts only empty or `Name *`; UUID/draft/reselection
checks remain intact.

At the next unit-only macOS/Xcode CI `40886601079` (source `09dc1f5`), 278/279 unit
tests passed. All six historical-schema fixtures, migration rollback, bounded history,
mixed timestamps, worker/stale-animal/read-failure checks, and storage timeout/cancel/
scope/error tests passed. The 1,205-row page100+page100+bulk-read benchmark took
0.111 seconds on that simulator. The sole failure was an existing removal-readiness
test asserting immediately after AppViewModel initialization; it now awaits actual
history/recovery readiness while retaining all file-removal and active-capture guards.
This unit-only run did not run the UI suite. Later top-level wire-contract correction,
actual server-generated fixture, four-request restore batches, nil-animal global queue,
and late-insert/deletion/ROWID membership additions require their own native result.
They must not be counted as passed based on this earlier run.

Linux SQL/source checks cannot prove iOS compilation, BLE/camera behavior, MP4 quality,
background termination or physical sensor clock alignment. Those require a signed
physical iPhone and sensor. This work performs no TestFlight upload or distribution.
