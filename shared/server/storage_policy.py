"""Transactional manifest quotas and filesystem reservation admission.

Declared bytes remain charged while uploading/corrupt: partial uploads never
evade the account limit. These guards do not delete or rewrite source data.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import uuid

from fastapi import HTTPException
from sqlalchemy import text

from server.safety import active_entity_sql, identity_lock

GIB = 1024 ** 3
RESERVATION_ID = uuid.UUID('8209d0c4-70f5-42d0-8c33-a49e23275fc0')
ACTIVE_ARTIFACTS = ' AND '.join((active_entity_sql('dog', 'd.id'),
    active_entity_sql('profile', 'r.dog_profile_version_id'),
    active_entity_sql('recording', 'r.id'), active_entity_sql('artifact', 'a.id')))


def setting(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError as error:
        raise RuntimeError(f'{name} must be a nonnegative integer') from error
    if value < 0 or value >= 2 ** 63:
        raise RuntimeError(f'{name} must fit the nonnegative signed 64-bit range')
    return value


def limits() -> dict[str, int]:
    return {'recordingBytes': setting('WOONA_RECORDING_QUOTA_BYTES', 20 * GIB),
            'accountBytes': setting('WOONA_ACCOUNT_QUOTA_BYTES', 100 * GIB),
            'freeSpaceReserveBytes': setting('WOONA_UPLOAD_FREE_SPACE_RESERVE_BYTES', 256 * 1024 ** 2)}


def reservation_lock(connection) -> None:
    # Obtain only AFTER the caller's entity/row locks. No entity locks may be
    # acquired after this point; this order also covers account assignment and
    # corrupt-upload resets without blocking ordinary incremental writes.
    identity_lock(connection, 'storage-reservation', RESERVATION_ID)


def reserved_bytes(connection, *, recording_id=None, account=None, dog_id=None) -> int:
    where = 'r.id=:recording' if recording_id is not None else (
        'd.id=:dog' if dog_id is not None else 'd.account_id IS NOT DISTINCT FROM CAST(:account AS text)')
    return int(connection.execute(text(f'''SELECT COALESCE(sum(a.expected_size_bytes),0)
        FROM artifacts a JOIN recordings r ON r.id=a.recording_id JOIN dogs d ON d.id=r.dog_id
        WHERE {ACTIVE_ARTIFACTS} AND {where}'''),
        {'recording': recording_id, 'account': account, 'dog': dog_id}).scalar_one())


def quota_error(scope: str, limit: int, reserved: int, requested: int) -> None:
    if limit and reserved + requested > limit:
        raise HTTPException(413, detail={'code': 'storage_quota_exceeded',
            'quotaScope': scope, 'limitBytes': limit, 'reservedBytes': reserved,
            'requestedBytes': requested})


def pending_reservation(connection, root: Path) -> tuple[int, int]:
    # Snapshot pending metadata first, then measure free space. Concurrent
    # successful writes can only make this estimate conservative. Internal
    # downward resets take reservation_lock before truncating/resetting.
    rows = connection.execute(text(f'''SELECT a.id,a.expected_size_bytes,a.stored_size_bytes
        FROM artifacts a JOIN recordings r ON r.id=a.recording_id JOIN dogs d ON d.id=r.dog_id
        WHERE a.storage_status <> 'available' AND {ACTIVE_ARTIFACTS}''')).mappings().all()
    pending = 0
    for row in rows:
        try:
            part = root / 'incoming' / f"{row['id']}.part"
            info = part.lstat()
            actual = info.st_size if stat.S_ISREG(info.st_mode) and root in part.resolve().parents else 0
        except (OSError, RuntimeError):
            # Unreadable or unresolvable prefixes cannot count as durable
            # acknowledged bytes; reserve the full declaration conservatively.
            actual = 0
        acknowledged = min(row['stored_size_bytes'], actual)
        pending += max(0, row['expected_size_bytes'] - acknowledged)
    return pending, len(rows)


def reserve_manifest(connection, root: Path, recording_id, account, additions) -> None:
    # Called only for a genuinely new artifact. Existing-manifest/idempotent
    # retries and upload resumption continue even after a limit is lowered.
    if not additions:
        return
    size = sum(item.size_bytes for item in additions)
    reservation_lock(connection)
    policy = limits()
    quota_error('recording', policy['recordingBytes'],
                reserved_bytes(connection, recording_id=recording_id), size)
    quota_error('account', policy['accountBytes'], reserved_bytes(connection, account=account), size)
    if size == 0:
        return
    pending, _ = pending_reservation(connection, root)
    available = shutil.disk_usage(root).free
    required = pending + size + policy['freeSpaceReserveBytes']
    if available < required:
        raise HTTPException(507, detail={'code': 'storage_reservation_unavailable',
            'availableBytes': available, 'pendingReservedBytes': pending,
            'requestedBytes': size, 'requiredBytes': required}, headers={'Retry-After': '60'})


def reserve_artifact(connection, root: Path, recording_id, artifact) -> None:
    account = connection.execute(text('''SELECT d.account_id FROM recordings r
        JOIN dogs d ON d.id=r.dog_id WHERE r.id=:id'''), {'id': recording_id}).scalar_one()
    reserve_manifest(connection, root, recording_id, account, [artifact])


def check_account_assignment(connection, dog_id, account: str) -> None:
    reservation_lock(connection)
    quota_error('account', limits()['accountBytes'], reserved_bytes(connection, account=account),
                reserved_bytes(connection, dog_id=dog_id))


def current_acknowledged_bytes(connection, root: Path, account) -> int:
    rows = connection.execute(text(f'''SELECT a.id,a.storage_status,a.server_relative_path,
        a.expected_size_bytes,a.stored_size_bytes
        FROM artifacts a JOIN recordings r ON r.id=a.recording_id JOIN dogs d ON d.id=r.dog_id
        WHERE {ACTIVE_ARTIFACTS} AND d.account_id IS NOT DISTINCT FROM CAST(:account AS text)'''),
        {'account': account}).mappings().all()
    total = 0
    for row in rows:
        try:
            if row['storage_status'] == 'available':
                path = (root / (row['server_relative_path'] or '')).resolve()
                if root not in path.parents:
                    continue
                info = path.stat()
                if stat.S_ISREG(info.st_mode) and info.st_size == row['expected_size_bytes']:
                    total += row['stored_size_bytes']
            else:
                part = root / 'incoming' / f"{row['id']}.part"
                info = part.lstat()
                if stat.S_ISREG(info.st_mode) and root in part.resolve().parents:
                    total += min(row['stored_size_bytes'], info.st_size)
        except (OSError, RuntimeError):
            continue
    return total


def storage_status(connection, root: Path, account: str | None) -> dict:
    # Account accounting and global filesystem capacity are separate scopes;
    # no identifiers or amounts belonging to another individual account leak.
    reservation_lock(connection)
    policy = limits()
    declared = reserved_bytes(connection, account=account)
    active_parents = ' AND '.join((active_entity_sql('dog', 'd.id'),
        active_entity_sql('profile', 'r.dog_profile_version_id'), active_entity_sql('recording', 'r.id')))
    counts = connection.execute(text(f'''SELECT count(DISTINCT r.id) AS recordings,
        count(a.id) AS artifacts, COALESCE(sum(a.stored_size_bytes),0) AS acknowledged
        FROM recordings r JOIN dogs d ON d.id=r.dog_id
        LEFT JOIN artifacts a ON a.recording_id=r.id AND {active_entity_sql('artifact', 'a.id')}
        WHERE {active_parents} AND d.account_id IS NOT DISTINCT FROM CAST(:account AS text)'''),
        {'account': account}).mappings().one()
    pending, pending_files = pending_reservation(connection, root)
    acknowledged = current_acknowledged_bytes(connection, root, account)
    disk = shutil.disk_usage(root)
    usable = max(0, disk.free - policy['freeSpaceReserveBytes'] - pending)
    remaining = max(0, policy['accountBytes'] - declared) if policy['accountBytes'] else None
    blocked = []
    if remaining == 0:
        blocked.append('account_quota_reached')
    if usable == 0:
        blocked.append('server_capacity_reserved')
    return {'checkedScope': {'accountId': account, 'unassignedOnly': account is None,
                             'includesAllAccounts': False},
        'limits': policy,
        'account': {'declaredReservedBytes': declared, 'acknowledgedBytes': acknowledged,
                    'metadataAcknowledgedBytes': counts['acknowledged'],
                    'remainingQuotaBytes': remaining,
                    'recordings': counts['recordings'], 'artifacts': counts['artifacts']},
        'serverStorage': {'totalBytes': disk.total, 'freeBytes': disk.free,
                          'freeSpaceReserveBytes': policy['freeSpaceReserveBytes'],
                          'pendingReservedBytes': pending, 'pendingArtifacts': pending_files,
                          'newReservationAvailableBytes': usable, 'scope': 'server'},
        'status': 'account_quota_reached' if remaining == 0 else 'capacity_reserved' if blocked else 'ready',
        'admission': {'blockingReasons': blocked,
                      'newArtifactUpperBoundBytes': min(usable, remaining if remaining is not None else usable,
                                                       policy['recordingBytes'] or usable)},
        'nextAction': 'review_server_storage_limits' if remaining == 0 else
                      'retry_after_storage_available' if blocked else 'continue_upload',
        'existingUploadsMayResume': True, 'automaticDeletionEnabled': False}
