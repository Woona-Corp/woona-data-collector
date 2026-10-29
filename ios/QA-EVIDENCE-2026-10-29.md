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
| [Release workflow 40906195392](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40906195392) | 290/290 PASS | 0 / 256 | 41 / 256 |

Recorded control samples in all three runs match the original writer error 3850/errno 9.
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

The final standard simulator run in
[release workflow 40906195392](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40906195392)
at `75aae98` passed 290 unit tests plus 14 UI tests (304/304). The unit suite took
10.616 seconds and UI tests 438.896 seconds; `TEST SUCCEEDED` was recorded at
2026-10-29 16:08:42 UTC. Its independently opened native session ZIP again passed all
eight artifact types, questionnaires, sync, size/SHA and ZIP CRC checks. The earlier
299/299 result remains distinct. Earlier assertion/readiness failures were corrected without
removing UUID, draft-retention, active-capture, file-removal or exact cancellation checks.

Linux SQL/source checks cannot prove iOS compilation, BLE/camera behavior, MP4 quality,
background termination or physical sensor clock alignment. Those require a signed
physical iPhone and sensor.

## Internal release upload

The same successful release workflow built marketing version **1.5.1**, build
**13501**, from tag `ios-v1.5.1-internal.1` at `75aae98`. Native tests and signing-asset
installation succeeded before archive. Its log records `ARCHIVE SUCCEEDED` at
2026-10-29 16:11:23 UTC, then `Upload succeeded`, `Uploaded Woona` and
`EXPORT SUCCEEDED` at 16:12:43 UTC. These establish successful signed upload to
App Store Connect. The upload response states that the package is processing;
Apple processing completion and internal tester availability require the separate
exact-version/build status record and are not established by upload success alone.


## Apple availability confirmed

[Read-only verification 40951055459](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40951055459)
confirmed exact version **1.5.1 (13501)** as `VALID`, not expired,
`IN_BETA_TESTING`, and `available_for_internal_testers=true`. The existing internal
group contains two testers. No assignment, invitation or role change was requested;
physical installation is unverified.

During processing, Apple can return a null `buildBetaDetail` relationship. The
status checker now treats missing optional beta detail as unconfirmed availability
while retaining mandatory app/version ownership checks. All 32 checker tests and
the real read-only workflow passed. This is tooling only and changes no app code.


## UI startup readiness follow-up

The separate main run40906157293 failed one New UI case (303/304) although the
same runtime passed the complete release run304/304. Its hierarchy/video did
not establish the exact cause of the missed initial tap. Test-only `edef729`
waits for New to exist, be enabled and be hittable after startup, instead of
using account-field existence as action readiness. It preserves every editor,
save, new-ID and original-profile assertion and the original editor deadline;
there is no sleep or repeated tap. A pre-tap hierarchy is retained.

[Focused native run40953077016](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40953077016)
passed **1/1**, zero failures, **82.058s**. The separate full main run40953076878
passed 290 unit tests and 13 UI tests, but the new generic setup incorrectly
required enabled New in the running V2 fixture. This fixture sets
`isV2PreviewActive=true`, which deliberately makes `canSelectAnimal=false`.
Test-only `cc28784` excludes only that fixture from animal-action readiness;
all V2 navigation/chart assertions and deadlines remain unchanged. An independent
read-only review verified this condition against the fixture and callers.

The first focused pass validates the revised New fixture, not a proven cause of
every intermittent UI failure; the previous failures remain recorded. These diagnostic changes did not alter Release behavior; the subsequent
production heart-flow correction below has its own verified1.5.2 release.


The next full run40955417805, attempt1, passed 290 unit tests and 13 UI tests,
including New and V2. The first UI test failed within `app.launch`, before any
UI assertion. Its exported XCTest session records app PID9574 launched at
21:18:05.674 UTC and foreground state at21:18:21. The launch-progress request
started21:18:12.503 but Xcode logged receipt21:19:05.824; the status1 response
arrived21:19:13.827, **1.277s after** the60.047s waiter timeout. No crash/spin/sample
report exists among the502 exported diagnostics; the remote interface cannot
provide a spindump. This demonstrates a delayed launch-progress response, not
failed New/V2 assertions. Foreground state and absent crash reports alone do
not prove main-thread responsiveness without a stack. The next launch and all
remaining13UI cases passed. Only the failed iOS job was rerun on the same source;
no app change, relaxed assertion, timeout extension or test-level retry was added.


## Completed internal follow-up: iOS1.5.2(13601)

The native baseline [40961534011](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40961534011)
proved a real defect: selecting a dog with a preexisting incomplete heart record
opened its questionnaire without a new capture. The fixed flow creates one event
only after that exact capture's durable finalization. One model/root presenter
handles automatic and manual opening. Fresh recording/profile-version/account and
pending-retirement checks fence stale targets; dismiss/history cannot recreate an
event. A profile-version update for the same dog retains the capture owner.

Unrelated queued networking cannot block local post-capture editing or Save; the
target's own queued/running transfer still fences it. The root waits for actual
SessionQuestionnaireEditor dismissal before presenting the captured heart form.
No DB schema or client/server wire format changed. Android1.5.1 already has the
same capture-owned behavior and does not require another release for this fix.

Verified evidence:

- AppShell [40964460954](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40964460954):56/56 PASS, including actual finalizer, scope/version changes, duplicate stop,
  fresh manual data, SQL retirement/finalization failure and retry, held unrelated
  networking plus local Save. Later modal/retirement refinements are covered by
  the final full gates below.
- Fixed old-history/manual UI [40964298725](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40964298725):1/1 PASS112.568s; exact persisted record and manual action loaded before the
  final no-autoform assertion. This does not claim four hidden-tab presenters.
- Actual preparation-editor handoff [40966993722](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40966993722):1/1 PASS68.050s. The real editor selects Heartbeat/314159 and Continue; an
  empty synthetic replay exercises failed durable finalization, followed by the
  root heart form, Later, Animals origin and history with both old/new records.
  No BLE/camera hardware behavior is claimed.
- ASan [40967541135](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40967541135)
  and TSan [40967541042](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40967541042):296/296 each, no sanitizer report. Earlier d6 failures in two export tests were
  a new fixture's leaked selectedAccountID, not new HTTP401 requests or missing
  production files. All six new fixtures now restore exact prior account/dog
  preference values/absence after owned work; original export assertions pass.
- Full main [40969007238](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40969007238)
  and release [40969011554](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40969011554):both296unit+16UI=312/312 PASS. Independent session ZIP/SQLite/size/SHA/CRC
  verification also passed. The final release code is357273b, tag
  ios-v1.5.2-internal.1; later changes are documentation only.

The signed archive succeeded29Oct23:10:21UTC and upload/export23:11:42UTC.
The actual uploaded version is **1.5.2**, build **13601**. Read-only Apple
verification [40971538845](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40971538845)
confirmed VALID/notexpired/IN_BETA_TESTING and available_for_internal_testers=true;
the existing internal group has two assigned testers. No assignments, invitations,
roles or external review were requested. physical_installation_verified=false.

CI now waits for completed simulator boot before xcodebuild, with a180s bound;
native control40963681018 passed the first Account UI case33.204s after the
simulator reported93s DataMigration/SystemApp initialization. This does not prove
all prior first-tap causes or physical-device behavior. The owner cannot currently
check the real iPhone; physical BLE/camera/background/clock alignment and the
firmware board remain separate acceptance checks. Authentic iOS schema1–4
fixtures remain unavailable. Additional discoveries are deferred to the next
update by the owner's explicit scope freeze.
