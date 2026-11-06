# Woona Data Collector

Project documentation and wiki: [AFFiNE](https://159.223.239.217/workspace/8f9b801d-6f90-40a6-a70f-723db87d0355/25df5d8c-5468-5202-8364-1e43df703344).

Native Android 12+ and iOS 17+ apps for dog profiles, questionnaires, BLE recordings,
optional video and offline sync. FastAPI stores metadata in PostgreSQL and artifacts
on disk. Android and iOS share the same [UI/UX contract](shared/UI_UX_CONTRACT.md)
and release independently.

[CI](https://github.com/Woona-Corp/woona-data-collector/actions/workflows/mobile.yml) ·
[Releases](https://github.com/Woona-Corp/woona-data-collector/releases) ·
[Agent rules](AGENTS.md)

## Start here

| Task | Guide |
| --- | --- |
| Understand the system and module boundaries | [Architecture](ARCHITECTURE.md) |
| Accounts, heart sessions and reference uploads | [Accounts](shared/ACCOUNTS.md), [heart recordings](shared/HEART_RECORDINGS.md) |
| Build, sign or test iOS | [iOS guide](ios/README.md) |
| Test Android sync and camera on a phone | [Isolated phone checks](android/docs/PHONE_CHECKS.md) |
| Deploy and identify the running server | [Operations](shared/docs/target-server-plan/operations.md), [build inputs](shared/server/DEPENDENCY_BUILD.md), [provenance](shared/server/DEPLOYMENT_PROVENANCE.md) |
| Find schemas, API notes and earlier acceptance results | [Contracts and plan index](shared/docs/target-server-plan/README.md) |
| Inspect production labeling | [Label Studio](shared/LABEL_STUDIO.md) |

Backups remain **disabled** by the owner's decision of 27 October 2026.
Setup and updates must preserve the [backup policy](shared/operations/backups/README.md).
`./woona status` reads production health; `./woona check server` and
`./woona check android` run local checks. Windows/Clinic checks need the full workspace.

## Run locally

**Android:** Install JDK 21, then prepare the SDK and build/test the single `app` module:

```sh
./android/tools/setup-android-sdk.sh fast
./android/tools/check.sh fast
```

APK: `android/app/build/outputs/apk/debug/app-debug.apk`. For the API 31 managed
emulator suite, run SDK setup and checks with `full`. SDK setup defaults to `full`.
Debug uses `https://cool-trams.digital` without an embedded token. For a local API,
set `http://10.0.2.2:8080` in the emulator; phones need reachable HTTPS and a device token.

**iOS:** On macOS/Xcode, open `ios/Woona.xcodeproj`, choose the `Woona` scheme and
an available simulator or signed device. [Test and distribution commands](ios/README.md).

**Shared server:** From the repository root:

```sh
cd shared
cp .env.example .env
mkdir -p ../var/storage
sudo chown -R 10001 ../var/storage
docker compose config -q
docker compose up -d --build --wait
curl http://127.0.0.1:8080/health/ready
docker compose exec -T api python -m unittest discover -v -s server/tests
```

The API binds to localhost; PostgreSQL is private. Keep `.env` out of Git and
replace local credentials before network deployment. The API runs as UID 10001.

## Checks and releases

Pushes to `main` and pull requests use the [changed-path CI policy](.github/ci/POLICY.md).
Unknown diffs, shared contracts/fixtures/workflows, tags and manual distribution
scopes retain broad checks. The large ZIP64 fixture defaults to enabled.

| Platform | Before tagging | Trigger and output |
| --- | --- | --- |
| Android | Commit `versionCode` and `versionName` in `android/app/build.gradle.kts` | `android-v*`: tests/lint, server tests, signed APK and SHA-256 in GitHub Releases |
| iOS | Commit app `MARKETING_VERSION` in `ios/Woona.xcodeproj/project.pbxproj` | `ios-v*` or manual TestFlight workflow: simulator tests, signed archive, Apple upload; CI sets the build number |

Push the version commit before its tag. Legacy `v*` tags do not release mobile
builds; pushes to `main` run CI without distribution. For contract changes, deploy
and verify a compatible server before shipping dependent clients; retain support
for installed clients during rollout.

Android signing needs `ANDROID_KEYSTORE_BASE64`, `ANDROID_SIGNING_STORE_PASSWORD`,
`ANDROID_SIGNING_KEY_ALIAS` and `ANDROID_SIGNING_KEY_PASSWORD`. The field-key
`Woona-Android-release.apk` updates field installations; branch artifacts are
`Woona-Android-debug.apk`. Distributable APKs must contain no server token.
[iOS signing and Apple processing checks](ios/README.md) are separate.

Emulator/simulator results verify software behavior. Real BLE, camera/MP4 quality
and hardware synchronization require physical devices. Dated
[acceptance results](shared/docs/target-server-plan/acceptance-report.md) do not
verify a new release; a dirty deployment checkout's HEAD does not identify the running image.
