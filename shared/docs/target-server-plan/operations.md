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
7. Настроить мониторинг `/health/live`, `/health/ready`, 5xx, свободного места
   и PostgreSQL backup.

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
- `/v1/integrity` с device token — проверяет доступные файлы, размер и SHA.
- `offset_mismatch` — клиент должен повторить HEAD и продолжить с серверного
  offset, а не начинать новый файл.
- `artifact_hash_mismatch` — локальный файл или manifest изменился; повторная
  отправка тех же bytes не должна маскировать конфликт.
