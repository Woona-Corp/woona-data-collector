# Резервное копирование Woona отключено

**Решение владельца от 27 октября 2026:** полностью убрать резервное копирование
Woona. Серверный scheduled/full backup, off-host pull и копирование на ноутбук
отключены. Новый backup server пользователь подключит сам при необходимости.
Обычная установка, deployment и обновление не должны включать эти jobs.

`scheduled-backup.sh`, `pull-backup.sh`, `server/backup.sh` и
`server/backup.label.sh` сохранены как явные отключённые entrypoints: они
возвращают **78** и понятное сообщение до любых операций с Docker, SSH, rsync,
файлами, каталогами или сервисами. Environment flag не включает их обратно.
Это предотвращает запуск старым cron/service или ранее сохранённой командой.
Рабочие API, PostgreSQL и Label Studio ради backup не останавливаются.

Systemd timer/service templates удалены из текущего репозитория. На сервере
`woona-backup.timer` и `woona-backup.service` должны быть **masked/inactive**;
старые cron entries отсутствуют. На ноутбуке hourly/startup pull также выключен.

Проверка состояния (ничего не включает):

```bash
systemctl show woona-backup.timer woona-backup.service -p Id -p ActiveState -p UnitFileState
systemctl list-timers --all woona-backup.timer --no-pager
./woona status
bash shared/server/tests/test_backup.sh
bash shared/operations/backups/test-scheduled-backup.sh
```

Очистка избыточных старых backup copies выполняется отдельно после проверки
живых БД, аннотаций LS и canonical files и с точным списком путей. Удаление
backup не означает разрешение удалить canonical recordings, Drive originals,
archive-import sources, аннотации, файлы коррекций или данные чужого сервиса.
Небольшой актуальный DB/source rollback artifact при конкретном deployment
может сохраняться как рабочий материал; это не регулярная backup job.

Инструкции прежней схемы остаются в истории Git и не являются текущим
порядком установки. Любое новое расписание или внешний backup target требует
нового явного решения владельца. Команды восстановления из существующего
операторского архива сами по себе не создают расписание.
