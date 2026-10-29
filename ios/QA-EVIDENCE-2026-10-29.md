# iOS QA evidence — 2026-10-29

## Historical database migrations

`WoonaDataTests.testEveryDocumentedHistoricalSchemaMigratesWithoutChangingOriginalDataOrFiles`
creates SQLite files directly from the historical DDL below. No fixture is generated
by creating the current schema and lowering `user_version`. `HistoricalIOSSchema` retains the SQL in source, including
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
Explicit Refresh starts at the newest 100. The initial read transaction captures a
ROWID watermark carried in every cursor/filter. Appended pages reuse the opening
count and exclude later inserts; append is also capped to the remaining count because
SQLite can reuse a deleted highest ROWID. Regressions insert both newer and older rows,
delete an unseen row between pages, and exercise ROWID reuse. An exhausted list shorter
than its opening count explicitly asks the user to Refresh and recount.

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
IDs and allowlisted quota details remain available for diagnosis. The native parser
also consumes the same captured synthetic HTTP fixture as Android/server tests,
including top-level `existingUploadsMayResume` and flat error bodies.

Account selection commits only after both mandatory profile and recording restores
succeed. A failed attempt preserves the current account, its draft input, preferences
and selected animal. Incrementally saved profiles for another account remain in that
account's cache; partial data for the current account can appear without changing its
selection. RU/EN errors distinguish a failed account request from incomplete restore,
state that the current account/local data are preserved, and retain the original
401 code/request ID or timeout. Model regressions cover both language/error branches,
new/current account failures, a later failed background reconciliation, and a paused
mandatory recordings GET proving that success never switches the account early.

## SQLite history descriptor regression

Native sanitizers exposed a real write-path failure while the UI history connection
was opening/reading/closing beside a writer. The captured error was
`SQLITE_IOERR_LOCK` (extended code 3850), system errno 9 (`EBADF`), during retirement
reconciliation before the profile PUT. Cancellation was false, the network/token/store
guards were valid, and the request generation remained current. This was not a metadata
timeout or an identity-conflict retry policy failure.

History connections now open existing databases with `SQLITE_OPEN_READWRITE` and
`SQLITE_OPEN_FULLMUTEX`, omit `SQLITE_OPEN_CREATE`, skip directory creation/migrations,
and enforce read-only SQL with `PRAGMA query_only=ON`. This keeps the descriptor capable
of advisory lock transitions while the SQL layer rejects writes. A native test verifies
write rejection, retained original rows and that missing databases/directories are not
created. The SQLite [error-code reference](https://www.sqlite.org/rescode.html#ioerr_lock)
identifies 3850 as an advisory-lock failure; the controlled native runs below establish
the descriptor-mode-dependent reproduction without claiming a particular internal
Apple VFS implementation branch.

The concurrency regression runs 256 short-lived history connections alongside 256
real writer retirement transactions, then repeats with the former `O_RDONLY` mode in
an independent synthetic directory. The old-mode control intentionally records errors;
it does not require an intermittent platform failure to occur for the suite to pass.

| Native run, source `75aae98` | Unit tests | New query-only mode errors | Old descriptor control errors |
| --- | --- | --- | --- |
| [ASan 40903495453](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40903495453) | 290/290 PASS | 0 / 256 | 39 / 256 |
| [TSan 40903500634](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40903500634) | 290/290 PASS | 0 / 256 | 53 / 256 |

Recorded control samples in both runs match the original writer error 3850/errno 9.
Both protected fixtures preserved the original profile and inventory. Reports are kept
as `history-lock-churn-control` test attachments. These are simulator stress results,
not physical-device throughput or a guarantee about every filesystem.

Separate test infrastructure fixes await actual worker readiness, scope cancellation
counts to immutable request owners, and shut down synthetic model fixtures before
removing their databases. The failed-read test compares complete profiles, recordings,
sync JSON, artifact progress/hashes, queue errors, inventory and cleanup through SQLite
APIs; it does not rename or hash a live SQLite file. External file open/read/close can
release SQLite's process-wide POSIX locks; see SQLite's
[database-corruption guidance, section 2.2](https://www.sqlite.org/howtocorrupt.html).

## Verification boundary

The final source `75aae98` passed all 290 unit tests independently under AddressSanitizer
and ThreadSanitizer in the runs above. This includes genuine historical migrations and
rollback, the actual server wire fixture, bounded history/restore, account commit/failure
semantics, automatic profile upload after the recovery gate clears, original-file safety,
and the descriptor stress/control. No memory/data-race sanitizer report was observed.

The earlier standard full simulator run
[40889214248](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40889214248)
at `e6edcc7` passed 285 unit plus 14 UI tests (299/299). This proved separate New/Edit,
first Edit/reselection, five-tab navigation, EN→RU canonical answer retention, capture
failure/removal-cancel UI, and V2 preview controls. Its independent session ZIP reader
verified all eight artifact types, questionnaires, sync, file sizes/SHA and ZIP CRC.
The 1,205-row page100+page100+bulk-read fixture took 0.090814s; the 205-detail restore
fixture used at most four concurrent requests and took 2.222214s. These timings describe
synthetic simulator fixtures, not production throughput.

Four exported PNGs were visually inspected: EN/RU questionnaire top sections and
English/light plus Russian/dark Animals/Account screens. Visible titles, Save/Cancel,
Size Small↔мелкий, separate New/Edit and tab labels were not clipped; the Account prompt
was readable in both themes. The editable species value «собака» is preserved user/model
text in English on both platforms, not an untranslated UI label. This review does not
claim full-page/Dynamic Type visual coverage or contrast measurements for every field.

Subsequent account-selection and descriptor changes are covered by the final 290-test
sanitizer suites. Their standard full UI/release workflow results must be recorded
separately when those runs complete; the earlier 299/299 result is not relabeled as a
304-test final full run. Earlier assertion/readiness failures were corrected without
removing UUID, draft-retention, active-capture, file-removal or exact cancellation checks.

Linux SQL/source checks cannot prove iOS compilation, BLE/camera behavior, MP4 quality,
background termination or physical sensor clock alignment. Those require a signed
physical iPhone and sensor. These simulator/test records do not establish signing,
TestFlight upload, Apple processing or tester availability; release workflow records
establish those separately.
