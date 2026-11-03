# Woona mobile release notes

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
