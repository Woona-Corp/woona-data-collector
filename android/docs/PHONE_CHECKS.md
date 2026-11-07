# Physical-phone diagnostics

Run from the repository root. Use an isolated server and a separate app ID to
preserve the installed field app and its recordings. These checks use mock BLE;
a passing result does not verify the real sensor or hardware synchronization.

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

Run the Android software checks separately: `./android/tools/check.sh fast`
and `./android/tools/check.sh full`.
