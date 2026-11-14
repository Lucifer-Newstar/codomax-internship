"""Task + deployment storage. PostgresTaskStore for real use, MemoryTaskStore for unit tests."""

from __future__ import annotations

import logging
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

log = logging.getLogger("cloudops.db")

# database/init.sql in the repo; the Dockerfile copies it next to the package as well.
_CANDIDATES = (
    Path(__file__).resolve().parents[2] / "database" / "init.sql",
    Path(__file__).resolve().parent / "init.sql",
)
STATUSES = ("todo", "doing", "done")
TITLE_MAX, DESC_MAX = 140, 5000
COLS = "id, title, description, status, priority, created_at, updated_at"


class TaskNotFound(LookupError):
    pass


class StoreUnavailable(RuntimeError):
    pass


def _iso(v):
    return v.isoformat() if hasattr(v, "isoformat") else v


def _task(row) -> dict[str, Any]:
    keys = ("id", "title", "description", "status", "priority", "created_at", "updated_at")
    d = dict(zip(keys, row, strict=True))
    d["created_at"], d["updated_at"] = _iso(d["created_at"]), _iso(d["updated_at"])
    return d


def schema_sql() -> str:
    for p in _CANDIDATES:
        if p.is_file():
            return p.read_text(encoding="utf-8")
    raise FileNotFoundError("init.sql not found")


class PostgresTaskStore:
    def __init__(self, database_url: str, sslmode: str = "prefer", connect_timeout: int = 5):
        self._url, self._sslmode, self._timeout = database_url, sslmode, connect_timeout

    def _connect(self):
        import psycopg

        try:
            return psycopg.connect(
                self._url,
                sslmode=self._sslmode,
                connect_timeout=self._timeout,
                application_name="cloudops-api",
            )
        except psycopg.OperationalError as exc:
            raise StoreUnavailable(f"database connection failed: {exc}".strip()) from exc

    def init_schema(self) -> None:
        with self._connect() as conn:
            conn.execute(schema_sql())
        log.info("database schema ensured")

    def ping(self) -> dict[str, Any]:
        with self._connect() as conn:
            version = conn.execute("SELECT version()").fetchone()[0]
        return {"backend": "postgres", "server_version": version.split(" on ")[0]}

    def list(self, status: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        q = f"SELECT {COLS} FROM tasks"
        params: tuple = ()
        if status:
            q += " WHERE status = %s"
            params = (status,)
        q += " ORDER BY status, priority, created_at DESC LIMIT %s"
        with self._connect() as conn:
            return [_task(r) for r in conn.execute(q, (*params, limit)).fetchall()]

    def get(self, task_id: int) -> dict[str, Any]:
        with self._connect() as conn:
            row = conn.execute(f"SELECT {COLS} FROM tasks WHERE id = %s", (task_id,)).fetchone()
        if row is None:
            raise TaskNotFound(task_id)
        return _task(row)

    def create(self, title: str, description: str, priority: int) -> dict[str, Any]:
        with self._connect() as conn:
            row = conn.execute(
                f"INSERT INTO tasks (title, description, priority) VALUES (%s, %s, %s) "
                f"RETURNING {COLS}",
                (title, description, priority),
            ).fetchone()
        return _task(row)

    def update(self, task_id: int, fields: dict[str, Any]) -> dict[str, Any]:
        sets = ", ".join(f"{k} = %s" for k in fields)  # keys are whitelisted by the route layer
        with self._connect() as conn:
            row = conn.execute(
                f"UPDATE tasks SET {sets}, updated_at = now() WHERE id = %s RETURNING {COLS}",
                (*fields.values(), task_id),
            ).fetchone()
        if row is None:
            raise TaskNotFound(task_id)
        return _task(row)

    def delete(self, task_id: int) -> None:
        with self._connect() as conn:
            if conn.execute("DELETE FROM tasks WHERE id = %s", (task_id,)).rowcount == 0:
                raise TaskNotFound(task_id)

    def stats(self) -> dict[str, Any]:
        with self._connect() as conn:
            rows = conn.execute("SELECT status, count(*) FROM tasks GROUP BY status").fetchall()
            dep = conn.execute(
                "SELECT version, git_sha, environment, hostname, deployed_at FROM deployments "
                "ORDER BY deployed_at DESC LIMIT 1"
            ).fetchone()
        by_status = {s: 0 for s in STATUSES}
        by_status.update(dict(rows))
        last = None
        if dep:
            keys = ("version", "git_sha", "environment", "hostname", "deployed_at")
            last = dict(zip(keys, dep, strict=True))
            last["deployed_at"] = _iso(last["deployed_at"])
        return {"tasks": by_status, "total": sum(by_status.values()), "last_deployment": last}

    def record_deployment(self, version: str, git_sha: str, environment: str, hostname: str):
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO deployments (version, git_sha, environment, hostname) "
                "VALUES (%s, %s, %s, %s)",
                (version, git_sha, environment, hostname),
            )


class MemoryTaskStore:
    def __init__(self):
        self._lock = threading.Lock()
        self._tasks: dict[int, dict[str, Any]] = {}
        self._next = 1
        self._deployments: list[dict[str, Any]] = []

    def init_schema(self) -> None:
        return None

    def ping(self) -> dict[str, Any]:
        return {"backend": "memory"}

    def list(self, status: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        with self._lock:
            items = [dict(t) for t in self._tasks.values() if not status or t["status"] == status]
        order = {s: i for i, s in enumerate(STATUSES)}
        items.sort(key=lambda t: (order[t["status"]], t["priority"], -t["id"]))
        return items[:limit]

    def get(self, task_id: int) -> dict[str, Any]:
        with self._lock:
            if task_id not in self._tasks:
                raise TaskNotFound(task_id)
            return dict(self._tasks[task_id])

    def create(self, title: str, description: str, priority: int) -> dict[str, Any]:
        now = datetime.now(UTC).isoformat()
        with self._lock:
            t = {
                "id": self._next,
                "title": title,
                "description": description,
                "status": "todo",
                "priority": priority,
                "created_at": now,
                "updated_at": now,
            }
            self._tasks[self._next] = t
            self._next += 1
        return dict(t)

    def update(self, task_id: int, fields: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            if task_id not in self._tasks:
                raise TaskNotFound(task_id)
            self._tasks[task_id].update(fields)
            self._tasks[task_id]["updated_at"] = datetime.now(UTC).isoformat()
            return dict(self._tasks[task_id])

    def delete(self, task_id: int) -> None:
        with self._lock:
            if self._tasks.pop(task_id, None) is None:
                raise TaskNotFound(task_id)

    def stats(self) -> dict[str, Any]:
        with self._lock:
            by_status = {
                s: sum(1 for t in self._tasks.values() if t["status"] == s) for s in STATUSES
            }
            last = dict(self._deployments[-1]) if self._deployments else None
        return {"tasks": by_status, "total": sum(by_status.values()), "last_deployment": last}

    def record_deployment(self, version, git_sha, environment, hostname) -> None:
        with self._lock:
            self._deployments.append(
                {
                    "version": version,
                    "git_sha": git_sha,
                    "environment": environment,
                    "hostname": hostname,
                    "deployed_at": datetime.now(UTC).isoformat(),
                }
            )


def make_store(settings):
    if settings.task_store == "memory":
        return MemoryTaskStore()
    return PostgresTaskStore(settings.database_url, sslmode=settings.db_sslmode)
