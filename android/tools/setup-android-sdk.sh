#!/usr/bin/env bash
set -euo pipefail

mode="${1-full}"
case "$mode" in
    fast|full) ;;
    *) echo "Usage: $0 [fast|full]" >&2; exit 2 ;;
esac
[[ "$#" -le 1 ]] || { echo "Usage: $0 [fast|full]" >&2; exit 2; }

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"

if [[ ! -x "$sdkmanager" ]]; then
    command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
    command -v unzip >/dev/null || { echo "unzip is required" >&2; exit 1; }
    command -v sha256sum >/dev/null || { echo "sha256sum is required" >&2; exit 1; }
    [[ ! -e "$sdk_root/cmdline-tools/latest" ]] || {
        echo "Incomplete SDK tools at $sdk_root/cmdline-tools/latest" >&2
        exit 1
    }

    setup_tmp="$(mktemp -d)"
    trap 'find "$setup_tmp" -depth -delete' EXIT
    tools_zip="$setup_tmp/commandlinetools.zip"
    curl -fL --retry 3 \
        -o "$tools_zip" \
        "https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip"
    echo "4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583  $tools_zip" |
        sha256sum -c -
    unzip -q "$tools_zip" -d "$setup_tmp/unpacked"
    mkdir -p "$sdk_root/cmdline-tools"
    mv "$setup_tmp/unpacked/cmdline-tools" "$sdk_root/cmdline-tools/latest"
fi

export ANDROID_HOME="$sdk_root"
export ANDROID_SDK_ROOT="$sdk_root"

{ yes || true; } | "$sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null
packages=(
    "platform-tools"
    "platforms;android-36.1"
    "build-tools;36.0.0"
    "build-tools;36.1.0"
)
if [[ "$mode" == full ]]; then
    packages+=("emulator" "system-images;android-31;google_apis;x86_64")
fi
"$sdkmanager" --sdk_root="$sdk_root" "${packages[@]}"

printf 'sdk.dir=%s\n' "$sdk_root" > "$project_root/local.properties"
echo "Android SDK ready at $sdk_root"
