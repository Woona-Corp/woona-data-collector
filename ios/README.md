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

## Native CI: один Mac, один build, один serial test

[Canonical workflow](../.github/workflows/ios-native.yml) используется обычным
[Mobile CI](../.github/workflows/mobile.yml) и
[TestFlight](../.github/workflows/testflight.yml). Входы reusable workflow:
`mode` (`full`, `unit`, `diagnostic`), `zip64-large` (boolean), `test-filter`
и `sanitizer` (`none`, `address`, `thread`).

- `full`: один macOS producer без Simulator boot делает один unsigned
  `build-for-testing` обоих test targets и один раз выполняет independent
  SQLite/ZIP oracle. Затем на том же Mac выполняется **один** serial
  `test-without-building`: целые bundles `WoonaTests` и `WoonaUITests`
  в исходном scheme target order, units перед UI. Один physical report `full`
  содержит сейчас 355 unit + 18 UI = 373 identities. Session ZIP proof
  проверяется по attachments этого bundle. Explicit reviewed 18 UI methods
  в [native_ci.py](tools/native_ci.py) проверяют полноту, не фильтруют запуск.
  Нет cross-Mac consumers, shards, duplicate unit execution, synthetic warm-up
  или изменения XCTest assertions/fixtures.
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
Во всех режимах prepare проверяет host/runtime/model без boot до компиляции.
Только перед test execution запускается Simulator (если ещё не booted), затем
bounded `bootstatus -b`; boot не перекрывается со сборкой.

Products остаются на том же producer в canonical
`$RUNNER_TEMP/woona-native-ci/Derived/Build/Products`; существующий tree digest
сохраняет binary SHA-256 без product artifact/pack/restore. Нет cross-run cache,
internal role или новых caller inputs. Source/run/attempt, input digest и полный
вывод Xcode/SDK/architecture/model остаются частью proof. Signing secrets не
передаются reusable native workflow.

Aggregator сравнивает discovered source XCTest identities с выполненными case
identities из `xcresulttool get test-results tests` JSON: exact набор
в одном physical report (`full` для full, `unit` для unit),
каждый один раз, каждый Passed; missing, duplicate, skipped, failed, retry/repetition,
unknown schema и filtered suite не проходят. Сейчас source inventory — 355 unit
и 18 UI methods; новые units обнаруживаются автоматически, новый UI method
требует явного включения в reviewed UI inventory. Discovery рассчитан на текущие обычные XCTest
classes/methods, не Swift Testing, dynamic/inherited или parameterized tests.
При такой миграции сначала обновить discovery/schema tests, не ослаблять gate.

Producer всегда сохраняет полный `.xcresult` как tar, raw JSON и compact
identities/timings, attachments, identity/archive proofs и phase wall times:
7 дней при success, 14 при failure. Linux required job требует success producer
и проверяет полноту. Final proof связывает mode, test identities,
independent proofs, result hashes и same-run artifact IDs/digests. Failed/cancelled
selected jobs не могут быть заменены зелёным subset или диагностическим run.

Для Mobile CI artifact `ios-native-full-evidence` содержит полный physical
report, `ios-native-unit-evidence` — unit/diagnostic evidence, `ios-native-proof`
— результат Linux acceptance. На открытом PR нужны зелёные `ios / ios-required`
и `ci-required`, а не только macOS job. Main/manual используют `ci-observed`;
`mode=unit` или `diagnostic` с `fullproof=false` не подтверждает UI acceptance.

Linux checks (не native acceptance):

```sh
python3 -m unittest discover -s ios/tools -p 'test_native_ci.py' -v
python3 -m unittest discover -s ios/tools -p 'test_testflight_internal.py' -v
```

**Изменения single-Mac CI требуют macOS/Xcode acceptance.** Linux hermetic
subprocess и JSON schema tests подтверждают tooling policy, но не native
acceptance. При приёмке full run проверить unit→UI порядок единственного
invocation, точные 373 identities (355+18), attachments/session ZIP proof и полный
агрегатор. Прежние consumer runs не доказывают принятие нового DAG или
устранение AX timeout. Если Xcode возвращает иную schema, gate обязан упасть;
не добавлять rebuild/retry/subset fallback. До release rollout нужны native
эквивалентность и пять сопоставимых full runs (median/p90 и runner-minutes).
Этот порядок — performance/order hypothesis, не доказанное исправление
AXErrorIPCTimeout; post-tap waits/retries не добавлены. Ускорение не заявлено;
physical BLE/camera,
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
