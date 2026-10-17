#!/usr/bin/env bash
set -euo pipefail
umask 077

destination="${1:-$HOME/.local/share/woona-backups}"
mkdir -p "$destination"
exec 9>"$destination/.lock"
flock -n 9
shopt -s nullglob
bundle="$(ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 root@167.99.223.71 'bash -se' <<'REMOTE'
set -euo pipefail
cd /srv/woona/backups/scheduled
exec 8<.lock
flock -s 8
shopt -s nullglob
bundles=([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
latest=''
for directory in "${bundles[@]}"; do
    if test -f "$directory/VERIFIED"; then latest="$directory"; fi
done
test -n "$latest"
printf '%s\n' "$latest"
REMOTE
)"
[[ "$bundle" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo 'Invalid remote bundle name' >&2; exit 1; }
mkdir -p "$destination/.pending"
for pending in "$destination"/.pending/*; do
    if test "$(basename "$pending")" != "$bundle"; then rm -rf -- "$pending"; fi
done
stage="$destination/.pending/$bundle"
already_verified=false
if test -f "$destination/$bundle/VERIFIED"; then
    already_verified=true
    cd "$destination/$bundle"
else
    mkdir -p "$stage"
    rsync -rt --partial --inplace --checksum \
        -e 'ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3' \
        --rsync-path='flock -s /srv/woona/backups/scheduled/.lock rsync' \
        "root@167.99.223.71:/srv/woona/backups/scheduled/$bundle/" "$stage/"
    cd "$stage"
fi
test -f VERIFIED
age=$(( $(date +%s) - $(stat -c %Y VERIFIED) ))
(( age >= 0 && age <= 129600 )) || { echo 'Remote backup is older than 36 hours (or clock is ahead)' >&2; exit 1; }
if $already_verified; then
    rm -rf -- "$stage"
    printf 'Already verified off-host backup: %s/%s\n' "$destination" "$bundle"
    exit 0
fi
checksums=(backup-*.sha256)
test "${#checksums[@]}" -eq 1
sha256sum -c "${checksums[0]}"
for archive in storage-*.tar label-media-*.tar deployment.tar api-image.tar; do tar -tf "$archive" >/dev/null; done
cd "$destination"
test ! -e "$bundle"
mv -- "$stage" "$bundle"
shopt -s nullglob
verified=()
for directory in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z; do
    if test -f "$directory/VERIFIED"; then verified+=("$directory"); fi
done
for ((i=0; i<${#verified[@]}-2; i++)); do rm -rf -- "${verified[i]}"; done
printf 'Verified off-host backup: %s/%s\n' "$destination" "$bundle"
