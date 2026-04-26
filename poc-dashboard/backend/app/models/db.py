import aiosqlite
from typing import Optional

_db_path: str = "./poc_dashboard.db"
_db: Optional[aiosqlite.Connection] = None

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS operation_logs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    action      TEXT NOT NULL,
    target      TEXT,
    params      TEXT,
    tx_hash     TEXT,
    status      TEXT NOT NULL,
    error       TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_logs_action ON operation_logs(action);
CREATE INDEX IF NOT EXISTS idx_logs_created ON operation_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_logs_target ON operation_logs(target);

CREATE TABLE IF NOT EXISTS watch_addresses (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    kind        TEXT NOT NULL,
    address     TEXT NOT NULL,
    label       TEXT,
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(kind, address)
);

CREATE INDEX IF NOT EXISTS idx_watch_kind_enabled ON watch_addresses(kind, enabled);

CREATE TABLE IF NOT EXISTS event_cursors (
    event_key   TEXT PRIMARY KEY,
    last_version TEXT NOT NULL,
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS managed_keys (
    address     TEXT PRIMARY KEY,
    private_key TEXT NOT NULL,
    label       TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


async def init_db(db_path: str = "./poc_dashboard.db"):
    global _db_path, _db
    _db_path = db_path
    _db = await aiosqlite.connect(_db_path)
    _db.row_factory = aiosqlite.Row
    await _db.executescript(SCHEMA_SQL)
    await _db.commit()


async def get_db() -> aiosqlite.Connection:
    global _db
    if _db is None:
        await init_db(_db_path)
    return _db


async def close_db():
    global _db
    if _db:
        await _db.close()
        _db = None
