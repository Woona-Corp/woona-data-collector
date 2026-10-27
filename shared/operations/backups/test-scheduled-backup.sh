#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
test ! -e "$root/woona-backup.service"
test ! -e "$root/woona-backup.timer"
bash "$root/../../server/tests/test_backup.sh" "$root/scheduled-backup.sh" "$root/pull-backup.sh"
printf '%s\n' 'PASS: scheduled/off-host entrypoints disabled and deployable timer/service templates absent'
