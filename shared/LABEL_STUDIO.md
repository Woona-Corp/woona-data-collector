# Label Studio deployment

The worker uses existing project **21 — Активность и Аллюр** and preserves its
labeling configuration. It reads completed V2 activity recordings from
PostgreSQL, requires all six capture artifact types, and adds missing tasks
every 60 seconds. Tasks use `woona:<recording UUID>` and files from the ordinary
Woona storage. [Data contract](DATA.md).

From `shared/` on a fresh host:

```sh
python3 tools/bootstrap_label_env.py
install -d -m 0755 /srv/woona/storage /srv/woona/postgres /srv/woona/label-postgres
chown 10001:10001 /srv/woona/storage
docker compose --env-file .env --env-file .env.label \
  -f compose.yaml -f compose.label.yaml up -d --build --wait
```

Bootstrap refuses to overwrite credentials. Device tokens stay in app settings;
server and Label Studio credentials stay in root-only env files.

Caddy serves API and dashboard alongside Label Studio at
`https://cool-trams.digital/`. The dashboard requires a Label Studio login.
Both PostgreSQL databases stay private. Label Studio mounts Woona files read-only.

```sh
docker compose --env-file .env --env-file .env.label \
  -f compose.yaml -f compose.label.yaml exec -T label_sync python -m server.label_sync --once
```

Exports read the project's explicit frame rate and preserve one-based inclusive
frame ranges as zero-based half-open seconds. Existing annotation metadata
freezes the coordinate frame rate; changing it requires a range migration.
BLE export additionally validates measured, hash-bound alignment.

`server/backup.label.sh` briefly stops ingest and labeling and backs up both
PostgreSQL databases, canonical storage and Label Studio media with SHA-256.
Restore verification requires database counts, `/v1/integrity`, local-file reads
and annotation counts. Separate Drive sources and recovered-recording roots
are no longer part of the runtime.

Verified orientation derivatives and dataset export: [VIDEO_PRESENTATION.md](VIDEO_PRESENTATION.md).
