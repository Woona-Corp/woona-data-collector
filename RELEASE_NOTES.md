# Woona mobile release notes

## Android 1.5.9 / iOS 1.5.9 — 2026-11-12

- Preserve resumable upload declarations when a questionnaire is edited after a
  partial upload. Restored unfinished recordings return to the pending queue,
  stale missing-resource retries can recover after account linking, and completion
  receipts are retained before optional metadata refreshes.
- Keep incomplete server recordings retryable on iOS and preserve safe identity
  conflict diagnostics, including request ID and next action, without enabling an
  automatic retry loop for Animal ID conflicts.
- Android packet assembly validates before scanning, supports bounded lookback
  resynchronization and records actual rejection details. BLE connection callbacks
  and capture counters retain more diagnostic context. Diagnostic log bytes are
  frozen before their size and checksum are declared to the server.
- Android complete-archive Share reuses the prepared ZIP and offers Save; closing
  or dismissing the sheet removes only that prepared copy, never source captures.
  Sync details prefer local or combined diagnostics with a remote fallback.
- Server diagnostics distinguish aborted uploads and committed chunks, propagate a
  normalized request ID through Caddy, and rotate container logs. Persisted
  SHA-bound fingerprints avoid rereading unchanged large videos during no-op
  normalization and presentation checks. PostgreSQL uses an init process and
  FileBrowser has a health check.
- Wire formats and server schema `0009` are unchanged. Original capture files and
  capture-device ownership checks are preserved; no backup job is enabled.

## Android 1.5.8 / iOS 1.5.8 — 2026-11-09

- Prevent creating another local dog card with an already used animal ID,
  including historical aliases and cards in other data accounts. Comparison is
  pinned to the deployed Python 3.13 / Unicode 15.1 behavior on both platforms;
  existing UUIDs and questionnaire content hashes are not rewritten or merged.
- Explain identity conflicts inline while preserving the questionnaire draft.
  Local commits continue through asynchronous server validation; absent server
  configuration preserves queued work instead of stranding it as a permanent
  failure. A known server conflict still requires an explicit correction.
- Separate exact-version profile acknowledgement, local capture, server delivery,
  file progress and technical evidence. Diagnostic payloads are collapsed and
  redacted before storage/presentation, including credentials and signed URL data.
- Add bounded actual sync events and read-only local capture-log previews. The
  journal retains at most 128 recent installation events and displays 20 matching
  events per item; it is best-effort diagnostics, not a complete durable audit.
  Process exit may lose pending journal writes without losing the domain queue.
- Account linking invalidates the former scope's profile confirmation and queues
  validation of the current version. Existing recordings/files remain intact.
- Keep editing actions reachable around the keyboard and large-text landscape
  layouts. Android multiline editing uses the parent form scroll and actual
  cursor-region relocation instead of relying on a stale nested-editor offset;
  iOS content reserves the actual custom-navigation height.
- Android token entry requests a password keyboard with autocorrection disabled,
  in addition to visual masking; ordinary text-keyboard suggestions must not echo
  the entered credential.

### Release verification and distribution

