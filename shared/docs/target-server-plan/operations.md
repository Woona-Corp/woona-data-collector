# Эксплуатация сервера

## Локальный запуск

```bash
cd shared
cp .env.example .env
docker compose config
docker compose up -d --build --wait
curl http://127.0.0.1:8080/health/ready
```

Локальные defaults предназначены только для loopback-разработки. PostgreSQL
порт наружу не публикуется. Файлы лежат в `../var/storage`, БД — в named volume.

## Обязательные production-изменения

1. Сгенерировать отдельный длинный случайный token для каждого устройства.
2. Установить уникальный `WOONA_DEVICE_ID`, label и token через защищённый
   provisioning; не использовать `change-me-local-token`.
3. Задать сильный пароль PostgreSQL через secret store.
4. Выключить `WOONA_ALLOW_LEGACY_MIGRATION` после переноса старых устройств.
5. Публиковать API только через HTTPS reverse proxy/VPN; не публиковать
   PostgreSQL и storage.
6. Ограничить права service account каталогом storage и БД Woona.
7. Настроить мониторинг `/health/live`, `/health/ready`, 5xx и свободного места.

Production overlays устанавливают `WOONA_ENVIRONMENT=production`: API не
запустится с пустым/example token или если в БД остаётся активное устройство с
известным локальным example token. Обычный `compose.yaml` сохраняет локальный
development режим. Для другого способа deployment production режим необходимо
задать явно. Проверка не меняет и не отзывает существующие credentials.

Startup создаёт bootstrap device только при отсутствии его UUID. Он не заменяет
уже provisioned token/label и не отменяет revoke. Менять или отзывать token
нужно явно через `python -m server.device_admin provision <uuid> <label>` /
`revoke <uuid>`; `provision` читает token скрытым вводом. Одного изменения env
для rotation существующего устройства недостаточно.

Token отзывается заполнением `client_devices.revoked_at`. После revoke все
доменные endpoints возвращают 401.

## Team data interfaces

- `https://cool-trams.digital/files/` — read-only просмотр, preview и download
  recordings и PostgreSQL backups через FileBrowser Quantum.
- `https://cool-trams.digital/db/` — просмотр PostgreSQL, SQL и экспорт выборок
  через CloudBeaver Community.

Оба интерфейса доступны только после входа. FileBrowser получает storage и
backup каталоги как read-only mounts. CloudBeaver подключается отдельной ролью
`woona_viewer` с `default_transaction_read_only=on` и только `SELECT` на схеме
`public`; PostgreSQL порт наружу не публикуется. Пароли находятся только в
root-only `/opt/woona/.env.team`, а не в репозитории.

## Backup: отключён

27 октября 2026 владелец явно отменил резервное копирование Woona. Серверные
scheduled/full jobs и off-host/laptop pull отключены; не включать их при
deployment, установке или обновлении. Старые backup entrypoints завершаются
кодом 78 до копирования файлов, SSH, изменения каталогов или остановки API.
Timer/service templates удалены из текущей конфигурации. Политика и проверка:
[Backup policy](../../operations/backups/README.md).

Новый backup server пользователь подключит самостоятельно при необходимости.
Настройка нового расписания не является частью обычного deployment.

## Restore drill

1. Поднять чистый PostgreSQL volume и пустой storage.
2. Остановить API после Alembic initialization.
3. Выполнить `pg_restore --clean --if-exists --exit-on-error --no-owner --no-acl`.
4. Распаковать парный `storage-*.tar` в пустой storage root.
5. Запустить API и дождаться ready.
6. Сравнить counts dogs/recordings/artifacts.
7. Вызвать `/v1/integrity`.
8. Скачать минимум один artifact и сравнить SHA с PostgreSQL.

Нельзя считать успешным восстановление только БД или только файлов.
`--no-acl` намеренно не переносит environment-specific роль `woona_viewer`;
после disaster restore её read-only grants нужно выдать заново.

## Диагностика

- `/health/live = 200` — процесс API жив.
- `/health/ready = 200` — доступны БД и запись/чтение storage.
- `database_unavailable` — проверять PostgreSQL health/DNS/password/pool.
- `storage_unavailable` — проверять mount, права, inode и свободное место.
- `/v1/storage-status` с device token показывает квоты и занятый объём выбранного
  `X-Woona-Account`, физическое место и уже обещанные pending bytes всего сервера.
  `checkedScope` относится только к аккаунту; `serverStorage.scope=server` явно
  отделяет общую ёмкость. Идентификаторы и записи других аккаунтов не возвращаются.
  `admission.blockingReasons` различает `account_quota_reached` и
  `server_capacity_reserved`. Даже при лимите `existingUploadsMayResume=true`:
  уже принятые файлы можно завершить, а `ready` не обещает место сверх показанной
  верхней границы `newArtifactUpperBoundBytes`.
