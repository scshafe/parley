"""The relay's record: conversations, turns and their events, in SQLite (WAL);
each turn's audio and timings as files beside it."""

from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
import sqlite3
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    title TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS turns (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    seq INTEGER NOT NULL,
    client_turn_id TEXT NOT NULL,
    user_text TEXT NOT NULL,
    state TEXT NOT NULL,
    reply_raw TEXT,
    reply_text TEXT,
    attachment TEXT,
    cleanup_json TEXT,
    style_version TEXT,
    jobs_json TEXT,
    segments_json TEXT,
    audio_duration_ms INTEGER,
    timings_exact INTEGER,
    error_code TEXT,
    error_detail TEXT,
    pushed INTEGER NOT NULL DEFAULT 0,
    audio_deleted INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    ready_at TEXT,
    UNIQUE (conversation_id, client_turn_id),
    UNIQUE (conversation_id, seq)
);
CREATE TABLE IF NOT EXISTS speech_jobs (
    job_id TEXT PRIMARY KEY,
    turn_id TEXT NOT NULL REFERENCES turns(id),
    job_index INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    type TEXT NOT NULL,
    data_json TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    token TEXT NOT NULL UNIQUE,
    environment TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_push_at TEXT,
    last_push_status INTEGER
);
CREATE INDEX IF NOT EXISTS events_by_conversation ON events (conversation_id, id);
CREATE INDEX IF NOT EXISTS turns_by_state ON turns (state);
"""

log = logging.getLogger("parley.store")

DB_NAME = "relay.sqlite3"
SNAPSHOT_DIR = "backup"  # data_dir/backup/relay.sqlite3: the copy a backup restores from

ACTIVE_STATES = ("thinking", "speaking")
TERMINAL_STATES = ("ready", "failed")


def now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def new_id(prefix: str) -> str:
    return f"{prefix}_{secrets.token_hex(8)}"


class ConflictError(Exception):
    pass


class Store:
    def __init__(self, data_dir: Path) -> None:
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        (self.data_dir / "turns").mkdir(exist_ok=True)
        db_path = self.data_dir / DB_NAME
        snapshot = self.snapshot_path
        if not db_path.exists() and snapshot.exists():
            # A restore: the backup's live database files were removed, so the
            # relay starts from its last consistent snapshot.
            shutil.copyfile(snapshot, db_path)
            log.warning("the database was missing: restored it from %s/%s", SNAPSHOT_DIR, DB_NAME)
        self._db = sqlite3.connect(db_path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.execute("PRAGMA busy_timeout=5000")
        self._db.executescript(SCHEMA)
        columns = {r["name"] for r in self._db.execute("PRAGMA table_info(turns)")}
        if "segments_json" not in columns:  # a database made before the streamed segments
            self._db.execute("ALTER TABLE turns ADD COLUMN segments_json TEXT")
        self._lock = threading.RLock()

    def close(self) -> None:
        self._db.close()

    # --- snapshots ------------------------------------------------------------------------
    # The live database is in WAL mode, so a byte copy of it (the stack's
    # backup tars state/data) can be torn. The relay keeps a consistent copy
    # beside it, made with SQLite's online backup API; a restore uses that copy
    # (docs/DESIGN.md, "P2 build decisions: the relay").

    @property
    def snapshot_path(self) -> Path:
        return self.data_dir / SNAPSHOT_DIR / DB_NAME

    def changes(self) -> int:
        """A counter that moves whenever this connection writes."""
        with self._lock:
            return self._db.total_changes

    def snapshot(self) -> Path:
        """Write a consistent copy of the database to ``backup/relay.sqlite3``,
        atomically (a reader sees the old copy or the new one, never half)."""
        folder = self.snapshot_path.parent
        folder.mkdir(exist_ok=True)
        tmp = folder / f".{DB_NAME}.tmp"
        tmp.unlink(missing_ok=True)
        dest = sqlite3.connect(tmp)
        try:
            with self._lock:
                self._db.backup(dest)
            dest.execute("PRAGMA journal_mode=DELETE")  # one self-contained file
        finally:
            dest.close()
        with open(tmp, "rb") as fh:
            os.fsync(fh.fileno())
        os.replace(tmp, self.snapshot_path)
        return self.snapshot_path

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield self._db
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")

    # --- files ---------------------------------------------------------------------------

    def turn_dir(self, turn_id: str) -> Path:
        return self.data_dir / "turns" / turn_id

    # --- conversations ----------------------------------------------------------------------

    def create_conversation(self, title: str | None) -> dict:
        cid, ts = new_id("c"), now_iso()
        with self._tx() as db:
            db.execute("INSERT INTO conversations VALUES (?, ?, ?, ?)", (cid, title, ts, ts))
        return self.get_conversation(cid)  # type: ignore[return-value]

    def get_conversation(self, cid: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM conversations WHERE id = ?", (cid,)).fetchone()
            if row is None:
                return None
            conv = dict(row)
            stats = self._db.execute(
                "SELECT COUNT(*) AS n FROM turns WHERE conversation_id = ?", (cid,)
            ).fetchone()
            last = self._db.execute(
                "SELECT * FROM turns WHERE conversation_id = ? ORDER BY seq DESC LIMIT 1", (cid,)
            ).fetchone()
            ev = self._db.execute(
                "SELECT COALESCE(MAX(id), 0) AS m FROM events WHERE conversation_id = ?", (cid,)
            ).fetchone()
        conv["turn_count"] = stats["n"]
        conv["last_turn"] = dict(last) if last else None
        conv["last_event_id"] = ev["m"]
        return conv

    def list_conversations(self) -> list[dict]:
        with self._lock:
            ids = [r["id"] for r in self._db.execute("SELECT id FROM conversations ORDER BY updated_at DESC, id")]
        return [c for c in (self.get_conversation(i) for i in ids) if c]

    def search_conversations(self, query: str) -> list[tuple[dict, str]]:
        """Conversations whose title or any turn's text contains ``query``
        (case-insensitive), newest first, each with the first matching text."""
        needle = query.casefold()
        found = []
        for conv in self.list_conversations():
            texts = [conv["title"] or ""]
            for turn in self.turns_of(conv["id"]):
                texts += [turn["user_text"], turn["reply_text"] or ""]
            hit = next((t for t in texts if needle in t.casefold()), None)
            if hit is not None:
                found.append((conv, hit))
        return found

    # --- turns ------------------------------------------------------------------------------

    def add_turn(self, cid: str, client_turn_id: str, text: str) -> tuple[dict, bool]:
        """Add a user turn; a retry with the same ``client_turn_id`` and text
        answers the existing turn (``created`` is False)."""
        with self._tx() as db:
            row = db.execute(
                "SELECT * FROM turns WHERE conversation_id = ? AND client_turn_id = ?", (cid, client_turn_id)
            ).fetchone()
            if row is not None:
                if row["user_text"] != text:
                    raise ConflictError("client_turn_id reused with a different text")
                return dict(row), False
            seq = db.execute(
                "SELECT COALESCE(MAX(seq), 0) + 1 AS s FROM turns WHERE conversation_id = ?", (cid,)
            ).fetchone()["s"]
            tid, ts = new_id("t"), now_iso()
            db.execute(
                "INSERT INTO turns (id, conversation_id, seq, client_turn_id, user_text, state, created_at, updated_at)"
                " VALUES (?, ?, ?, ?, ?, 'thinking', ?, ?)",
                (tid, cid, seq, client_turn_id, text, ts, ts),
            )
            db.execute(
                "UPDATE conversations SET updated_at = ?, title = COALESCE(title, ?) WHERE id = ?",
                (ts, _title_from(text), cid),
            )
            row = db.execute("SELECT * FROM turns WHERE id = ?", (tid,)).fetchone()
        return dict(row), True

    def get_turn(self, tid: str) -> dict | None:
        with self._lock:
            row = self._db.execute("SELECT * FROM turns WHERE id = ?", (tid,)).fetchone()
        return dict(row) if row else None

    def turns_of(self, cid: str) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM turns WHERE conversation_id = ? ORDER BY seq", (cid,)).fetchall()
        return [dict(r) for r in rows]

    def update_turn(self, tid: str, **fields: Any) -> dict:
        fields["updated_at"] = now_iso()
        cols = ", ".join(f"{k} = ?" for k in fields)
        with self._tx() as db:
            db.execute(f"UPDATE turns SET {cols} WHERE id = ?", (*fields.values(), tid))  # noqa: S608 - fixed column names
            row = db.execute("SELECT * FROM turns WHERE id = ?", (tid,)).fetchone()
            db.execute("UPDATE conversations SET updated_at = ? WHERE id = ?", (fields["updated_at"], row["conversation_id"]))
        return dict(row)

    def unfinished_turns(self) -> list[dict]:
        """Turns a restart must resume: still working, or ready but not yet pushed."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM turns WHERE state IN ('thinking', 'speaking') OR (state = 'ready' AND pushed = 0)"
                " ORDER BY created_at, seq"
            ).fetchall()
        return [dict(r) for r in rows]

    def record_job(self, job_id: str, tid: str, index: int) -> None:
        with self._tx() as db:
            db.execute("INSERT OR IGNORE INTO speech_jobs VALUES (?, ?, ?)", (job_id, tid, index))

    def turn_for_job(self, job_id: str) -> str | None:
        with self._lock:
            row = self._db.execute("SELECT turn_id FROM speech_jobs WHERE job_id = ?", (job_id,)).fetchone()
        return row["turn_id"] if row else None

    def expired_audio(self, days: int) -> list[dict]:
        cutoff = (datetime.now(UTC) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM turns WHERE state = 'ready' AND audio_deleted = 0 AND ready_at < ?", (cutoff,)
            ).fetchall()
        return [dict(r) for r in rows]

    # --- devices (APNs) -----------------------------------------------------------------------
    # A device token is a credential for pushing to that phone: it is stored, sent
    # to Apple, and never logged or returned by the API.

    def register_device(self, token: str, environment: str) -> tuple[dict, bool]:
        """Add a device, or update the environment of the one with this token
        (``created`` is False)."""
        ts = now_iso()
        with self._tx() as db:
            row = db.execute("SELECT * FROM devices WHERE token = ?", (token,)).fetchone()
            if row is not None:
                db.execute("UPDATE devices SET environment = ?, updated_at = ? WHERE id = ?", (environment, ts, row["id"]))
                did, created = row["id"], False
            else:
                did, created = new_id("d"), True
                db.execute("INSERT INTO devices (id, token, environment, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                           (did, token, environment, ts, ts))
            row = db.execute("SELECT * FROM devices WHERE id = ?", (did,)).fetchone()
        return dict(row), created

    def devices(self) -> list[dict]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM devices ORDER BY created_at, id").fetchall()
        return [dict(r) for r in rows]

    def delete_device(self, did: str) -> bool:
        with self._tx() as db:
            return db.execute("DELETE FROM devices WHERE id = ?", (did,)).rowcount > 0

    def record_push(self, did: str, status: int) -> None:
        with self._tx() as db:
            db.execute("UPDATE devices SET last_push_at = ?, last_push_status = ? WHERE id = ?", (now_iso(), status, did))

    # --- events -----------------------------------------------------------------------------

    def add_event(self, cid: str, type_: str, data: dict) -> int:
        with self._tx() as db:
            cur = db.execute(
                "INSERT INTO events (conversation_id, type, data_json, created_at) VALUES (?, ?, ?, ?)",
                (cid, type_, json.dumps(data, separators=(",", ":")), now_iso()),
            )
            return int(cur.lastrowid or 0)

    def events_after(self, cid: str, after: int, limit: int = 200) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE conversation_id = ? AND id > ? ORDER BY id LIMIT ?", (cid, after, limit)
            ).fetchall()
        return [dict(r) for r in rows]


def _title_from(text: str) -> str:
    line = " ".join(text.split())
    return line if len(line) <= 60 else line[:57].rstrip() + "…"
