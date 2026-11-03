"""Data access for notes.

Two implementations behind the same small interface:
- PostgresNotesStore: the real one (psycopg 3, one short-lived connection per operation).
- MemoryNotesStore:   in-process dict, used by unit tests so they run without a database.

Keeping SQL in one place makes it easy to see exactly what the app does to the database.
"""

from __future__ import annotations

import logging
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

log = logging.getLogger("cloudops.db")

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schema.sql"
TITLE_MAX = 120
BODY_MAX = 5000


class NoteNotFound(LookupError):
    pass


class StoreUnavailable(RuntimeError):
    """The backing store cannot be reached (e.g. database down)."""


def _row_to_dict(row: tuple) -> dict[str, Any]:
    note_id, title, body, created_at, updated_at = row
    return {
        "id": note_id,
        "title": title,
        "body": body,
        "created_at": created_at.isoformat(),
        "updated_at": updated_at.isoformat(),
    }


class PostgresNotesStore:
    def __init__(self, database_url: str, sslmode: str = "prefer", connect_timeout: int = 5):
        self._url = database_url
        self._sslmode = sslmode
        self._timeout = connect_timeout

    # --- connection helpers -------------------------------------------------------------
    def _connect(self):
        import psycopg  # imported here so the memory store works without psycopg installed

        try:
            return psycopg.connect(
                self._url,
                sslmode=self._sslmode,
                connect_timeout=self._timeout,
                application_name="cloudops-notes",
            )
        except psycopg.OperationalError as exc:
            # Never log the URL: it contains the password.
            raise StoreUnavailable(f"database connection failed: {exc}".strip()) from exc

    def init_schema(self) -> None:
        sql = SCHEMA_PATH.read_text(encoding="utf-8")
        with self._connect() as conn:
            conn.execute(sql)
        log.info("database schema ensured")

    def ping(self) -> dict[str, Any]:
        """Return a small dict for the readiness check, raise StoreUnavailable on failure."""
        with self._connect() as conn:
            version = conn.execute("SELECT version()").fetchone()[0]
        return {"backend": "postgres", "server_version": version.split(" on ")[0]}

    # --- CRUD -----------------------------------------------------------------------------
    def list(self, limit: int = 100) -> list[dict[str, Any]]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id, title, body, created_at, updated_at FROM notes "
                "ORDER BY created_at DESC, id DESC LIMIT %s",
                (limit,),
            ).fetchall()
        return [_row_to_dict(r) for r in rows]

    def get(self, note_id: int) -> dict[str, Any]:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT id, title, body, created_at, updated_at FROM notes WHERE id = %s",
                (note_id,),
            ).fetchone()
        if row is None:
            raise NoteNotFound(note_id)
        return _row_to_dict(row)

    def create(self, title: str, body: str) -> dict[str, Any]:
        with self._connect() as conn:
            row = conn.execute(
                "INSERT INTO notes (title, body) VALUES (%s, %s) "
                "RETURNING id, title, body, created_at, updated_at",
                (title, body),
            ).fetchone()
        return _row_to_dict(row)

    def delete(self, note_id: int) -> None:
        with self._connect() as conn:
            cur = conn.execute("DELETE FROM notes WHERE id = %s", (note_id,))
            if cur.rowcount == 0:
                raise NoteNotFound(note_id)

    def count(self) -> int:
        with self._connect() as conn:
            return conn.execute("SELECT count(*) FROM notes").fetchone()[0]


class MemoryNotesStore:
    """Thread-safe in-memory store with the same interface. For tests only."""

    def __init__(self):
        self._lock = threading.Lock()
        self._notes: dict[int, dict[str, Any]] = {}
        self._next_id = 1

    def init_schema(self) -> None:
        return None

    def ping(self) -> dict[str, Any]:
        return {"backend": "memory"}

    def list(self, limit: int = 100) -> list[dict[str, Any]]:
        with self._lock:
            notes = sorted(self._notes.values(), key=lambda n: n["id"], reverse=True)
        return notes[:limit]

    def get(self, note_id: int) -> dict[str, Any]:
        with self._lock:
            if note_id not in self._notes:
                raise NoteNotFound(note_id)
            return dict(self._notes[note_id])

    def create(self, title: str, body: str) -> dict[str, Any]:
        now = datetime.now(UTC).isoformat()
        with self._lock:
            note = {
                "id": self._next_id,
                "title": title,
                "body": body,
                "created_at": now,
                "updated_at": now,
            }
            self._notes[self._next_id] = note
            self._next_id += 1
        return dict(note)

    def delete(self, note_id: int) -> None:
        with self._lock:
            if self._notes.pop(note_id, None) is None:
                raise NoteNotFound(note_id)

    def count(self) -> int:
        with self._lock:
            return len(self._notes)


def make_store(settings) -> PostgresNotesStore | MemoryNotesStore:
    if settings.notes_store == "memory":
        return MemoryNotesStore()
    return PostgresNotesStore(settings.database_url, sslmode=settings.db_sslmode)
