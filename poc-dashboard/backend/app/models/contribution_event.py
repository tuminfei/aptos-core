import json
from typing import Any

from app.models.db import get_db
from app.utils.address import address_variants


def _row_to_dict(row) -> dict:
    return dict(row)


async def insert_events(events: list[dict[str, Any]]) -> int:
    if not events:
        return 0
    db = await get_db()
    await db.executemany(
        """
        INSERT OR IGNORE INTO contribution_events (
            tx_hash, event_index, version, app_admin, app_address, contributor,
            equity_token, equity_amount, event_type, raw_event
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                event["tx_hash"],
                event.get("event_index", 0),
                event.get("version", 0),
                event.get("app_admin"),
                event.get("app_address", ""),
                event.get("contributor", ""),
                event.get("equity_token", ""),
                event.get("equity_amount", 0),
                event.get("event_type", ""),
                json.dumps(event.get("raw_event") or {}, ensure_ascii=False),
            )
            for event in events
        ],
    )
    await db.commit()
    return db.total_changes


async def count_events(*, contributor: str | None = None, app_admin: str | None = None) -> int:
    db = await get_db()
    conditions = []
    params: list[Any] = []
    if contributor:
        variants = address_variants(contributor)
        conditions.append(f"lower(contributor) IN ({','.join('lower(?)' for _ in variants)})")
        params.extend(variants)
    if app_admin:
        variants = address_variants(app_admin)
        conditions.append(f"lower(app_admin) IN ({','.join('lower(?)' for _ in variants)})")
        params.extend(variants)
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    cursor = await db.execute(f"SELECT COUNT(*) AS total FROM contribution_events {where}", params)
    row = await cursor.fetchone()
    return int(row["total"] or 0)


async def get_events(
    *,
    contributor: str | None = None,
    app_admin: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict]:
    db = await get_db()
    conditions = []
    params: list[Any] = []
    if contributor:
        variants = address_variants(contributor)
        conditions.append(f"lower(contributor) IN ({','.join('lower(?)' for _ in variants)})")
        params.extend(variants)
    if app_admin:
        variants = address_variants(app_admin)
        conditions.append(f"lower(app_admin) IN ({','.join('lower(?)' for _ in variants)})")
        params.extend(variants)
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    rows = await db.execute_fetchall(
        f"""
        SELECT * FROM contribution_events
        {where}
        ORDER BY created_at DESC, id DESC
        LIMIT ? OFFSET ?
        """,
        params + [limit, offset],
    )
    return [_row_to_dict(row) for row in rows]


async def sum_equity_amount(*, contributor: str | None = None, app_admin: str | None = None) -> int:
    db = await get_db()
    conditions = []
    params: list[Any] = []
    if contributor:
        variants = address_variants(contributor)
        conditions.append(f"lower(contributor) IN ({','.join('lower(?)' for _ in variants)})")
        params.extend(variants)
    if app_admin:
        variants = address_variants(app_admin)
        conditions.append(f"lower(app_admin) IN ({','.join('lower(?)' for _ in variants)})")
        params.extend(variants)
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    cursor = await db.execute(f"SELECT COALESCE(SUM(equity_amount), 0) AS total FROM contribution_events {where}", params)
    row = await cursor.fetchone()
    return int(row["total"] or 0)
