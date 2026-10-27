#!/usr/bin/env bash
# Disabled entrypoints must reject before any file, network or service operation.
set -euo pipefail
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin"
for name in docker ssh rsync tar pg_dump systemctl mkdir cp mv rm find install flock date; do
    cat > "$test_root/bin/$name" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}: forbidden backup side effect" >> "$WOONA_DISABLED_TEST_LOG"
exit 99
MOCK
    chmod +x "$test_root/bin/$name"
done
if [[ $# -eq 0 ]]; then
    set -- "$(dirname "$0")/../backup.sh" "$(dirname "$0")/../backup.label.sh"
fi
for entry in "$@"; do
    set +e
    PATH="$test_root/bin:$PATH" WOONA_DISABLED_TEST_LOG="$test_root/side-effects.log" \
        WOONA_ENABLE_BACKUPS=1 WOONA_BACKUP_ROOT="$test_root/never-created" \
        WOONA_STORAGE_ROOT_HOST="$test_root/never-read" \
        bash "$entry" "$test_root/never-created" "$test_root/also-never-created" > "$test_root/output" 2>&1
    status=$?
    set -e
    test "$status" -eq 78 || { cat "$test_root/output"; echo 'Retired backup must return 78' >&2; exit 1; }
    grep -q 'disabled by owner request (2026-10-27)' "$test_root/output"
    test ! -e "$test_root/side-effects.log"
    test ! -e "$test_root/never-created"
    test ! -e "$test_root/also-never-created"
done
printf '%s\n' 'PASS: backup entrypoints are disabled before file, network and service side effects'
