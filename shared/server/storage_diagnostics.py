"""Cooperative budgets for read-only storage diagnostics, never upload admission."""
from __future__ import annotations

import time

from fastapi import HTTPException
from sqlalchemy import text


def unavailable(phase: str) -> HTTPException:
    return HTTPException(503, detail={'code': 'storage_status_busy', 'phase': phase},
                         headers={'Retry-After': '1'})


class DiagnosticBudget:
    def __init__(self, max_artifacts: int, timeout_ms: int, *, clock=None):
        if max_artifacts < 1 or timeout_ms < 1:
            raise ValueError('Diagnostic budgets must be positive')
        self.max_artifacts = max_artifacts
        self.timeout_ms = timeout_ms
        self.clock = time.monotonic if clock is None else clock
        self.deadline = self.clock() + timeout_ms / 1000
        self.visited = 0

    def check(self) -> int:
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise unavailable('time_budget')
        return max(1, int(remaining * 1000))

    def query(self, connection) -> None:
        # Transaction-local: never change the pool connection's global settings.
        connection.execute(text("SELECT set_config('statement_timeout', :timeout, true)"),
                           {'timeout': str(self.check()) + 'ms'})

    def rows(self, connection, statement: str, parameters=None):
        self.query(connection)
        remaining = self.max_artifacts - self.visited
        # Fetch one sentinel only; reject incomplete accounting before any stats.
        rows = connection.execute(text(statement + ' ORDER BY a.id LIMIT :diagnostic_limit'),
            {**(parameters or {}), 'diagnostic_limit': remaining + 1}).mappings().all()
        if len(rows) > remaining:
            raise unavailable('artifact_budget')
        self.visited += len(rows)
        self.check()
        return rows
