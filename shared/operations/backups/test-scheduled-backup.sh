#!/usr/bin/env bash
set -euo pipefail
runner="$(cd "$(dirname "$0")" && pwd)/scheduled-backup.sh"
root="$(mktemp -d)"
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/shared/server/.venv" "$root/shared/docs/target-server-plan/models" "$root/shared/testdata" "$root/storage" "$root/backups" "$root/bin"
printf 'WOONA_STORAGE_ROOT_HOST=%s/storage\n' "$root" > "$root/shared/.env"
touch "$root/shared/.env.label" "$root/shared/compose.yaml" "$root/shared/compose.label.yaml" "$root/shared/server/.venv/excluded"
cat > "$root/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    *'ps -q api') printf 'api-container\n' ;;
    'inspect --format {{.Image}} api-container') printf 'sha256:api-image\n' ;;
    'image inspect --format {{.Size}} sha256:api-image') printf '1024\n' ;;
    'image save sha256:api-image') tar -cf - --files-from /dev/null ;;
    *) cat >/dev/null ;;
esac
MOCK
chmod +x "$root/bin/docker"
export PATH="$root/bin:$PATH"
cat > "$root/shared/server/backup.label.sh" <<'MOCK'
set -euo pipefail
cd "$WOONA_BACKUP_ROOT"
printf 'database' > "woona-$MOCK_STAMP.dump"
printf 'database' > "labels-$MOCK_STAMP.dump"
tar -cf "storage-$MOCK_STAMP.tar" --files-from /dev/null
tar -cf "label-media-$MOCK_STAMP.tar" --files-from /dev/null
sha256sum ./*.dump ./*.tar > "backup-$MOCK_STAMP.sha256"
if test "${MOCK_CORRUPT:-0}" = 1; then printf 'bad' >> "woona-$MOCK_STAMP.dump"; fi
MOCK
printf 'historical' > "$root/backups/historical.dump"
mkdir -p "$root/backups/.pending-12345678"
printf 'interrupted' > "$root/backups/.pending-12345678/file"
for day in 01 02 03; do
    MOCK_STAMP="202610${day}T020000Z" bash "$runner" "$root/shared" "$root/backups" >/dev/null
done
test ! -e "$root/backups/20261001T020000Z"
test -f "$root/backups/20261002T020000Z/VERIFIED"
test -f "$root/backups/20261003T020000Z/VERIFIED"
tar -tf "$root/backups/20261003T020000Z/deployment.tar" | grep -qx '.env'
if tar -tf "$root/backups/20261003T020000Z/deployment.tar" | grep -q '.venv'; then
    echo 'Deployment cache incorrectly included' >&2; exit 1
fi
grep -q 'api-image.tar' "$root/backups/20261003T020000Z/backup-20261003T020000Z.sha256"
test ! -e "$root/backups/.pending-12345678"
test "$(cat "$root/backups/historical.dump")" = historical
if MOCK_STAMP=20261004T020000Z MOCK_CORRUPT=1 bash "$runner" "$root/shared" "$root/backups" >/dev/null 2>&1; then
    echo 'Corrupt backup incorrectly accepted' >&2; exit 1
fi
test ! -e "$root/backups/20261004T020000Z"
test -f "$root/backups/20261002T020000Z/VERIFIED"
test -f "$root/backups/20261003T020000Z/VERIFIED"
exec 8>"$root/backups/.lock"
flock -n 8
if MOCK_STAMP=20261005T020000Z bash "$runner" "$root/shared" "$root/backups" >/dev/null 2>&1; then
    echo 'Concurrent backup incorrectly accepted' >&2; exit 1
fi
cat > "$root/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "$MOCK_BUNDLE"
MOCK
chmod +x "$root/bin/ssh"
cat > "$root/bin/rsync" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_SOURCE/rsync.log"
[[ "$*" == *'--partial --inplace --checksum'* ]]
[[ "$*" == *'--rsync-path=flock -s /srv/woona/backups/scheduled/.lock rsync'* ]]
destination="${@: -1}"
if test "${MOCK_INTERRUPT:-0}" = 1; then
    head -c 64 "$MOCK_SOURCE/$MOCK_BUNDLE/storage-$MOCK_BUNDLE.tar" > "$destination/storage-$MOCK_BUNDLE.tar"
    exit 23
fi
exec /usr/bin/rsync -rt --partial --inplace --checksum --no-whole-file "$MOCK_SOURCE/$MOCK_BUNDLE/" "$destination"
MOCK
chmod +x "$root/bin/rsync"
export MOCK_SOURCE="$root/backups" MOCK_BUNDLE=20261003T020000Z
pull="$(dirname "$runner")/pull-backup.sh"
if MOCK_INTERRUPT=1 bash "$pull" "$root/offhost" >/dev/null 2>&1; then
    echo 'Interrupted off-host transfer incorrectly accepted' >&2; exit 1
fi
test "$(stat -c %s "$root/offhost/.pending/$MOCK_BUNDLE/storage-$MOCK_BUNDLE.tar")" -eq 64
test ! -e "$root/offhost/$MOCK_BUNDLE"
bash "$pull" "$root/offhost" >/dev/null
test -f "$root/offhost/$MOCK_BUNDLE/VERIFIED"
bash "$pull" "$root/offhost" >/dev/null
test "$(wc -l < "$MOCK_SOURCE/rsync.log")" -eq 2
export MOCK_BUNDLE=20261002T020000Z
mkdir -p "$root/offhost/.pending/20261001T020000Z"
touch -d '40 hours ago' "$root/backups/$MOCK_BUNDLE/VERIFIED"
if bash "$pull" "$root/offhost" >/dev/null 2>&1; then
    echo 'Stale off-host backup incorrectly accepted' >&2; exit 1
fi
test ! -e "$root/offhost/.pending/20261001T020000Z"
test ! -e "$root/offhost/$MOCK_BUNDLE"
touch "$root/backups/$MOCK_BUNDLE/VERIFIED"
printf 'corrupt' >> "$root/backups/$MOCK_BUNDLE/woona-$MOCK_BUNDLE.dump"
if bash "$pull" "$root/offhost" >/dev/null 2>&1; then
    echo 'Corrupt off-host backup incorrectly accepted' >&2; exit 1
fi
test ! -e "$root/offhost/$MOCK_BUNDLE"
printf 'database' > "$root/backups/$MOCK_BUNDLE/woona-$MOCK_BUNDLE.dump"
printf 'badbytes' > "$root/offhost/.pending/$MOCK_BUNDLE/woona-$MOCK_BUNDLE.dump"
touch -r "$root/backups/$MOCK_BUNDLE/woona-$MOCK_BUNDLE.dump" "$root/offhost/.pending/$MOCK_BUNDLE/woona-$MOCK_BUNDLE.dump"
bash "$pull" "$root/offhost" >/dev/null
(cd "$root/offhost/$MOCK_BUNDLE" && sha256sum -c "backup-$MOCK_BUNDLE.sha256" >/dev/null)
printf 'PASS: retention, corruption rejection, history preservation, lock exclusion, real-rsync partial resume and same-size corruption repair, off-host idempotency/freshness, old pending cleanup\n'
