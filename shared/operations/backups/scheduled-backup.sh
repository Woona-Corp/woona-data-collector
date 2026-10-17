#!/usr/bin/env bash
set -euo pipefail
umask 077

shared="${1:-/opt/woona/shared}"
destination="${2:-/srv/woona/backups/scheduled}"
mkdir -p "$destination"
exec 9>"$destination/.lock"
flock -n 9
shopt -s nullglob
for pending in "$destination"/.pending-????????; do rm -rf -- "$pending"; done
cd "$shared"
compose=(docker compose --env-file "$shared/.env" --env-file "$shared/.env.label" -f "$shared/compose.yaml" -f "$shared/compose.label.yaml")
api_container="$("${compose[@]}" ps -q api)"
test -n "$api_container"
api_image="$(docker inspect --format '{{.Image}}' "$api_container")"
deployment=(.env .env.label compose.yaml compose.label.yaml server docs/target-server-plan/models testdata)
storage="$(python3 -c 'from pathlib import Path; print(next(x.split("=", 1)[1] for x in Path(".env").read_text().splitlines() if x.startswith("WOONA_STORAGE_ROOT_HOST=")))')"
# shortcut: 2 GiB covers current dumps/media; increase when they approach this size.
required=$(( $(du -sb "$storage" "${deployment[@]}" | awk '{sum += $1} END {printf "%.0f", sum}') + $(docker image inspect --format '{{.Size}}' "$api_image") + 2147483648 ))
available="$(df -PB1 "$destination" | awk 'NR == 2 {print $4}')"
(( available >= required )) || { echo 'Insufficient disk for full backup plus 2 GiB margin' >&2; exit 1; }
stage="$(mktemp -d "$destination/.pending-XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
tar -cf "$stage/deployment.tar" --exclude=.venv --exclude=__pycache__ \
    --exclude=.pytest_cache --exclude=build --exclude='*.egg-info' "${deployment[@]}"
docker image save "$api_image" > "$stage/api-image.tar"
WOONA_BACKUP_ROOT="$stage" bash server/backup.label.sh
cd "$stage"
checksums=(backup-*.sha256)
test "${#checksums[@]}" -eq 1
sha256sum deployment.tar api-image.tar >> "${checksums[0]}"
sha256sum -c "${checksums[0]}"
for archive in storage-*.tar label-media-*.tar deployment.tar api-image.tar; do tar -tf "$archive" >/dev/null; done
for dump in woona-*.dump labels-*.dump; do
    "${compose[@]}" exec -T postgres pg_restore --list < "$dump" >/dev/null
done
touch VERIFIED
bundle="${checksums[0]#backup-}"
bundle="${bundle%.sha256}"
cd "$destination"
test ! -e "$bundle"
mv -- "$stage" "$bundle"
trap - EXIT
bundles=([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
verified=()
for directory in "${bundles[@]}"; do
    if test -f "$directory/VERIFIED"; then verified+=("$directory"); fi
done
for ((i=0; i<${#verified[@]}-2; i++)); do rm -rf -- "${verified[i]}"; done
printf 'Verified scheduled backup: %s/%s\n' "$destination" "$bundle"