- Android `android-v1.5.8`: signed field-key APK (version code 21) and checksum
  [published](https://github.com/Woona-Corp/woona-data-collector/releases/tag/android-v1.5.8);
  downloaded bytes, signature, version and empty embedded token verified.
- iOS `ios-v1.5.8`: build **14401** uploaded; Apple processing **VALID**, nonexpired,
  **IN_BETA_TESTING**, assigned to the existing internal group with two testers.
  This verifies internal availability, not an installation, invitation, external
  testing or App Store publication.
- Exact-release Android full CI: **368 JVM passed; 240 instrumentation passed,
  eight opt-in skips, zero failures/errors**. Native iOS: **355 unit +18 UI passed**.
  An additional local full run had one no-Compose-hierarchy failure; the single
  exact-tag CI comparison passed, without erasing or explaining that local failure.
- [Detailed runs, assets, physical/visual evidence and remaining limitations](shared/docs/qa-identity-sync-20261107.md#distribution-evidence--2026-11-09).
  Real BLE/camera/background and physical-iPhone acceptance remain separate.
  No server API/schema migration, production deployment or backup job was needed.

## Android 1.5.5 / iOS 1.5.5

- iOS: fence camera preparation/start/stop ownership, validate completed video
  before admitting it as a recording artifact, and retain the first Stop's
  timing and validated video through a local finalization retry.
- Harden packet boundary handling and artifact validation. Android session
  CSV export rejects mismatched or damaged timelines rather than reporting a
  successful export; original source files are retained. Session ZIP manifests
  correctly escape control characters in metadata.
- Keep unsaved server URL/token edits in memory only, and clear them when the
  editor is dismissed. Improve compact-screen, landscape and large-text
  questionnaire/settings controls without changing saved questionnaire formats.
- Android: explicitly exclude app data from cloud backup and device transfer;
  no backup service is enabled. Validate only active heart-questionnaire details
  while retaining inactive draft text when an answer is changed back.
- Compatible server hardening bounds upload admission and Label Studio summary
  waits, and preserves retryable recording imports. Storage, wire and API formats
  and schema revision `0009` remain unchanged. Deploy and verify the compatible
  server before distributing these clients.

### Release verification and limits

- Prior regression evidence: Android 332 JVM tests passed; clean API 31 emulator
  instrumentation had 220 passed and 8 explicit skips. iOS native CI had 321 unit
  and 17 UI tests passed; a later stronger landscape case also passed. Candidate
  PR CI must verify the versioned source separately; these are not delivery or
  physical-device acceptance claims.
- Real BLE, camera/MP4 quality, background capture and hardware synchronization
  still require target sensors and physical phones. Existing storage-failure and
  historical-upload limitations below continue to apply.
- Android signed delivery and iOS TestFlight upload are separate release gates.
  iOS is for the existing internal TestFlight group only; Apple processing and
  group availability must be verified after upload. No invitations, external
  testing or App Store submission are included.

## Android 1.5.2 / iOS 1.5.3

Changes since the Android 1.4.0 stable release and the 1.5.x internal builds:

- Fix complete local ZIP creation when the temporary archive directory is inside
  an excluded cache/temporary root. Local source files are not deleted.
- Android: after preparing the archive, choose a destination in the system file
  picker or share it. iOS uses the system share sheet, including Save to Files.
  The archive contains locally available data only, excludes access tokens and
  requires temporary free space on the device. Interrupted saving may leave an
  incomplete file at the chosen destination.
- Localized Russian/English questionnaire text and validation; historical answers
  and user-entered text are not translated or replaced.
- Bounded, paged local recording history and clearer server storage, upload and
  restore statuses. Heart questionnaire prompts are tied to the actual capture.
- V2 sensor preview is separate from recording and does not save a session.
  SD-card download and phone acknowledgements are not included.
- Android debug replay no longer fails merely because Bluetooth scan permission
  is missing, does not request video, and is not shown in release builds.
- Android: stopping a recording now waits for queued packet processing and local
  finalization before disconnecting. Temporary SQLite contention is retried; an
  unfinished heart recording is considered for its questionnaire after restart.
  A queue overflow or packet storage failure marks the recording failed rather
  than silently reporting it complete; recoverable fragments after a storage
  failure are saved separately.
- Android: stop and retry no longer reopen Polar CSV files for a finalized capture.
  A Polar storage failure is reported as failed, and remaining original files are
  retained. After a Polar reconnect, callbacks from the replaced Bluetooth
  connection can no longer change the new connection's setup, counters or status,
  and a delayed notification cannot complete setup for streams that never started. Questionnaire conflict details and actions remain scrollable on
  compact screens, including when the keyboard reduces the available space.

### Important limits

- Test results and publication status belong to the exact build and must be
  verified separately for each platform. Simulator/emulator or mock-BLE tests do
  not establish real sensor, camera, background capture or clinical acceptance.
- iOS TestFlight upload is not App Store publication or proof of tester access.
- Packet recovery files can overlap partially written originals and may not
  include data lost before the failure was detected. A storage failure can leave
  fragments only in memory until the recovery file is saved; keep the app open,
  free space and retry. Neither process death nor power-loss durability is
  guaranteed. Restart the app before recording again after packet recovery.
- A Polar write failure can leave a partial CSV and lose samples still in memory;
  existing file bytes are not overwritten, and a failed capture is not evidence
  of a complete physiological recording. Restart the app before recording again.
- A damaged packet file or a packet storage failure can prevent the individual
  session ZIP from being generated. Use the complete data archive to preserve
  originals for investigation; it does not repair them or establish completeness.
- Some historical uploads remain incomplete. A changed capture manifest can be
  rejected with 409; do not delete originals or bypass conflict checks. Resolve
  affected recordings with their original device and reviewed server metadata.
- Profiles under a different account may produce a 404. Select the intended
  account and restore its metadata; do not delete or recreate local profiles.
- The compatible production server schema is `0009`. This mobile release does
  not require a new server migration. Server backups remain disabled by the
  owner's decision; manual on-device archive export does not enable backup jobs.
