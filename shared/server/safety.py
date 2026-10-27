"""Small storage and database guards shared by API mutations."""
from __future__ import annotations

import errno
import hashlib
import os
import shutil
import uuid
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import text

LOCAL_ONLY_TOKEN = "change-me-local-token"


def identity_lock(connection, kind: str, identity: uuid.UUID) -> None:
    # Row locks cannot serialize creation of an absent row. Transaction-scoped
    # advisory locks also work across API workers and release on rollback.
    key = int.from_bytes(hashlib.sha256(f"woona:{kind}:{identity}".encode()).digest()[:8],
                         "big", signed=True)
    connection.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": key})


def production_auth_guard(connection, token: str) -> None:
    if os.getenv("WOONA_ENVIRONMENT", "development").strip().lower() not in {"production", "prod"}:
        return
    if not token.strip() or token.strip() == LOCAL_ONLY_TOKEN:
        raise RuntimeError("Production requires an explicitly configured non-example device token")
    example_hash = hashlib.sha256(LOCAL_ONLY_TOKEN.encode()).hexdigest()
    if connection.execute(text("""
        SELECT 1 FROM client_devices WHERE token_hash=:hash AND revoked_at IS NULL LIMIT 1
    """), {"hash": example_hash}).first():
        raise RuntimeError("Production has an active example device credential; provision or revoke it explicitly")


def active_entity_sql(kind: str, identity_column: str) -> str:
    # Callers supply only fixed SQL identifiers, never request input.
    if kind not in {"dog", "profile", "recording", "artifact"}:
        raise ValueError("Invalid entity kind")
    return ("NOT EXISTS (SELECT 1 FROM retired_entities retired "
            f"WHERE retired.kind='{kind}' AND retired.id_sha256="
            f"encode(sha256(convert_to({identity_column}::text,'UTF8')),'hex'))")


def append_upload(part: Path, body: bytes | bytearray, acknowledged_offset: int) -> None:
    # This is a fixed filesystem reserve, not an account quota or cleanup policy.
    reserve = max(0, int(os.getenv("WOONA_UPLOAD_FREE_SPACE_RESERVE_BYTES", str(256 * 1024 * 1024))))
    try:
        available = shutil.disk_usage(part.parent).free
        if available < len(body) + reserve:
            raise HTTPException(507, detail={"code": "storage_space_low",
                "availableBytes": available, "requiredBytes": len(body) + reserve,
                "uploadOffset": acknowledged_offset}, headers={"Retry-After": "60",
                "Upload-Offset": str(acknowledged_offset)})
        with part.open("ab", buffering=0) as output:
            remaining = memoryview(body)
            while remaining:
                written = output.write(remaining)
                if written is None or written <= 0:
                    raise OSError(errno.EIO, "Upload write made no progress")
                remaining = remaining[written:]
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        # Leave acknowledged bytes and any unacknowledged tail intact. A retry
        # uses HEAD and the existing reconciliation before appending again.
        code = "storage_full" if error.errno in {errno.ENOSPC, errno.EDQUOT} else "storage_unavailable"
        raise HTTPException(507 if code == "storage_full" else 503,
            detail={"code": code, "uploadOffset": acknowledged_offset},
            headers={"Retry-After": "60", "Upload-Offset": str(acknowledged_offset)}) from error
