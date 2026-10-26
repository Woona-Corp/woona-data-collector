# Woona iOS

Нативный SwiftUI-клиент iOS 17+, восстановленный из старого проекта и
синхронизированный с текущим Android-контрактом. Внешних packages нет.

## Реализованный паритет

- Overview / Charts / Settings, EN/RU и system/light/dark;
- обязательные typed-анкеты собаки и сессии с conditional validation;
- несколько собак, immutable profile versions и последние 10 записей;
- CoreBluetooth scan/connect, live capture и replay старых/новых dump;
- `BLERAW2`, `packets.bin`, `packet_timeline.bin`, diagnostics и export/share;
- «Поделиться ZIP сессии» у каждой локальной записи, независимо от серверной
  выгрузки и перезапуска: видео, все локальные артефакты, `manifest.json`,
  историческая анкета собаки, анкета сессии и синхронизация; «Показать все записи»
  открывает записи старше последних десяти. ZIP сохраняется через системное меню
  в «Файлы» или передаётся AirDrop. Исходники и очередь выгрузки не изменяются.
  Отсутствующие на устройстве файлы перечислены в `missingFiles`; их можно
  сначала скачать кнопкой «Скачать». Размер и SHA локальных файлов проверяются.
- задняя AVCaptureSession camera, H.264 MP4, 16:9 preview и единый Start/Stop;
- `ios.CMClock.hostTime`, первый video PTS и `sync.json`;
- SQLite schema v5, Keychain token, общий Android/iOS сервер;
- resumable `HEAD/PATCH` upload, metadata restore, проверяемый Range download
  через `.part` и BGProcessing retry.

## Проверка на Mac

```bash
woona_result="/tmp/WoonaTests-$(date +%s).xcresult"
xcodebuild -project Woona.xcodeproj -scheme Woona -resultBundlePath "$woona_result" \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 16' test
xcrun xcresulttool export attachments --path "$woona_result" --output-path "$woona_result-attachments"
python3 tools/check-recording-export.py "$woona_result-attachments"
```

В Debug локальный HTTP разрешён только для local networking; Release ожидает
HTTPS. Bearer token хранится в Keychain, URL и Wi-Fi policy — в UserDefaults.

Затем на подписанном физическом iPhone проверить BLE, camera permission,
preview/MP4, 10-с/1/10/30-минутные записи, background/lock/interruption,
upload resume и восстановление Android-записи. Linux не содержит Swift/Xcode,
поэтому не доказывает компиляцию или аппаратное поведение.

## TestFlight через CI

Пуш тега `ios-v*` запускает только workflow `Upload iOS to TestFlight`:
проверки на iOS Simulator, подписанный архив и загрузку в App Store Connect.
Android выпускается отдельно тегом `android-v*`; его сборка не блокирует iOS.
Перед iOS-релизом обновите только `MARKETING_VERSION` приложения и сохраните
изменение в коммите. Номер сборки вычисляется из номера запуска CI и его
попытки; вручную менять `CURRENT_PROJECT_VERSION` не нужно.

```bash
git tag -a ios-v1.3.8 -m 'Woona iOS 1.3.8'
git push origin ios-v1.3.8
```

Можно запустить workflow вручную на нужной ветке: `upload=true` загружает
новую сборку, `upload=false` проверяет подпись и экспорт без загрузки.
Пуш в `main` и старые теги `v*` не запускают загрузку в TestFlight.
Версии и даты выпуска платформ могут различаться; функциональный паритет и
совместимость с общим сервером сохраняются. Для изменений контрактов сначала
разверните и проверьте совместимый сервер.

После загрузки проверьте обработку Apple и доступность сборки тестировщикам.
Внешняя группа TestFlight получает новую сборку после отдельного добавления
сборки в группу и, если требуется, проверки Apple.

Секреты GitHub Actions: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`
(ключ App Store Connect с ролью Developer), `BUILD_CERTIFICATE_BASE64`,
`BUILD_PROVISION_PROFILE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`.
Сертификат и профиль подписи истекают 24 сентября 2027 года; перед этим
перевыпустите их и обновите соответствующие секреты.
