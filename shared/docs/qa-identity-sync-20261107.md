# Identity/sync candidate verification — 2026-11-07

Candidate: Android/iOS 1.5.8, branch `fix/identity-sync-ux-20261107`,
[PR #19](https://github.com/Woona-Corp/woona-data-collector/pull/19).
This is verification evidence, **not a release or distribution announcement**.
Times below are UTC. Check the PR's latest checks for subsequent results.

## Implemented safeguards

- Transactional, global local identity reservations include historical profile
  versions and other data accounts; editing the same dog UUID remains possible.
  No automatic merging, recording reassignment or immutable-payload rewrite.
- Full case folding and whitespace rules are pinned to the observed deployed
  Python 3.13 / Unicode 15.1 behavior, not platform ICU: 1,530 fold mappings and
  29 whitespace scalars. Unicode 16-only case pairs remain distinct.
- V2 validation mirrors schema text lengths using scalar counts, required-text
  whitespace, bounded activity/surface arrays and numeric measurement bounds.
  Validation leaves original stored text unchanged.
- Missing `plannedActivities` in a V2 heart session becomes `[]` only at explicit
  new-recording/edit commit boundaries. Historical reads, serialization/hashes
  and server-canonical responses are not silently normalized. Regression tests
  cover old rows, live/replay creation, finalization and explicit edits.
- Durable local work survives absent server configuration. Actual attempts,
  exact profile-version acknowledgement and account-link invalidation are separate.
- Credentials and URL userinfo/query/fragment data are redacted before HTTP
  exception construction/persistence and technical-details presentation.
  Repeated sanitization is idempotent.
- Actual activity events are bounded best-effort diagnostics: 128 installation
  events, 20 displayed matching events. They are not an audit or durable domain
  queue. Labels disclose retention and potentially missing unflushed events.
- Read-only capture previews are bounded and reject untrusted paths/symlinks.
  Account controls explain data scope, not a sign-in/security boundary.

## Software and native checkpoints

- Local full Android runs passed with **368 JVM cases** and **248 managed API 31
  cases, zero failures, eight opt-in skips**. Skips are not device/API evidence.
- Full Android CI on `bb5118c` passed:
  [run 42411107420](https://github.com/Woona-Corp/woona-data-collector/actions/runs/42411107420).
  Downloaded JUnit XML confirms **368 JVM cases, zero failures/errors/skips**;
  instrumentation XML confirms **248 cases, zero failures/errors, eight skips**.
  Gradle's live progress counter exceeded its expected count; XML totals, not that
  progress counter, are used here. This predates the final inset correction.
- Native iOS on `8e517cc` **passed all 355 unit and 18 UI cases, zero failures or
  skips**: [run 42425416880](https://github.com/Woona-Corp/woona-data-collector/actions/runs/42425416880).
  Compilation, Storage/AppShell, history removal/cancellation and accessibility
  landscape checks all ran on macOS/iPhone Simulator, not Linux or a physical iPhone.
- Earlier native iOS on `bb5118c` compiled and passed 355 unit cases, but only
  16 of 18 UI cases: [42411110881](https://github.com/Woona-Corp/woona-data-collector/actions/runs/42411110881).
  That earlier run is not reported as green.
- All 240 shared display translations match Android/iOS. Earlier iOS Python
  tooling ran 32 cases with one macOS-only class skipped on Linux.
- Kotlin/Swift LSP probes were inconclusive; auxiliary style warnings do not
  establish native-language correctness. Actual builds/tests are the evidence.

### Earlier failures retained for provenance

[Initial full CI, d04ec05](https://github.com/Woona-Corp/woona-data-collector/actions/runs/42397884937)
compiled iOS and ran 349 unit plus 18 UI cases, but failed three assertions.
Follow-ups corrected an obsolete primary-summary expectation, a changed details
label and a container accessibility identifier overriding the identity leaf.
A later Swift optional-fixture typing issue and four missing shared translations
were corrected in `9ca623c`. Stricter heart-session validation then exposed the
missing-array creation/edit regression; `bb5118c` fixed the commit boundaries,
with all 355 native unit cases subsequently passing.

Earlier Android CI failures included a system-owned ANR modal and SystemUI
navigation-bar NPE during rotation. Cleanup now preserves the primary failure
and independently restores keyboard/accessibility/orientation/font state.
The workflow adds bounded host/emulator failure diagnostics only: no test split,
new image, retry, filter or readiness gate. **Prevention of emulator crashes is
not claimed.** A full run on `deb9770` also passed
([42400547401](https://github.com/Woona-Corp/woona-data-collector/actions/runs/42400547401)).

## Physical Pixel and isolated API evidence

Only `com.woona.drivetest.review20261107` / “Woona UI Review” was used, with eight
explicitly synthetic replay fixtures. The existing manual-QA and signed field
installations were not cleared or replaced. Field version **1.5.7 / code 20**,
first-install and last-update timestamps were compared unchanged after testing.

An initial early build override produced the field package ID; Android rejected
that installation with signature mismatch. The override was corrected to
`androidComponents.finalizeDsl`. Every subsequent application ID and test target
was independently checked before installation. See
[phone guards](../../android/docs/PHONE_CHECKS.md); signature rejection is not an
acceptable protection plan.

### API integration — five passed

The final isolated local-server/proxy run executed **all five
`ServerApiClientIntegrationTest` methods: five passed, zero failed/skipped**,
63.339 seconds. Coverage included:

- account headers, data-scope isolation and explicit linking;
- recovery-artifact upload/download without changing original files;
- upload, restore, range/ETag and corruption/conflict protection;
- invalid-token failure shown as a human reason with raw evidence collapsed,
  followed by Details expansion and real WorkManager manual retry;
- persisted HTTP 503 retry, successful retry, nine-artifact delivery and receipt.

An earlier four-pass/one-fail run stopped at an obsolete assertion demanding the
raw token error before Details expansion. The corrected assertion retains the
raw-code check after expansion; the final five-pass run exercised the remaining
worker phases. The first disconnected attempt executed zero API cases and is
not counted as a pass.

Only the test project's loopback API/proxy, network and volume were used, then
removed. Existing services were left alone. Original review preferences and all
eight recording fixtures were restored and recursively compared byte-for-byte.

### UI correction and final physical subset — 17 passed

The initial physical subset ran **17 cases: 12 passed, five failed**. A controlled
comparison using `am instrument --no-window-animation` retained all assertions
and ran the eight viewport cases: three passed, five failed. Rotation-transformed
initial frames disappeared, but actual IME occlusion remained. Primary-failure
screenshots were captured before cleanup; these are private, synthetic evidence,
not repository attachments.

The delivered dialog-local IME inset was correct, but `ADJUST_RESIZE` left the
Android 16 / target-36 dialog at full height. Recorded examples:

- Portrait: root bottom 2305 minus IME inset 825 equals keyboard top **1480**.
- Landscape: root bottom 1021 minus inset 607 equals keyboard top **414**.

`667c07b` makes Compose own the insets and applies one root `safeDrawingPadding`
union around the whole server/questionnaire dialog. Native parent measurement
is retained; fixed actions remain outside the shrinking scroll body. No display
height arithmetic, hardcoded keyboard padding or duplicated navigation inset.
The test adds a bounded accessibility-idle barrier after rotation, not polling
until assertions pass; this alone is not a compositor-animation guarantee.

The corrected physical run used **ordinary system animations**, not the
comparison flag, and passed **all 17 cases, zero failures/skips**, 70.138 seconds:

| Group | Passed |
| --- | ---: |
| RU/EN × portrait/landscape × font 1.1/1.8, real regular IME | 8 |
| Compact questionnaire | 3 |
| Sync details | 4 |
| Account controls | 1 |
| Multiple-surfaces session regression | 1 |

Domain files and preferences compared byte-for-byte unchanged before/after this
run. Font **1.1**, auto-rotation **1**, user rotation **0** and USB keep-awake **0**
were verified restored; the review process was stopped. The owner was told the
phone could be disconnected. This verifies action visibility in those tested
configurations, not every editing end state or theme/device combination.

### Focused-editor acceptance, beyond passing action tests

Independent visual review of the 24 saved matrix frames found an additional
blind spot: all eight Notes end states failed to show the insertion end after
multiline input; several landscape server frames hid or clipped the active
field. The action-only 17-pass result above is therefore **not evidence that
focused editing was fully usable**.

The follow-up uses a compact, wide title/actions row and preserves one stable
form composition. A bounded multiline trial exposed a Compose 1.7 internal-scroll
limitation: an unchanged cursor can remain below the viewport when only its
container shrinks. The inspected 1.7.8 implementation has the same update logic;
a blind patch-version bump is not presented as a fix.

The multiline candidate instead keeps natural text height with one parent form
scroll owner. Public `BasicTextField` plus Material decoration supplies the actual
text layout; synchronous raw draft updates preserve selection/composition. A
geometry-driven request brings a conservative cursor interval (actual cursor line
plus measured non-text height) into view on selection/layout/viewport changes.
Single-line fields retain their existing implementation. Long Notes labels can
legitimately scroll above the viewport; the current insertion line must remain
visible, with title/actions reachable. No selection pokes, timer-driven fixes,
internal tooling APIs or new dependencies are used.

The stronger matrix verifies focus, exact value/selection and password masking;
token checks require full field geometry above the IME, while natural Notes
checks require actual cursor-interval containment in the rendered clip and native
IME-safe window. Password Save separately checks the exact raw synthetic token.
The token now requests a password keyboard with autocorrection disabled: visual
masking alone had left the raw test word visible in IME suggestions.

Caret acceptance has a separate mandatory visual gate: inspect all eight token
and eight Notes end-state frames, including the final `End`/insertion line. A
`manual-caret-review-required.txt` output makes clear that automated success is
not this visual acceptance. Compose 1.7 character extra-data proved unreliable:
whole arrays can be absent, and raw paragraph coordinates omit internal scroll
translation, reporting a null glyph even when `End` and its caret are visibly
rendered. That API remains nonsecret diagnostic evidence, not a false pass/fail
oracle. No reflection, Kotlin-internal tooling APIs or new dependencies were
introduced to manufacture automatic caret proof. Primary screenshots and bounds
metadata are preserved; unsupported provider output is not counted as a skipped
test or as proof that a caret is visible.

The natural-editor follow-up continued on **2026-11-08 UTC**. Its local API 31
matrix passed **8/8**, zero skips, at `01:10:47` (90.338 seconds); JVM XML totals
are **368 passed**, and lint passed. All 16 Notes early/late samples validate an
independent native-decor root anchor and conservative cursor-interval containment.
These are not 32 root-anchor checks: the 16 token samples use their separate
whole-field geometry criteria.

Independent review of all 24 exact-source frames remains **incomplete**: all three
landscape 1.8 EN images contain an unexplained opaque white region spanning app
and keyboard pixels. Seven Notes configurations show the complete final `End`
line; six of those capture the caret ON and one does not. Seven focused token
frames show the complete mask line and no raw-token suggestions; five capture the
caret ON, two do not, and the eighth configuration is obscured. An absent cursor
in a still frame is not positive caret evidence. Initial nonfocused content may
legitimately extend below the scroll viewport.

An earlier trial showed the white region in RU instead. Native roots/window
geometry and lifecycle logs did not establish a late Activity replacement or the
cause of those pixels; recorded emulator graphics fallback/jank also occurred in
good cases. No speculative renderer/AVD mitigation was added and no graphics fix
is claimed. Final-source full CI, independent visual evidence and physical review
remain publication gates; the automated eight-pass result alone does not close
them.

A disposable API 31 emulator also displayed Android's first-use immersive hint.
The optional `woonaDisposableEmulator=true` matrix fixture independently requires
`ro.kernel.qemu=1`, snapshots the original nullable secure confirmation value,
acknowledges only that known onboarding before any per-case activity, then
restores and verifies the original after all cases. Only managed full mode opts
in. Physical direct instrumentation without the argument changes no such setting.
This is not dismissal of an ANR, permission prompt or arbitrary failed-test modal,
and does not claim prevention of SystemUI crashes.

## iOS layout correction and native rerun

The two remaining `bb5118c` UI failures were investigated from native frames and
screenshots, not dismissed as fixtures:

- At the end of history, Remove stayed at y=790.7–811 under custom navigation
  beginning at y=764.3, unchanged across repeated swipes. This was a real scroll
  viewport defect. `667c07b` lays out tab content and custom navigation as dynamic
  `VStack` siblings, retaining native TabView state and capture/recovery guards.
  No fixed tab-height spacer or historical data changes.
- Large-text landscape app-wide swipes started over navigation rather than the
  scrollable content. Tests now gesture within the measured unobscured viewport
  and require the full target frame plus actual hittability. Confirmation,
  cancellation, raw-diagnostic, large-text and landscape assertions remain.

The first root-layout reruns passed history removal and all 355 unit cases, but
one landscape test still failed: its flick moved the heading between y336 and
approximately y0, skipping the valid y78–296 viewport. `8e517cc` replaces that
flick with a frame-guided, bounded slow drag and finger hold at the destination,
not extra sleeps, more attempts or weaker assertions. The subsequent full native
run passed all 373 cases as linked above.

Final Android regression and physical focused-editor review after the additional
editing correction remain separate requirements. Successful earlier-source or
action-only runs must not be reported as passes of the stronger corrected-source
editing criteria; use the PR's checks and linked final evidence.

## Limits and release gate

Offline workspace inventory was rerun and all 22 workspace script tests passed.
The root documentation validator remains blocked by unrelated unpublished links
in `Operations/panels/README.md` to `recording_hours.sql` and
`Operations/test_recording_hours.py`. Those independent workspace edits were not
changed or staged as part of the mobile fix.

No physical iPhone, Android/iPhone BLE, camera, process-death or sensor-quality
verification is supplied by these software runs. Synthetic replay and local API
success must not be presented as physical acquisition or clinical evidence.
No backup job or off-host backup transfer was enabled.

Keep the PR as a candidate until corrected-source Android/native iOS checks and
required visual/integration checks pass. Publish Android and iOS independently
only after their distribution gates. A prepared version number is not a release,
TestFlight upload, tester invitation or physical-device verification.
