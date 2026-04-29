from app.models.db import get_db


async def get_addresses(kind: str, enabled: bool = True) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        "SELECT id, kind, address, label, enabled, created_at, updated_at FROM watch_addresses WHERE kind = ? AND enabled = ?",
        (kind, 1 if enabled else 0),
    )
    return [{"id": r[0], "kind": r[1], "address": r[2], "label": r[3],
             "enabled": bool(r[4]), "created_at": r[5], "updated_at": r[6]} for r in rows]


async def get_all_addresses(kind: str | None = None) -> list[dict]:
    db = await get_db()
    if kind:
        rows = await db.execute_fetchall(
            "SELECT id, kind, address, label, enabled, created_at, updated_at FROM watch_addresses WHERE kind = ?",
            (kind,),
        )
    else:
        rows = await db.execute_fetchall(
            "SELECT id, kind, address, label, enabled, created_at, updated_at FROM watch_addresses"
        )
    return [{"id": r[0], "kind": r[1], "address": r[2], "label": r[3],
             "enabled": bool(r[4]), "created_at": r[5], "updated_at": r[6]} for r in rows]


async def add_address(kind: str, address: str, label: str | None = None) -> int:
    db = await get_db()
    cursor = await db.execute(
        "INSERT OR REPLACE INTO watch_addresses (kind, address, label, updated_at) VALUES (?, ?, ?, datetime('now'))",
        (kind, address, label),
    )
    await db.commit()
    return cursor.lastrowid


async def remove_address(kind: str, address: str):
    db = await get_db()
    await db.execute("DELETE FROM watch_addresses WHERE kind = ? AND address = ?", (kind, address))
    await db.commit()


async def update_label(kind: str, address: str, label: str):
    db = await get_db()
    await db.execute(
        "UPDATE watch_addresses SET label = ?, updated_at = datetime('now') WHERE kind = ? AND address = ?",
        (label, kind, address),
    )
    await db.commit()


async def upsert_label(kind: str, address: str, label: str) -> int:
    db = await get_db()
    cursor = await db.execute(
        """
        INSERT INTO watch_addresses (kind, address, label, updated_at)
        VALUES (?, ?, ?, datetime('now'))
        ON CONFLICT(kind, address) DO UPDATE SET
            label = excluded.label,
            enabled = 1,
            updated_at = datetime('now')
        """,
        (kind, address, label),
    )
    await db.commit()
    return cursor.lastrowid
