# Woona iOS

Нативный клиент iOS 17+ на SwiftUI, CoreBluetooth и AVFoundation, без внешних
пакетов. Общие экраны и сценарии заданы в [контракте Android/iOS](../shared/UI_UX_CONTRACT.md).

## Реализованный паритет

| Область | Возможности |
| --- | --- |
| Интерфейс | Животные / Сессия / Видео / Записи / Настройки; графики внутри Сессии; RU/EN, system/light/dark |
| Анкеты | Собака и сессия, проверка зависимых полей, несколько собак, неизменяемые версии профиля |
| Датчик | CoreBluetooth scan/connect, live capture, replay старых и новых dump |
| Запись | Камера H.264 MP4, preview 16:9, единый Start/Stop, `ios.CMClock.hostTime`, первый video PTS и `sync.json` |
| Хранение | SQLite v8 с атомарными миграциями, `BLERAW2`, `packets.bin`, `packet_timeline.bin`, diagnostics |
| Синхронизация | Keychain token, `HEAD/PATCH` upload, Range download через `.part`, BGProcessing retry |

Восстановление получает до четырёх GET деталей параллельно и сохраняет их
последовательно. В Настройках ручная проверка места показывает квоту аккаунта,
объём принятых данных и свободное/зарезервированное место сервера. Лимит —
15 секунд; смена настроек или аккаунта отменяет запрос. HTTP 404 старого сервера
показывается как отсутствие поддержки проверки.

Последние 10 сессий видны сразу. «Открыть историю» загружает первые 100;
«Показать ещё N» добавляет до 100, «Обновить историю» возвращает начало списка.
Список ленивый; SQLite и проверка файлов работают вне главного потока.

«Поделиться ZIP сессии» доступно у каждой локальной записи после перезапуска
и независимо от выгрузки. Архив содержит локальные артефакты и видео,
`manifest.json`, историческую анкету собаки, анкету сессии и синхронизацию.
Размер и SHA проверяются; отсутствующие файлы перечисляются в `missingFiles`
и могут быть заранее скачаны кнопкой «Скачать». Share позволяет сохранить ZIP
в «Файлы» или отправить AirDrop; исходники и очередь выгрузки сохраняются.

## Проверка на Mac

Из каталога `ios/`, выбрав доступный симулятор:

```bash
woona_result="/tmp/WoonaTests-$(date +%s).xcresult"
xcodebuild -project Woona.xcodeproj -scheme Woona -resultBundlePath "$woona_result" \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 16' test
xcrun xcresulttool export attachments --path "$woona_result" --output-path "$woona_result-attachments"
python3 tools/check-recording-export.py "$woona_result-attachments"
```

Debug допускает локальный HTTP для local networking; Release ожидает HTTPS.
Токен хранится в Keychain, URL и Wi-Fi policy — в UserDefaults.

На подписанном iPhone отдельно проверить BLE, разрешения камеры, preview/MP4,
записи 10 с / 1 / 10 / 30 минут, фон/блокировку/прерывания, продолжение выгрузки
и восстановление Android-записи. Linux не заменяет native build/test в Xcode;
симулятор не подтверждает работу реального датчика и камеры.

## Native CI: один build и два UI shard

[Canonical workflow](../.github/workflows/ios-native.yml) используется обычным
[Mobile CI](../.github/workflows/mobile.yml) и
[TestFlight](../.github/workflows/testflight.yml). Входы reusable workflow:
`mode` (`full`, `unit`, `diagnostic`), `zip64-large` (boolean), `test-filter`
и `sanitizer` (`none`, `address`, `thread`).

- `full`: один unsigned `build-for-testing` обоих test targets, serial unit
  `test-without-building`, независимые SQLite/ZIP и session ZIP proofs,
  затем два отдельных macOS runner с explicit 9+9 UI methods, одним simulator
  и serial `test-without-building` на каждом. Список methods задан в
  [native_ci.py](tools/native_ci.py), без изменения XCTest assertions/fixtures.
- `unit`: build + весь unit target и оба independent proofs; **не UI proof**.
  Main использует его только после effective required PR protection и включения
  repository variable `CI_MAIN_UNITS_ENABLED`; иначе main остаётся full.
- `diagnostic`: focused/sanitized проверки; никогда не `fullproof` и не release
  gate. Full/unit отвергают filters и sanitizers.
- `zip64-large=false` допускается только для ordinary dependency-selected CI
  согласно [policy](../.github/ci/POLICY.md). Distribution всегда передаёт `true`.
  Native completeness и large ZIP64 fixture — отдельные поля отчёта.

Pinned host: `macos-26`, `/Applications/Xcode_26.6.app`, arm64,
iPhoneSimulator SDK 26.5, available iPhone 17 Pro / runtime 26.5. Отсутствие
этого toolchain/device — ошибка, не fallback на первый доступный iPhone.
Simulator boot начинается до build/download; bounded bootstatus — до tests.
UI jobs ждут build/unit job целиком: публикация products происходит до units,
но GitHub `needs` не запускает consumers по окончании отдельного step.

Products передаются **только внутри одного workflow run**, в tar с сохранением
executable modes и symlinks. Consumers восстанавливают тот же canonical
`$RUNNER_TEMP/woona-native-ci/Derived/Build/Products` и проверяют tar SHA-256,
source/run/attempt, input digest и полный вывод Xcode/SDK/architecture/model.
Ни PR artifact promotion в privileged publisher, ни cross-run DerivedData cache
не используются. Signing secrets не передаются reusable native workflow.

