"""Bounded, explicitly scoped integrity pages; never an unbounded HTTP hash scan."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import time

from fastapi import HTTPException
from sqlalchemy import text

from server.storage_policy import ACTIVE_ARTIFACTS, setting

AUDIT_LOCK = 514101967130924612


def audit_limits() -> dict:
    return {'maxArtifacts': min(100, max(1, setting('WOONA_INTEGRITY_MAX_ARTIFACTS', 50))),
            'maxFileBytes': min(64 * 1024 ** 2, setting('WOONA_INTEGRITY_MAX_FILE_BYTES', 16 * 1024 ** 2)),
            'maxHashBytes': min(256 * 1024 ** 2, setting('WOONA_INTEGRITY_MAX_HASH_BYTES', 32 * 1024 ** 2)),
            'maxSeconds': min(5, max(1, setting('WOONA_INTEGRITY_MAX_SECONDS', 2))),
            'minimumIntervalSeconds': min(86_400, max(1, setting('WOONA_INTEGRITY_MIN_INTERVAL_SECONDS', 1)))}


def begin_audit(connection, policy: dict, mode: str) -> None:
    acquired = connection.execute(text('SELECT pg_try_advisory_xact_lock(:key)'),
                                  {'key': AUDIT_LOCK}).scalar_one()
    if not acquired:
        raise HTTPException(429, detail={'code': 'integrity_check_busy', 'phase': 'concurrent_audit'},
                            headers={'Retry-After': '1'})
    interval = policy['minimumIntervalSeconds'] if mode == 'sha256' else 0
    if not interval:
        return
    accepted = connection.execute(text('''INSERT INTO integrity_check_budget(id,next_allowed_at)
        VALUES(1,clock_timestamp() + :seconds * interval '1 second')
        ON CONFLICT(id) DO UPDATE SET next_allowed_at=EXCLUDED.next_allowed_at
        WHERE integrity_check_budget.next_allowed_at <= clock_timestamp()
        RETURNING id'''), {'seconds': interval}).first()
    if accepted is None:
        seconds = connection.execute(text('''SELECT GREATEST(1,ceil(extract(epoch FROM
            next_allowed_at-clock_timestamp()))) FROM integrity_check_budget WHERE id=1''')).scalar_one()
        raise HTTPException(429, detail={'code': 'integrity_check_busy', 'phase': 'cooldown'},
                            headers={'Retry-After': str(int(seconds))})


def inspect_page(root: Path, rows, *, mode: str, policy: dict,
                 started_at: float | None = None, clock=time.monotonic) -> dict:
    deadline = (clock() if started_at is None else started_at) + policy['maxSeconds']
    problems, unchecked = [], []
    hashed_bytes = 0
    hashed_artifacts = 0
    processed = []
    time_exhausted = False
    for row in rows:
        if processed and clock() >= deadline:
            time_exhausted = True
            break
        identity = str(row['id'])
        processed.append(identity)
        try:
            path = (root / (row['server_relative_path'] or '')).resolve()
            if root not in path.parents:
                raise FileNotFoundError
            descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
            with os.fdopen(descriptor, 'rb') as source:
                before = os.fstat(source.fileno())
                if not stat.S_ISREG(before.st_mode):
                    problems.append({'artifactId': identity, 'problem': 'not_regular_file'})
                    continue
                if before.st_size != row['expected_size_bytes']:
                    problems.append({'artifactId': identity, 'problem': 'size'})
                    continue
                reason = ('hash_not_requested' if mode == 'metadata' else
                          'file_hash_limit' if before.st_size > policy['maxFileBytes'] else
                          'page_hash_budget' if hashed_bytes + before.st_size > policy['maxHashBytes'] else None)
                if reason:
                    unchecked.append({'artifactId': identity, 'reason': reason, 'sizeBytes': before.st_size})
                    continue
                digest = hashlib.sha256()
                remaining = before.st_size
                while remaining:
                    if clock() >= deadline:
                        time_exhausted = True
                        break
                    chunk = source.read(min(1024 ** 2, remaining))
                    if not chunk:
                        break
                    digest.update(chunk)
                    hashed_bytes += len(chunk)
                    remaining -= len(chunk)
                if time_exhausted:
                    unchecked.append({'artifactId': identity, 'reason': 'time_budget', 'sizeBytes': before.st_size})
                    continue
                after = os.fstat(source.fileno())
                if remaining or before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns:
                    problems.append({'artifactId': identity, 'problem': 'changed_during_check'})
                    continue
                hashed_artifacts += 1
                if digest.hexdigest() != row['sha256']:
                    problems.append({'artifactId': identity, 'problem': 'hash'})
        except FileNotFoundError:
            problems.append({'artifactId': identity, 'problem': 'missing'})
        except (OSError, RuntimeError):
            problems.append({'artifactId': identity, 'problem': 'unreadable'})
    return {'problems': problems, 'uncheckedArtifacts': unchecked,
            'checkedArtifacts': len(processed), 'hashedArtifacts': hashed_artifacts,
            'hashedBytes': hashed_bytes, 'lastProcessedId': processed[-1] if processed else None,
            'timeBudgetExhausted': time_exhausted}


def integrity_page(connection, root: Path, account, *, mode='sha256', limit=None, cursor=None, policy=None) -> dict:
    policy = audit_limits() if policy is None else policy
    page_limit = min(limit or policy['maxArtifacts'], policy['maxArtifacts'])
    started = time.monotonic()
    def query_budget():
        milliseconds = max(1, int((started + policy['maxSeconds'] - time.monotonic()) * 1000))
        connection.execute(text("SELECT set_config('statement_timeout', :timeout, true)"),
                           {'timeout': str(milliseconds) + 'ms'})
    query_budget()
    begin_audit(connection, policy, mode)
    where = f'''a.storage_status='available' AND {ACTIVE_ARTIFACTS}
        AND d.account_id IS NOT DISTINCT FROM CAST(:account AS text)'''
    common = '''FROM artifacts a JOIN recordings r ON r.id=a.recording_id
        JOIN dogs d ON d.id=r.dog_id'''
    query_budget()
    # Totals and the page share ONE PostgreSQL statement snapshot. A concurrent
    # upload becoming available cannot make counts describe another dataset.
    combined = connection.execute(text(f'''SELECT page.*,totals.scope_artifacts,totals.scope_bytes
        FROM (SELECT count(*) AS scope_artifacts,COALESCE(sum(a.expected_size_bytes),0) AS scope_bytes
              {common} WHERE {where}) totals
        LEFT JOIN LATERAL (
            SELECT a.id,a.server_relative_path,a.expected_size_bytes,a.sha256
            {common} WHERE {where} AND (CAST(:cursor AS uuid) IS NULL OR a.id > CAST(:cursor AS uuid))
            ORDER BY a.id LIMIT :limit
        ) page ON true ORDER BY page.id'''), {'account': account,
        'cursor': str(cursor) if cursor else None, 'limit': page_limit + 1}).mappings().all()
    totals = combined[0]
    rows = [row for row in combined if row['id'] is not None]
    result = inspect_page(root, rows[:page_limit], mode=mode, policy=policy, started_at=started)
    checked = result['checkedArtifacts']
    has_more = len(rows) > checked
    last = result.pop('lastProcessedId')
    scope_complete = not cursor and not has_more and not result['uncheckedArtifacts']
    verified = scope_complete and not result['problems']
    result.update({'status': 'failed' if result['problems'] else 'ok' if verified else 'partial',
        'checkedScope': {'accountId': account, 'unassignedOnly': account is None, 'includesAllAccounts': False},
        'mode': mode, 'scopeArtifacts': totals['scope_artifacts'], 'scopeExpectedBytes': int(totals['scope_bytes']),
        'coverage': {'pageChecksumVerified': checked == result['hashedArtifacts'] and not result['problems'],
                     'scopeChecksumVerified': verified},
        'limits': policy, 'hasMore': has_more, 'nextCursor': last if has_more else None,
        'nextAction': 'review_integrity_problems' if result['problems'] else
            'continue_integrity_pages' if has_more else
            'run_operator_integrity_audit' if not verified else 'none'})
    return result
