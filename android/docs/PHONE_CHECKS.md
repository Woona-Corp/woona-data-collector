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
# Never trust the build command alone: verify BOTH targets before any installation.
set -euo pipefail
QA_ID=com.woona.drivetest.diagnostics
APK_ANALYZER="${ANDROID_HOME:?Set ANDROID_HOME}/cmdline-tools/latest/bin/apkanalyzer"
test "$("$APK_ANALYZER" manifest application-id android/app/build/outputs/apk/debug/app-debug.apk)" = "$QA_ID"
test "$("$APK_ANALYZER" manifest application-id android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk)" = "${QA_ID}.test"
"$APK_ANALYZER" manifest print android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk | python3 -c 'import sys,xml.etree.ElementTree as E; r=E.parse(sys.stdin).getroot(); assert r.find("instrumentation").get("{http://schemas.android.com/apk/res/android}targetPackage") == sys.argv[1]' "$QA_ID"
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

A successful Gradle build is not proof of an isolated package ID: an override
applied before the application DSL finishes may be overwritten by the app build
script. Keep the `androidComponents.finalizeDsl` override and the independent APK
checks above. Never rely on signature rejection to protect the field installation;
never uninstall or clear it to make a diagnostic APK install. With multiple ADB
devices, add the explicit test-device `-s SERIAL` to every ADB command.

Run the Android software checks separately: `./android/tools/check.sh fast`
and `./android/tools/check.sh full`.

## Focused editing and managed-emulator setup

`QaUiViewportMatrixTest` covers RU/EN, portrait/landscape and system font scales
1.1/1.8 with a real regular IME. It checks action readability, retained focus,
value/selection and the complete editable field above the IME. Its 24 end-state
screenshots also require independent visual review: confirm the active masked
token and the final `End`/caret in all eight Notes cases. A green action/field
suite alone is not that manual caret acceptance. Compose 1.7 native character
extra-data is diagnostic only: its outer-node mapping can omit inner scrolling.
Use a fresh additional-output directory so stale failure frames cannot be
mistaken for the current run; preserve primary failure evidence before cleanup.

Managed `full` mode explicitly passes `woonaDisposableEmulator=true`. Only the
matrix's class fixture uses it: it independently verifies `ro.kernel.qemu=1`,
snapshots Android's first-use immersive confirmation value, acknowledges that
known hint before testing, then restores and verifies the original after the
class. It never dismisses an ANR, permission prompt or arbitrary modal. Do not
pass this argument to a physical phone. Direct physical instrumentation without
the argument performs no such secure-setting mutation. Keep ordinary animations
for final physical acceptance; `--no-window-animation` is a separately reported
controlled comparison, not a production fix or substitute for that acceptance.
