#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-fast}"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"

case "$mode" in
    fast|full) ;;
    *) echo "Usage: $0 fast|full" >&2; exit 2 ;;
esac

[[ -f "$project_root/local.properties" ]] || {
    echo "Run ./tools/setup-android-sdk.sh first" >&2
    exit 1
}

export ANDROID_HOME="$sdk_root"
export ANDROID_SDK_ROOT="$sdk_root"
cd "$project_root"

if [[ "$mode" == full ]]; then
    command -v pgrep >/dev/null || { echo "pgrep is required for managed-device cleanup" >&2; exit 1; }
    snapshot_probe_pattern="^$sdk_root/emulator/qemu/linux-x86_64/qemu-system-x86_64-headless @dev31_google_apis_x86_64_Pixel_2 .* -check-snapshot-loadable default_boot$"
    mapfile -t existing_snapshot_probes < <(pgrep -f "$snapshot_probe_pattern" || true)
    cleanup_snapshot_probes() {
        local pid
        for pid in $(pgrep -f "$snapshot_probe_pattern" || true); do
            case " ${existing_snapshot_probes[*]} " in
                *" $pid "*) ;;
                *) kill -KILL "$pid" 2>/dev/null || true ;;
            esac
        done
    }
    trap cleanup_snapshot_probes EXIT
fi

tasks=(testDebugUnitTest lintDebug assembleDebug)
managed_args=()
if [[ "$mode" == full ]]; then
    tasks+=(woonaApi31DebugAndroidTest)
    # A disposable emulator may show Android's first-use immersive hint over
    # the matrix. Its class fixture verifies qemu independently, acknowledges
    # only that hint before testing, then restores the original secure value.
    managed_args+=(-Pandroid.testInstrumentationRunnerArguments.woonaDisposableEmulator=true)
fi
./gradlew "${tasks[@]}" "${managed_args[@]}" --max-workers=4 --no-daemon --console=plain

apk="app/build/outputs/apk/debug/app-debug.apk"
apksigner="$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 -type f -name apksigner | sort -V | tail -n 1)"
[[ -n "$apksigner" ]] || { echo "apksigner not found in $sdk_root" >&2; exit 1; }

signature="$("$apksigner" verify --verbose --print-certs "$apk")"
grep -Fq "Verified using v2 scheme (APK Signature Scheme v2): true" <<<"$signature"
grep -Fq "CN=Android Debug" <<<"$signature"
printf '%s\n' "$signature"
