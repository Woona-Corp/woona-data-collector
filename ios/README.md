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

## TestFlight через CI

1. Измените только app `MARKETING_VERSION` и отправьте коммит.
2. Создайте и отправьте соответствующий тег `ios-v*`. Workflow
   `Upload iOS to TestFlight` проверит симулятор, подпишет архив и загрузит его
   в App Store Connect. Номер сборки задаёт CI; `CURRENT_PROJECT_VERSION`
   вручную менять не нужно.
3. Проверьте обработку Apple и назначение сборки внутренним тестировщикам.
   Успешная загрузка сама по себе не подтверждает их доступ.

Ручной запуск: `upload=true` загружает сборку; `upload=false` проверяет подпись
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
Signing/upload выполняется отдельным `testflight.yml`.

GitHub Actions secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`
(App Store Connect, роль Developer), `BUILD_CERTIFICATE_BASE64`,
`BUILD_PROVISION_PROFILE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`.
Сертификат и профиль истекают **24 сентября 2027**; заранее перевыпустите их
и обновите secrets. Текущая доставка предназначена для внутреннего тестирования.
