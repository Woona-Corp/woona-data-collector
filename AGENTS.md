# Agent rules

- This workspace contains native Android and iOS clients plus the shared
  server/contracts in `shared/`. Do not add cross-platform UI scaffolding,
  remotes, or CI unless explicitly requested.
- Inspect `git status` first. Preserve unrelated dirty-worktree changes and keep
  diffs minimal.
- Keep the current single Android `app` module under `android/`. Reuse existing
  code and dependencies before adding abstractions or libraries.
- Respect boundaries: `ble` owns transport/GATT, `protocol` owns pure packet
  logic, `storage` owns files/exports, `data` owns SQLite and recording metadata,
  and Compose UI only renders state and emits actions.
- Every behavior change needs the smallest relevant runnable test. Run
  `./android/tools/check.sh fast`; run `full` for SQLite, Compose, preferences,
  or fake-BLE instrumentation changes.
- For shared server or Compose changes, validate from `shared/` with
  `docker compose config` and the relevant server tests.
- Keep iOS native and dependency-free: reuse SwiftUI, CoreBluetooth,
  AVFoundation, URLSession, CryptoKit, Keychain and system SQLite3. An iOS
  build/test result requires macOS with Xcode; Linux static checks are not a
  substitute.
- Preserve explicit shutdown/finalization for BLE, replay, packet writers,
  video, and recording state. Do not trade data safety for a smaller diff.
- Emulator tests never prove real BLE behavior, camera behavior, `video.mp4`
  quality, or hardware synchronization. Report those as physical-device checks.
- Treat client/server contract updates as one release: deploy and verify the
  compatible production API and migrations before distributing dependent mobile
  builds; update affected clients when a server change requires it.
- Release Android and iOS independently using `android-v*` and `ios-v*` tags.
  Platform-specific fixes and marketing/build versions may ship separately.
  Maintain the same UI/UX and functionality across both clients: screen order,
  labels, visible actions, selection, validation, loading/error states and navigation
  must match. Android is the baseline for current alignment; consult
  `shared/UI_UX_CONTRACT.md` before changing either client. Preserve compatible shared contracts;
  track any temporary feature gaps explicitly. Verify TestFlight upload and Apple
  processing before claiming tester availability.

## Agent workflow

1. Read `README.md` and `ARCHITECTURE.md`, then inspect the relevant client or
   server code and its callers before editing. Keep Android, iOS, and server
   contracts in sync when a shared format changes.
2. Do not commit `.env`, credentials, signing keys, `android/dist/`, local
   databases, recordings, or generated build outputs. Do not put a server
   bearer token in a release APK.
3. Use `./android/tools/check.sh fast` for Android work; use `full` for the
   instrumentation areas above. For server/Compose work, run `docker compose
   config -q` and the relevant tests from `shared/`. iOS tests run only on
   macOS/Xcode. State the exact checks and limitations in the final report.
4. `.github/workflows/mobile.yml` owns cross-platform CI and Android releases
   (`android-v*`); `.github/workflows/testflight.yml` owns iOS distribution
   (`ios-v*` or a manual run). Keep GitHub Actions permissions minimal and
   distinguish debug artifacts from signed releases and TestFlight builds.
