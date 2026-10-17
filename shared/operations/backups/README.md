# Ежедневная полная копия Woona

`scheduled-backup.sh` запускает существующий `/opt/woona/shared/server/backup.label.sh`
без изменений. API, Label Studio и label_sync останавливаются на время двух
DB dumps, архивирования storage/media и создания SHA-256; исходный скрипт
возвращает их в работу. Это ежедневный перерыв обслуживания. Во время backup
не запускать другие writers/importers или ручной backup параллельно.

После перезапуска сервисов wrapper проверяет SHA-256, чтение обоих tar и
`pg_restore --list` обоих dumps. Только после этого каталог атомарно получает
имя `YYYYMMDDTHHMMSSZ` и `VERIFIED`. Это проверка целостности, не полное
восстановление сервисов. Изолированный restore необходимо проверять отдельно.

Копии находятся исключительно в `/srv/woona/backups/scheduled/`. Хранятся две
успешные копии; третья временно занимает место до завершения проверки.
Исторические файлы рядом, в `/srv/woona/backups/`, не удаляются. `.pending-*`
удаляются при ошибке и перед следующим запуском под тем же flock. Не помещать
ручные копии в `scheduled`. При недостатке места новый запуск завершается
ошибкой, сохраняя две предыдущие копии.

На 17 октября storage занимает 28.74 GB, на сервере свободно 133 GiB; копия
будет около 29 GB, пик трёх копий около 87 GB плюс dumps/media. Проверка места
использует размер storage, deployment files и API image плюс 2 GiB для dumps/media; при росте БД больше этой
границы её нужно увеличить. Проверка не резервирует место от других процессов.
Off-host pull использует уже установленный на обеих машинах rsync по SSH.
`--partial --inplace --checksum` продолжает частичную передачу и исправляет
повреждённые staged files, включая совпадающие по размеру и mtime. На Linux-машине пользователя
свободно 581 GiB; она должна быть включена, иметь сеть и рабочий SSH BatchMode
для `root@167.99.223.71` без интерактивного пароля/agent setup.

Установка из корня mobile-репозитория после deployment (авторизованный оператор):

```bash
ssh root@167.99.223.71 'install -d -m 700 /opt/woona/operations-backups'
scp shared/operations/backups/scheduled-backup.sh root@167.99.223.71:/opt/woona/operations-backups/
scp shared/operations/backups/woona-backup.service shared/operations/backups/woona-backup.timer root@167.99.223.71:/etc/systemd/system/
ssh root@167.99.223.71 'systemd-analyze verify /etc/systemd/system/woona-backup.service /etc/systemd/system/woona-backup.timer && systemctl daemon-reload && systemctl start woona-backup.service && systemctl enable --now woona-backup.timer'

install -d -m 700 ~/.local/lib/woona-backups
install -m 700 shared/operations/backups/pull-backup.sh ~/.local/lib/woona-backups/
bash ~/.local/lib/woona-backups/pull-backup.sh
crontab -e
```

В пользовательский crontab добавить две строки, сохранив существующие записи:

```cron
0 * * * * /bin/bash /home/ashromanov/.local/lib/woona-backups/pull-backup.sh >> /home/ashromanov/.local/share/woona-backups/pull.log 2>&1
@reboot /bin/bash /home/ashromanov/.local/lib/woona-backups/pull-backup.sh >> /home/ashromanov/.local/share/woona-backups/pull.log 2>&1
```

Локальная машина использует Artix/runit и действующий crond. Её timezone —
Europe/Moscow; cron запускает pull каждый час, а также
при старте crond через `@reboot`. Каталог для `pull.log` создаётся первоначальным
ручным pull. SSH должен работать без login-shell/ssh-agent. Если машина выключена
в плановый час, cron не догоняет пропуск автоматически; `@reboot` даёт отдельную попытку,
которая может завершиться ошибкой до появления сети. Пересекающиеся попытки
отсекаются flock. Следующий час повторяет неудачную попытку, продолжая partial.
Уже проверенная локальная копия с тем же именем повторно не скачивается;
проверяется свежесть её `VERIFIED` (до 36 часов), без повторного SHA всех байтов.

Сервер запускается ежедневно в 02:00 UTC. Его systemd timer с `Persistent=true`
выполняет пропущенный запуск при следующем старте systemd. Pull берёт shared
flock на сервере через `--rsync-path='flock -s /srv/woona/backups/scheduled/.lock rsync'`
на весь transfer, поэтому retention не удалит скачиваемую копию. Последнее имя
отдельно читается по SSH под lock и проверяется строгим timestamp regex;
если копию удалили между lookup и transfer, запуск завершится ошибкой и повторится
в следующий час.
Локально проверяет SHA-256/tar и возраст `VERIFIED` не больше 36 часов; держит
две проверенные копии в `~/.local/share/woona-backups`. Единственная незавершённая
копия остаётся в `.pending/<bundle>/` для resume; при смене последней серверной
копии старый pending удаляется. Пик локального места — две готовые копии плюс
одна partial; ошибки не накапливают дополнительные pending bundles. DB TOC проверяется на
сервере; независимый off-host restore не входит в pull.

Ошибки SSH, нехватки места, checksum, старой копии и блокировки дают ненулевой
выход: на сервере это failed service/journal, локально — `pull.log` и код
завершения cron job. Автоматических внешних уведомлений нет; проверять журнал
и наличие свежего локального `VERIFIED`, а не только расписание.

```bash
ssh root@167.99.223.71 'systemctl status woona-backup.service woona-backup.timer; journalctl -u woona-backup.service -n 40 --no-pager'
crontab -l
tail -n 40 ~/.local/share/woona-backups/pull.log
bash shared/operations/backups/test-scheduled-backup.sh
```

В bundle также входят `deployment.tar` (`.env`, `.env.label`, оба Compose,
`server`, `docs/target-server-plan/models`, `testdata`) и `api-image.tar`
(`docker image save` точного image ID работающего API). Оба файла включены в
SHA-256 manifest. Venv, `__pycache__`, pytest cache, build и egg-info исключены.
Секреты находятся только в защищённых backup-каталогах (umask 077); не
публиковать эти архивы и не коммитить их. Перед backup запрещён параллельный
deployment, иначе конфигурация и image могут относиться к разным версиям.

Для восстановления API image нужен `docker load -i api-image.tar`; сохранение
по ID не сохраняет service tag, поэтому Compose нужно привязать к загруженному
ID (и использовать его для label_sync, если worker развёрнут из того же кода).
Postgres, Label Studio и Caddy images требуют registry/cache: их слои отдельно
не архивируются. Storage/LS media и оба DB dumps восстанавливаются отдельно;
полный disaster-recovery запуск этим тестом не проверен.
