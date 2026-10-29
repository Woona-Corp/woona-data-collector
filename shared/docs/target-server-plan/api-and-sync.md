# API и синхронизация

## 1. Основные свойства контракта

- Версия API: `/v1`.
- Все entity UUID создаются на Android/iOS до сети.
- Повтор одного запроса с тем же UUID идемпотентен.
- Повтор с тем же UUID, но другим immutable content hash, возвращает `409`.
- JSON timestamps — RFC 3339 UTC.
- IANA timezone передаётся отдельно, например `Europe/Moscow`.
- Binary content не кодируется base64 и не кладётся в JSON.
- Один artifact передаётся chunks и может продолжиться с server offset.
- Запись считается серверно complete только после отдельного finalize.
- API не принимает абсолютные/относительные пути клиента как server path.

## 2. Dog и profile version без записи

### `PUT /v1/dogs/{dogId}/profile-versions/{profileVersionId}`

Этот endpoint вызывается сразу после локального создания/редактирования
профиля, а не ждёт будущей съёмки:

```json
{
  "dog": {
    "id": "uuid",
    "numberOrName": "Rex",
    "expectedRevision": 3
  },
  "profileVersion": {
    "id": "uuid",
    "schemaVersion": 1,
    "validationState": "complete",
    "questionnaire": {},
    "contentSha256": "64-hex",
    "clientCreatedAtUtc": "2026-07-30T17:00:00Z"
  }
}
```

Правила:

- оба path id совпадают с payload;
- одинаковый request идемпотентен;
- profile version immutable;
- новая версия supersede текущую в одной PostgreSQL transaction;
- `expectedRevision` не допускает silent last-write-wins;
- offline версии одного dog клиент отправляет по времени создания;
- `409 revision_conflict` требует загрузить server current и явного merge,
  локальная версия не исчезает;
- новая обычная версия всегда `complete`;
- `legacy_incomplete` разрешён только migration command.

Ответ содержит новую `dogRevision`, current profile version id и server
timestamp. Android сохраняет их и показывает профиль синхронизированным даже
при отсутствии recordings.

## 3. Recording manifest

### `PUT /v1/recordings/{recordingId}`

Один transaction upsert передаёт всю структурированную часть:

```json
{
  "schemaVersion": 1,
  "captureDeviceId": "uuid",
  "dog": {
    "id": "uuid",
    "numberOrName": "Rex",
    "expectedRevision": 3
  },
  "dogProfileVersion": {
    "id": "uuid",
    "schemaVersion": 1,
    "validationState": "complete",
    "questionnaire": {},
    "contentSha256": "64-hex"
  },
  "recording": {
    "source": "live",
    "captureStatus": "completed",
    "startedAtUtc": "2026-07-30T17:00:00Z",
    "endedAtUtc": "2026-07-30T17:03:12Z",
    "timezone": "Europe/Moscow",
    "videoRequested": true,
    "sensorHardwareId": "optional-device-id",
    "appVersion": "future-version",
    "questionnaireSchemaVersion": 1,
    "questionnaireValidationState": "complete",
    "sessionQuestionnaire": {}
  },
  "sync": {},
  "artifacts": [
    {
      "id": "uuid",
      "type": "video",
      "fileName": "video.mp4",
      "mimeType": "video/mp4",
      "sizeBytes": 123456789,
      "sha256": "64-hex"
    }
  ]
}
```

Server response:

```json
{
  "recordingId": "uuid",
  "ingestStatus": "uploading",
  "dogRevision": 4,
  "artifacts": [
    {
      "id": "uuid",
      "storageStatus": "uploading",
      "uploadOffset": 8388608
    }
  ]
}
```

Server validation:

- device active;
- path id совпадает с payload id;
- dog/profile/recording relations согласованы;
- questionnaire соответствует заявленной schema version;
- normal Android endpoint принимает только `validationState=complete`;
- historical migration endpoint/command может принять `legacy_incomplete`;
- capture status terminal для automatic upload;
- ended time не раньше started time;
- video artifact обязателен, если `videoRequested=true` и status completed;
- artifact type/name/MIME/size находятся в allowlist/limits;
- все SHA-256 имеют правильный формат;
- profile version immutable;
- `expectedRevision` предотвращает silent concurrent update.

Recording worker перед PUT сначала убеждается, что связанная profile version
синхронизирована. Вложенный snapshot остаётся обязательным: server применяет ту
же идемпотентную функцию и поэтому request самодостаточен после process death.

## 4. Artifact upload

### `HEAD /v1/artifacts/{artifactId}/content`

Возвращает:

```text
Upload-Offset: <stored_size_bytes>
Upload-Length: <expected_size_bytes>
ETag: "<sha256>"
```

### `PATCH /v1/artifacts/{artifactId}/content`

Headers:

