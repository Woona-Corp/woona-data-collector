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

### Important limits

- Test results and publication status belong to the exact build and must be
  verified separately for each platform. Simulator/emulator or mock-BLE tests do
  not establish real sensor, camera, background capture or clinical acceptance.
- iOS TestFlight upload is not App Store publication or proof of tester access.
- Some historical uploads remain incomplete. A changed capture manifest can be
  rejected with 409; do not delete originals or bypass conflict checks. Resolve
  affected recordings with their original device and reviewed server metadata.
- Profiles under a different account may produce a 404. Select the intended
  account and restore its metadata; do not delete or recreate local profiles.
- The compatible production server schema is `0009`. This mobile release does
  not require a new server migration. Server backups remain disabled by the
  owner's decision; manual on-device archive export does not enable backup jobs.
