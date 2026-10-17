# Woona Data Collector

[CI](https://github.com/ashromanov/woona-data-collector/actions/workflows/mobile.yml) · [Releases](https://github.com/ashromanov/woona-data-collector/releases) · [Agent guide](AGENTS.md)

Native Android 12+ and iOS 17+ apps for dog profiles, questionnaires, BLE sensor recordings, optional synchronized video, offline storage, and resumable server sync. The shared FastAPI service stores metadata in PostgreSQL and recording files on disk. See [Architecture](ARCHITECTURE.md) for the data flow and [the shared contracts](shared/docs/target-server-plan/README.md) for schemas and API details.

Heart sessions, the separate post-recording questionnaire, and manual ECG/HR/reference uploads are documented in [Heart recordings](shared/HEART_RECORDINGS.md).

Operator accounts and post-recording questionnaire edits in 1.3.5 are documented in [Accounts](shared/ACCOUNTS.md).

The production labeling stack, canonical recordings, and annotation counts are documented in [Label Studio deployment](shared/LABEL_STUDIO.md).

Daily full backups and resumable off-host verification are documented in [Backup operations](shared/operations/backups/README.md). `./woona status` shows production health and backup state; `./woona check server` and `./woona check android` run local checks. The optional Windows/Clinic commands require the full Woona workspace.

| Directory | Contents |
| --- | --- |
| [`android/`](android/) | Single-module Kotlin/Compose app, Gradle wrapper, tests, and SDK setup |
| [`ios/`](ios/) | SwiftUI app, Xcode project, and XCTest suite; no third-party packages |
| [`shared/`](shared/) | FastAPI, PostgreSQL Compose stack, contracts, and server tests |
| [`AGENTS.md`](AGENTS.md) | Boundaries and verification instructions for coding agents |

## Run locally

**Android:** Install JDK 21 and the Android SDK, then open `android/` in Android Studio or use:

```bash
./android/tools/setup-android-sdk.sh
./android/tools/check.sh fast
```

The debug APK is `android/app/build/outputs/apk/debug/app-debug.apk`. The `full` check adds the API 31 managed emulator suite. The local server address in the debug build is `http://10.0.2.2:8080`; configure an HTTPS server URL and a device token in the app for a physical phone.

For physical-phone sync tests, start an isolated Compose project with fresh storage:

```bash
mkdir -p /tmp/woona-phone-e2e/storage
sudo chown -R 10001 /tmp/woona-phone-e2e/storage
WOONA_API_PORT=18088 WOONA_STORAGE_ROOT_HOST=/tmp/woona-phone-e2e/storage \
  docker compose -p woona-phone-e2e -f shared/compose.yaml up -d --build --wait
```

Start `python android/tools/e2e-fault-proxy.py` in another terminal; it forwards to that local API and injects one-shot HTTP 503, read timeout, and compressed-ETag responses. Build an isolated diagnostic package to preserve an installed signed field app and its recordings:

```bash
cat > /tmp/woona-e2e.gradle <<'EOF'
allprojects { plugins.withId('com.android.application') { androidComponents.finalizeDsl { dsl -> dsl.defaultConfig.applicationId = 'com.woona.drivetest.diagnostics' } } }
EOF
./android/gradlew -p android -I /tmp/woona-e2e.gradle assembleDebug assembleDebugAndroidTest
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb reverse tcp:18088 tcp:18088
adb reverse tcp:18089 tcp:18089
adb shell am instrument -w -r \
  -e class com.example.myapplication.sync.ServerApiClientIntegrationTest,com.example.myapplication.video.AndroidVideoRecorderDeviceTest \
  -e serverBaseUrl http://127.0.0.1:18088 \
  -e serverToken change-me-local-token \
  -e serverFaultBaseUrl http://127.0.0.1:18089 \
  com.woona.drivetest.diagnostics.test/androidx.test.runner.AndroidJUnitRunner
```

The tests cover all eight artifact types, Polar CSV files, live/replay/failed recordings, SQLite restore, upload/download resumption, integrity checks, real WorkManager retry, and physical camera capture with mock BLE. Optional `serverSecondaryToken` and `serverRevokedToken` instrumentation arguments exercise another device's upload ownership and revoked credentials; provision these only in the isolated server using `server.device_admin`. Production diagnostics are read-only and separately opt in through a privately supplied `cache/connection-test.token`.

**iOS:** On macOS with Xcode, open `ios/Woona.xcodeproj` and run the shared `Woona` scheme. To run tests from the terminal, choose an available simulator:

```bash
xcodebuild -project ios/Woona.xcodeproj -scheme Woona \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 16' test
```

See [the iOS guide](ios/README.md) for device signing and feature details. iOS cannot be built or tested with Xcode on Linux.

**Shared server:** Docker Compose binds the API to localhost and does not publish PostgreSQL. Keep `.env` out of Git and replace its local-only credentials before any network deployment.

```bash
cd shared
cp .env.example .env
mkdir -p ../var/storage
sudo chown -R 10001 ../var/storage # API container runs as UID 10001
docker compose config -q
docker compose up -d --build --wait
curl http://127.0.0.1:8080/health/ready
docker compose exec -T api python -m unittest -v server.tests.test_schemas server.tests.test_api
```

The Android emulator reaches the host at `10.0.2.2`; a phone needs a reachable HTTPS endpoint. [Server operations](shared/docs/target-server-plan/operations.md) covers deployment and backups.

## Checks and releases

Every push to `main` and every pull request runs Android unit tests, lint, a signed debug APK build, iOS simulator tests, and the Docker-backed server/API suite. The [workflow](.github/workflows/mobile.yml) also runs for `v*` tags. It publishes a GitHub Release only after all three jobs pass:

- `Woona-Android-release.apk` is signed with the field release key and can update an existing field installation. Tagged builds require the four Android signing secrets below. Branch builds publish a debug APK for development.
- `Woona-iOS-simulator.zip` contains the tested simulator `.app`. It is **not** an iPhone IPA; distributing an iPhone build requires Apple signing and an Xcode archive.
- SHA-256 files accompany both artifacts. Local APKs in `android/dist/`, `.env`, and server data are ignored by Git.

Before tagging, update Android `versionCode`/`versionName` and iOS `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION`, then push a `v*` tag. Configure `ANDROID_KEYSTORE_BASE64`, `ANDROID_SIGNING_STORE_PASSWORD`, `ANDROID_SIGNING_KEY_ALIAS`, and `ANDROID_SIGNING_KEY_PASSWORD` as GitHub Actions secrets for a signed Android release. Do not embed a server token in a distributable APK; users enter it in app settings.

```bash
git tag -a v1.3.0 -m 'Woona 1.3.0'
git push origin v1.3.0
```

Emulator and simulator checks cover software behavior. Real BLE, camera capture, `video.mp4` quality, and hardware synchronization still require tests with the target sensor and physical phones. Prior local acceptance notes are in the [acceptance report](shared/docs/target-server-plan/acceptance-report.md); they are historical results, not proof of a new release.