```text
Content-Type: application/offset+octet-stream
Upload-Offset: <client offset>
Content-Length: <chunk bytes>
```

Правила:

- default chunk 8 MiB, конфигурируемый 1–16 MiB;
- offset обязан точно совпасть с server `stored_size_bytes`;
- mismatch возвращает `409` и актуальный offset;
- chunk пишется в `.part`, flush выполняется до ответа;
- DB offset обновляется только после успешной записи;
- один artifact имеет server-side lock;
- повтор уже принятого chunk не append вслепую: клиент сначала получает offset;
- API process death оставляет `.part` и подтверждённый offset;
- client process death безопасен: новый worker продолжит после HEAD.

### `POST /v1/artifacts/{artifactId}/complete`

Server:

1. проверяет stored size;
2. вычисляет SHA-256 из `.part`;
3. сравнивает с manifest;
4. делает atomic rename;
5. ставит `storage_status=available`;
6. возвращает immutable receipt.

Hash mismatch:

- artifact -> `corrupt`;
- `.part` сохраняется в quarantine или удаляется согласно debug policy;
- запись не может стать complete;
- Android получает permanent data error и предлагает повторно вычислить
  локальный hash/пересоздать derived artifact.

## 5. Recording finalize

### `POST /v1/recordings/{recordingId}/complete`

Server вычисляет expected artifact set:

| Source/status | Обязательные artifacts |
|---|---|
| live completed, video true | packet, raw, diagnostic, sync, video |
| live completed, video false | packet, raw, diagnostic, sync |
| replay completed | packet, diagnostic, sync; raw если создаётся текущим pipeline |
| interrupted/failed | все заявленные и реально существующие; отсутствие video допускается с error metadata |

CSV — derived artifact. Он выгружается, если уже создан, но его отсутствие не
делает raw capture неполным: сервер или Android могут пересоздать CSV из
`packets.bin`.

Finalize возвращает:

```json
{
  "recordingId": "uuid",
  "ingestStatus": "complete",
  "verifiedAtUtc": "RFC3339",
  "artifactCount": 6,
  "totalBytes": 123,
  "receiptSha256": "hash-of-canonical-manifest"
}
```

Android сохраняет receipt и только после этого показывает `Синхронизировано`.

## 6. Чтение и восстановление

Все активные device tokens одного развёртывания читают общий набор dogs,
profile versions, recordings и artifacts. `created_by_device_id` и
`capture_device_id` остаются аудитом происхождения. `HEAD/PATCH/complete` для
незавершённой загрузки разрешены только capture device; готовый artifact может
скачать любое активное устройство.

### Metadata

- `GET /v1/dogs?cursor=&limit=`
- `GET /v1/dogs/{dogId}`
- `GET /v1/dogs/{dogId}/recordings?cursor=&limit=`
- `GET /v1/recordings/{recordingId}`
- `GET /v1/recordings/{recordingId}/sync-status`

Списки cursor-based, не offset-based. По умолчанию возвращается metadata без
binary body.

### Artifact

- `GET /v1/artifacts/{artifactId}/content`
- поддерживается HTTP Range;
- response содержит `Content-Length`, `ETag`/SHA-256, MIME и filename;
- Android скачивает в `.download.part`;
- после полного download сверяет size/hash;
- только после проверки atomic rename делает файл доступным;
- неполный download продолжается по Range.

### Reinstall restore

1. пользователь provision token;
2. приложение загружает dogs + current profile versions;
3. сохраняет их в local SQLite transaction;
4. загружает recent recording metadata;
5. artifacts остаются `remote_only`;
6. при открытии/экспорте пользователь скачивает нужный artifact;
7. локальный UI отличает `local`, `remote_only`, `downloading`, `verified`.

## 7. Фоновая синхронизация клиентов

Используется уже подключённый WorkManager.

Unique work на новую profile version:

```text
server-profile-<profile-version-id>
```

Она отправляет endpoint профиля, сохраняет server revision и не ждёт новой
recording.

Одна unique work chain на recording:

```text
server-sync-<recording-id>
```

Worker:

1. проверяет terminal local capture state;
2. закрывает/не трогает открытые writers;
3. подтверждает связанную profile version;
4. вычисляет отсутствующие SHA-256 streaming;
5. отправляет manifest;
6. последовательно продолжает artifacts;
7. вызывает artifact complete;
8. вызывает recording complete;
9. сохраняет receipt;
10. обновляет UI state.

Network constraint:

- `CONNECTED` по умолчанию;
- `UNMETERED`, если включено «только Wi-Fi».

Retry classification:

| Случай | Результат |
|---|---|
| timeout, DNS, connection reset, HTTP 408/425/429/5xx | retry + exponential backoff |
| worker stopped/constraint lost | сохранить offset, retry |
| 401/403 | permanent auth attention |
| 404 manifest/artifact | повторить manifest один раз, затем permanent contract error |
| 409 offset | получить server offset и продолжить |
| 409 immutable content/revision | permanent conflict, не перетирать |
| 413 | permanent size/config error |
| 422 | permanent validation error |
| hash mismatch | permanent data integrity error |

Большое видео:

- worker делает короткие chunk requests;
- для длительной активной передачи используется long-running/foreground
  WorkManager с системным уведомлением;
- остановка worker проверяется между chunks;
- ни один network retry не блокирует UI или capture.

iOS хранит тот же offset/state в SQLite, продолжает каждый artifact после
server `HEAD`, а повтор планирует через `BGProcessingTask`. Фоновое время
назначает iOS; следующий запуск или background task безопасно продолжает
загрузку с подтверждённого offset.

При restore iOS сначала импортирует общие profile/recording/sync/artifact
metadata в SQLite. Файлы остаются remote-only до явного Download; `.part`
возобновляется через Range, а target заменяется только после size/SHA-256.

## 8. Sync status UI

На карточке записи:

```text
Локально сохранено
Ожидает сеть
Выгружается 42% (video.mp4)
Синхронизировано 20:14
Нужна авторизация
Ошибка данных: повторить/подробности
Только на сервере
Скачивается 18%
Скачано и проверено
```

Общий top status не должен занимать место длинным текстом; icon + accessible
description, подробности в Settings/recording card.

## 9. Idempotency tests

Обязательные проверки:

1. два одинаковых manifest PUT дают одну запись;
2. одинаковый UUID с другим hash -> 409;
3. повтор chunk после lost response не удваивает bytes;
4. restart API после chunk сохраняет offset;
5. restart PostgreSQL не теряет confirmed metadata;
6. finalize дважды возвращает тот же receipt;
7. Android process death продолжает с server offset;
8. concurrent upload одного artifact не повреждает файл;
9. download Range собирает исходный SHA-256;
10. server path невозможно изменить filename/path traversal payload.
11. профиль, сохранённый без recording, появляется на сервере.
12. несколько offline profile versions одного dog применяются по порядку.

## Storage capacity and bounded integrity diagnostics

`GET /v1/storage-status` requires the existing bearer device token and accepts the
same `X-Woona-Account` scope. It returns `limits`, selected-account declared and
currently present acknowledged bytes (`metadataAcknowledgedBytes` separately
retains the database counter), and separately labelled server filesystem capacity/pending
reservations. `status` is `ready`, `account_quota_reached`, or `capacity_reserved`;
`admission.blockingReasons` can contain both blocking causes. It does not expose
other account identities. `existingUploadsMayResume=true` distinguishes rejection
of new declarations from the right to complete an already accepted upload.

New manifest/reference bytes are reserved transactionally. The whole manifest is
checked before inserting artifact rows. `413 storage_quota_exceeded` reports
`quotaScope`, `limitBytes`, `reservedBytes`, `requestedBytes`, nonretryable and
`nextAction=review_server_storage_limits`. `507 storage_reservation_unavailable`
reports physical admission failure after existing pending reservations and the
filesystem reserve; it is retryable with `Retry-After`. Both preserve local
originals and never acknowledge new upload bytes. Retried accepted UUIDs are not
charged again, and lowering a quota does not interrupt existing accepted uploads.

`GET /v1/integrity?mode=sha256&limit=50&cursor=<UUID>` uses the same account scope.
Defaults: at most 50 files/page, 16 MiB per hashed file, 32 MiB total hashed bytes,
2 second cooperative hash/query budget. HTTP maxima cannot be removed through
request input. `mode=metadata` checks existence/size and explicitly leaves SHA
unchecked. There is no public unbounded `mode=full`.

The additive result retains `checkedScope`, `problems`, `checkedArtifacts`,
`hashedArtifacts`, `hashedBytes`, and adds `uncheckedArtifacts`, `scopeArtifacts`,
`scopeExpectedBytes`, `coverage`, `limits`, `hasMore`, `nextCursor`, `nextAction`.
`status=ok` requires every available artifact in the selected scope to have its
SHA checked in this one request. Pages and omitted/large files yield `partial`;
`coverage.pageChecksumVerified` never implies `scopeChecksumVerified`. A missing
or corrupted file yields `failed`, and the list remains bounded/paginated.
`429 integrity_check_busy` with `phase` and `Retry-After` covers cross-worker
concurrency, cooldown and database query budget. No recordings are modified.

Migration 0009 adds only the technical single-row audit budget. Large explicit
operator audits use `python -m server.verify_storage` on the server with an
explicit scope and byte/time budget; they are not started by an HTTP query.
The CLI exits 0 only for a fully verified scope, 1 for detected problems, and 2
for partial/paged results that require continuation or a reviewed larger budget.