Aggregator сравнивает discovered source XCTest identities с выполненными case
identities из `xcresulttool get test-results tests` JSON: exact union, каждый
один раз, каждый Passed; missing, duplicate, skipped, failed, retry/repetition,
unknown schema и filtered suite не проходят. Сейчас source inventory — 355 unit
и 18 UI methods; новые units обнаруживаются автоматически, новый UI method
требует явного назначения shard. Discovery рассчитан на текущие обычные XCTest
classes/methods, не Swift Testing, dynamic/inherited или parameterized tests.
При такой миграции сначала обновить discovery/schema tests, не ослаблять gate.

Каждый native job всегда сохраняет `.xcresult` как tar, raw JSON и compact
identities/timings, attachments и phase wall times: 7 дней при success, 14 при
failure; temporary products — 1 день. Final proof связывает mode, test identities,
independent proofs, result hashes и same-run artifact IDs/digests. Failed/cancelled
selected jobs не могут быть заменены зелёным subset или диагностическим run.

Linux checks (не native acceptance):

```sh
python3 -m unittest discover -s ios/tools -p 'test_native_ci.py' -v
python3 -m unittest discover -s ios/tools -p 'test_testflight_internal.py' -v
```

**Migration acceptance ещё требует macOS/Xcode run.** Linux hermetic subprocess
и JSON schema tests плюс настоящий tar round-trip подтверждают tooling policy,
но не переносимость Xcode test products. Первый authorized native PR должен
проверить `.xctestrun` relative/absolute paths, test host/runner launch на двух
чистых VMs, фактическую JSON schema и полный identity union + attachments.
Если Xcode сохраняет иной absolute path или schema, gate обязан упасть;
не добавлять rebuild/retry/subset fallback. До release rollout нужны native
эквивалентность и пять сопоставимых full runs (median/p90 и runner-minutes).
Ускорение двух shard пока прогноз, не измеренный результат; physical BLE/camera,
MP4, background и hardware synchronization остаются отдельными проверками.

## TestFlight через CI

1. Измените только app `MARKETING_VERSION` и отправьте коммит.
2. Создайте и отправьте соответствующий тег `ios-v*`. Workflow
   `Upload iOS to TestFlight` сначала выполнит canonical full native gate
   и large ZIP64 oracle, затем отдельно подпишет device Release архив и загрузит его
   в App Store Connect. Номер сборки задаёт CI; `CURRENT_PROJECT_VERSION`
   вручную менять не нужно.
3. Проверьте обработку Apple и назначение сборки внутренним тестировщикам.
   Успешная загрузка сама по себе не подтверждает их доступ.

Ручной запуск: по умолчанию `upload=false`; `upload=true` загружает сборку; `upload=false` проверяет подпись
и экспорт. Push в `main` и старые `v*` теги не загружают TestFlight.
Android использует `android-v*` независимо. При смене контрактов сначала
разверните и проверьте совместимый сервер.

Workflow `Verify internal TestFlight availability` по точной версии и номеру
сборки по умолчанию только читает состояние. `available_for_internal_testers=true`
требует VALID, non-expired, IN_BETA_TESTING и внутреннюю группу с тестировщиками;
это не подтверждает установку на iPhone. Отчёт содержит processing/expiration,
beta state, ID групп, число тестировщиков и членство сборки, без списка людей.

Если назначения нет, повторите проверку с `assign_internal=true` и явными
`internal_group_ids` из отчёта. Helper проверяет приложение `com.woona.apps`
и `isInternalGroup=true` до записи, затем перечитывает результат через API.
Внешние группы, beta review, приглашения и localizations остаются отдельными.
Signing/upload выполняется отдельным `testflight.yml` после full native gate;
`upload=false` также требует полный gate и signing credentials, это не unsigned
CI и не способ обойти тесты. Signing/archive не выполняются спекулятивно.

После успешного export/upload сохраняется `testflight-upload-manifest` с exact
source/version/build/run/attempt и `uploaded`. Отдельный Ubuntu job автоматически
наблюдает **только этот build**, read-only; macOS не ждёт Apple. Каждый poll имеет
UTC timestamp и остаток monotonic budget (900 секунд, ограниченные HTTP waits).
`status_inspected=true` / green status job не означает
`available_for_internal_testers=true`. Timeout не разрешает повторный upload:
повторите только internal status workflow с exact version/build из manifest.
Assignment остаётся отдельным явным действием с existing internal group IDs;
автоматическое наблюдение ничего не назначает и никого не приглашает.
Release/status requests serialized с `cancel-in-progress:false`, `queue:max`
(документированный GitHub лимит — 100 pending). Старый actionlint 1.7.12 ещё
не распознаёт `queue`; это не основание включать отмену distribution requests.

GitHub Actions secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`
(App Store Connect, роль Developer), `BUILD_CERTIFICATE_BASE64`,
`BUILD_PROVISION_PROFILE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`.
Сертификат и профиль истекают **24 сентября 2027**; заранее перевыпустите их
и обновите secrets. Текущая доставка предназначена для внутреннего тестирования.
