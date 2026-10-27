# Architecture

## Структура репозитория

- `android/` — нативный Android-клиент и его инструменты сборки;
- `ios/` — нативный SwiftUI/CoreBluetooth/AVFoundation iOS-клиент;
- `shared/` — FastAPI-сервер, Docker Compose, общие схемы данных и документация.

## Общая схема

Woona состоит из Android/iOS приложений, одного FastAPI-сервиса, PostgreSQL 18 и
серверной файловой системы. Клиенты не подключаются к БД напрямую.

```text
Android (SQLite + WorkManager) --+
iOS (SQLite + BGProcessingTask) -+-- HTTPS/Bearer -- FastAPI -- PostgreSQL
                                                       |
                                                       +-- server filesystem
```

SQLite остаётся offline-first источником незавершённой локальной работы.
PostgreSQL хранит анкеты, версии, связи, состояния выгрузки и контрольные
суммы; бинарные артефакты хранятся файлами. Google Drive из итогового потока
удалён, ручной Android Share сохранён.

## Клиентские boundaries

- `ble/` — scan, GATT, notification и время получения фрагмента.
- `protocol/` — сборка и валидация пакетов.
- `feature/device/` — единый lifecycle датчика, камеры, replay и экспорта.
- `storage/` — packet/raw/timeline/diagnostic/CSV/ZIP форматы.
- `video/` — Camera2 preview и MediaRecorder.
- `data/` — SQLite v7 на Android, анкеты, immutable profile versions, записи, sync и
  artifacts.
- `sync/` — настройки сервера, Keystore-токен, HTTP upload/download и
  WorkManager.
- `profile/` и `AppShell.kt` — Compose UI без аппаратной и сетевой логики.
- iOS повторяет те же границы в `BLE/`, `Protocol/`, `Capture/`, `Storage/` и
  `AppShell/`; camera использует AVCaptureSession/AVAssetWriter.

## Локальная модель

`filesDir/Woona/woona.sqlite` на Android и Application Support
`Woona/woona.sqlite` на iOS используют совместимые модели (Android schema version 8; iOS version 8 с аккаунтами, версиями анкет, контрольными файлами и durable retirement outbox):

- `dogs`;
- `dog_profile_versions`;
- `recordings`;
- `recording_sync`;
- `artifacts`;
- `server_sync_state`.

Запись ссылается на конкретную неизменяемую версию анкеты. Артефакты находятся
под:

```text
<Android filesDir | iOS Application Support>/Woona/
  recordings/<dog-id>/<local-date>/<recording-id>/
```

Финальные типы: `packets.bin`, `packet_timeline.bin`,
`raw_fragments.binlog`, `diagnostics.log`, `channel.csv`, `video.mp4`,
`sync.json` и импортированный исходник replay. SHA-256 считается потоково.

## Capture lifecycle

1. Полностью валидные dog/session анкеты создают `preparing`.
2. BLE readiness переводит UI в готовность и показывает Camera2/AVFoundation preview.
3. Одна кнопка запускает датчик и, если выбрано, MediaRecorder/AVAssetWriter.
4. Валидированный первый пакет и первый кадр получают timestamps одной
   платформенной monotonic шкалы (`elapsedRealtimeNanos`/`CMClock.hostTime`);
   сохраняются также UTC anchor, device timer,
   camera timestamp, callback timestamp и первый video sample PTS.
5. Одна кнопка останавливает оба источника, дожидается очереди, атомарно
   обновляет sync, регистрирует файлы и ставит серверную выгрузку.
6. Если камера падает после старта датчика, запись остаётся останавливаемой,
   помечается `camera_failed` и выгружается без выдуманного видео.

## Server synchronization

Профили и записи имеют клиентские UUID. Метаданные PUT идемпотентны, версии
профилей и manifests после создания неизменяемы. Файлы передаются частями через
`HEAD` + `PATCH Upload-Offset`, завершаются проверкой размера/SHA-256 и
атомарным rename. Запись получает receipt только после проверки всех файлов.

Download поддерживает `Range`, ETag, продолжение `.part`, проверку размера и
SHA-256. Restore возвращает текущие и исторические profile versions, recordings,
sync и список артефактов; совпадающие локальные данные объединяются, конфликт
контрольной суммы не перезаписывается.

Bearer-токен хранится на сервере только как SHA-256, локально — в Android
Keystore или iOS Keychain. Аккаунт оператора выбирается заголовком `X-Woona-Account`; `dogs.account_id`
связывает собаку и все её сессии с одним аккаунтом. Без заголовка доступны
только непривязанные данные. Аккаунт не заменяет технический device token.
Анкеты сессий редактируются отдельно с проверкой `questionnaire_revision`;
исходные manifests/files и receipt артефактов сохраняются. Подробности:
[`shared/ACCOUNTS.md`](shared/ACCOUNTS.md). Изменять
незавершённую artifact upload может только создавший recording
`capture_device_id`. Readiness отдельно проверяет БД и файловую систему.

Полные DDL, JSON Schema, API и визуализации:
[`shared/docs/target-server-plan`](shared/docs/target-server-plan/README.md).