- `/v1/integrity` с device token проверяет только выбранный `X-Woona-Account`;
  без него — непривязанные записи. По умолчанию одна страница содержит до 50
  available artifacts, хешируются файлы до 16 MiB и не более 32 MiB суммарно,
  с двухсекундным cooperative hash/query budget. Проверки выполняются по UUID
  keyset cursor; `limit` ограничен 100. HTTP hard caps: 100 файлов, 64 MiB на файл,
  256 MiB хешируемых bytes и 5 seconds. Их нельзя снять query parameter.
  `mode=metadata` проверяет наличие/размер без SHA. `mode=full` не существует.
  `uncheckedArtifacts`, `hasMore`, `nextCursor`, `coverage` и `nextAction` явно
  описывают недопроверенные данные. `status=ok` выдаётся только для целиком
  проверенного checksum scope в одном запросе; `partial` не означает успешный
  SHA всех файлов. Одна страница с cursor не подтверждает предыдущие страницы.
  Ошибки missing/size/hash/unreadable показываются отдельно, без server paths.
  Одновременно работает не более одного audit во всём API/PG cluster; между
  SHA scans по умолчанию минимум 1 second. `429 integrity_check_busy` содержит
  phase и Retry-After. Миграция 0009 добавляет только одну техническую budget row,
  не меняет clinical metadata и не создаёт фонового задания.
- `storage_space_low` / `storage_full` (507) — upload offset не подтверждается
  вперёд. Сохранить исходники, проверить место и после `Retry-After` повторить
  HEAD перед продолжением. По умолчанию сервер оставляет 256 MiB свободного
  места сверх текущего chunk (`WOONA_UPLOAD_FREE_SPACE_RESERVE_BYTES`);
  это проверка доступного места, не quota и не автоматическое удаление `.part`.
- `storage_quota_exceeded` (413, nonretryable) — новые artifact declarations
  превысят quota записи или аккаунта. Defaults: 20 GiB/recording и 100 GiB/account;
  `WOONA_RECORDING_QUOTA_BYTES` / `WOONA_ACCOUNT_QUOTA_BYTES` меняют эти пределы,
  0 явно отключает соответствующую logical quota. Existing/pending/corrupt
  artifacts учитываются по expected size, повтор одного UUID не начисляется
  дважды. Authoritatively retired parents/children не резервируют будущие bytes;
  оставшиеся физические файлы всё равно уменьшают свободное место.
  Весь новый manifest проверяется до вставки файлов и транзакционно откатывается
  при отказе; дополнительный reference проходит те же правила. Перенос
  непривязанной собаки в аккаунт не обходит quota. Уже принятые manifests,
  idempotent retries и resume не блокируются при последующем уменьшении лимита.
- `storage_reservation_unavailable` (507, retryable) — новым файлам не хватает
  свободной ёмкости после учёта незаписанных bytes уже принятых uploads и256 MiB
  reserve. Admission сериализуется между API workers, namespace/account
  identifiers при этом не раскрываются. Неподтверждённые и отсутствующие
  `.part` prefixes не принимаются за записанные bytes. Файлы не удаляются,
  upload offsets не продвигаются, source originals должны остаться на телефоне.

Для явной проверки больших видео оператор внутри API container может запустить
ограниченную локальную команду (не HTTP request и не scheduled job):

```bash
python -m server.verify_storage --account clinic --max-bytes 8589934592 --max-seconds 300 --limit 10
```

Область обязательна: `--account` или `--unassigned`. Продолжать по `--cursor`
из JSON, проверять `uncheckedArtifacts` и ошибки. Exit codes: 0 — весь scope
проверен, 1 — найдены проблемы, 2 — результат частичный и требует продолжения.
Команда ничего не копирует, не создаёт резервных копий, не удаляет и не правит
исходные записи. Изменение файла во время чтения не выдаётся за проверенный SHA.
Quotas и HTTP audit limits — конфигурация admission/diagnostics, не разрешение
на очистку зависших `.part` или возобновление отключённых backup jobs.
- `offset_mismatch` — клиент должен повторить HEAD и продолжить с серверного
  offset, а не начинать новый файл.
- `artifact_hash_mismatch` — локальный файл или manifest изменился; повторная
  отправка тех же bytes не должна маскировать конфликт.
