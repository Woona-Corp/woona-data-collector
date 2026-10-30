# Mobile CI selection policy

`mobile.yml` runs the stdlib tests and selector in `changes`, then retains the
existing `android`, `ios`, `server` and `release` job names. No workflow-level path
filter hides required checks. Selection is a union of these ownership boundaries:

| Changed path | Checks | >4 GiB ZIP64 fixture if iOS runs |
| --- | --- | --- |
| `android/**` | Android | Not applicable |
| `ios/**` | iOS | Ordinary CI explicitly omits it, except rows below |
| `ios/Woona/{Storage,Data}/**` | iOS | Full |
| `ios/WoonaTests/StorageTests/**`, `ios/tools/**`, `ios/Woona.xcodeproj/**` | iOS | Full |
| `shared/server/**` | Server | Not applicable |
| Other shared paths, contracts, testdata, test-fixtures, workflows, selector, unknown paths | All | Full |
| Missing/failed/empty diff | All | Full |

PRs compare **merge-base(base SHA, head SHA)..head SHA**, not the synthetic merge
commit and not base-tip..head. Pushes compare the event's exact **before..after**
SHAs (including multi-commit pushes and force pushes). Renames are diffed without
rename detection so both deletion and addition participate in selection. Paths
are NUL-delimited. A bounded `git fetch --no-tags --depth=256` of just the two event
SHAs suffices for typical PRs; missing/deleted SHAs, distant merge bases, malformed
events and fetch/diff errors select all. There is no full-history clone or GitHub
files-API pagination/truncation assumption. Selector decisions appear in job logs
and the GitHub step summary.

Manual mobile scopes remain explicit (`all`, `android`, `ios`, `server`) with full
ZIP64 whenever iOS is selected; diagnostic XCTest filters/sanitizers remain
available. Android tags always run Android + server before publishing, without
adding iOS as a new Android release dependency. TestFlight tags **and manual
archive/export/upload runs** always run independent archive tests with the large
fixture, plus the existing simulator suite and export attachment verification.
Nothing here changes release signing, versions, upload logic or permissions.

## Large fixture gate, not an XCTest exclusion

`ios/tools/test_complete_archive.py` now runs the large streaming fixture by
**default**, including direct developer/full runs. Only the exact explicit value
`WOONA_SKIP_ZIP64_LARGE=1` skips that single test. Ordinary, non-storage iOS CI opts
in to that omission through the selector output. Other compatibility, >65,535
entries, CRC, cancellation, mutation, SQLite and insufficient-space assertions
are unchanged. Sanitizers do not instrument the independently compiled Swift
helper, so manual sanitizer runs also retain that independent coverage.

The large fixture is Python-driven, not a simulator test. The `Woona` scheme
includes **both WoonaTests and WoonaUITests**. No `-skip-testing` is added: skipping
a target/class to avoid this fixture would not work and would lose unrelated
storage/UI coverage. Existing focused `-only-testing` diagnostic behavior is
unchanged. Runtime Swift and the Xcode scheme are untouched.

No cancellation policy was added. TestFlight retains its existing serialized
`testflight-main` group with `cancel-in-progress: false`; tag/manual uploads must
never be superseded by an ordinary PR. Scheduling/queued-run behavior is otherwise
unchanged.

## Fixed action inputs and release cache isolation

The two modified build/distribution workflows pin each existing action version to
its resolved full GitHub commit (read-only upstream ref inspection, 2026-10-30),
without a major-version upgrade. Every checkout sets `persist-credentials: false`.
Gradle cache writes are restricted to main; tag builds disable Gradle caching
entirely so signed Android releases do not consume a shared build cache. Existing
release signing, upload gates, artifact scopes and TestFlight serialization are
unchanged. Hermetic tests guard these invariants alongside job selection.

## Validation

From the repository root on Linux:

```sh
python3 -m unittest discover -s .github/ci -p 'test_*.py' -v
actionlint .github/workflows/mobile.yml .github/workflows/testflight.yml
./android/tools/check.sh fast
```

The tests use local temporary Git repositories (no network), table-driven event
policies, failure injection, direct gate introspection, and scheme/workflow wiring
assertions. These do **not** prove that Xcode or GitHub Actions will behave as
intended. After the owner publishes these changes, inspect an actual ordinary
PR/main run's `changes` summary and job skips; exercise an iOS UI-only change
(single explicit large-fixture skip), then an exporter/storage change (all ten
independent tests including the large fixture). Verify simulator WoonaTests and
WoonaUITests and export attachments still pass. Verify full archive coverage in
the next already-authorized TestFlight tag/manual run before upload. Do not
create tags, dispatch/cancel workflows, or upload merely to validate this policy.

## Baseline evidence (not a speedup benchmark)

Read-only GitHub run inspection on 2026-10-30 found successful main push run
[40973885283](https://github.com/Woona-Corp/woona-data-collector/actions/runs/40973885283)
at baseline `cd7eecbf35edd082794decd9ea5fe691bed23a7e`:

- Server job: 23:33:00–23:33:57 UTC (57 s).
- Android job: 23:33:00–23:36:40 UTC (220 s).
- iOS job: 23:33:00–23:49:33 UTC (993 s).
- Independent archive step: 23:33:03–23:33:44 UTC (41 s, compilation + all
  compatibility cases, **not an isolated large-fixture measurement**).
- Simulator step: 23:33:44–23:49:00 UTC (916 s).

These are historical wall-clock observations, not billed-minute estimates or a
before/after benchmark. No speedup has been measured. Dependency selection is
expected to avoid irrelevant jobs; adding archive tests to TestFlight deliberately
adds release coverage. Measure comparable new runs before claiming savings.
