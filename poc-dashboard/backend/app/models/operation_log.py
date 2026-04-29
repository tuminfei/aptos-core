import json
from app.models.db import get_db


def _row_to_log(r) -> dict:
    return {
        "id": r[0], "action": r[1], "target": r[2],
        "params": json.loads(r[3]) if r[3] else None,
        "tx_hash": r[4], "status": r[5], "error": r[6], "created_at": r[7],
    }


async def create_log(action: str, target: str | None, params: dict | None,
                     tx_hash: str | None, status: str, error: str | None = None) -> int:
    db = await get_db()
    cursor = await db.execute(
        "INSERT INTO operation_logs (action, target, params, tx_hash, status, error) VALUES (?, ?, ?, ?, ?, ?)",
        (action, target, json.dumps(params) if params else None, tx_hash, status, error),
    )
    await db.commit()
    return cursor.lastrowid


async def get_logs(action: str | None = None, status: str | None = None,
                   page: int = 1, page_size: int = 20) -> tuple[int, list[dict]]:
    db = await get_db()
    conditions = []
    params = []
    if action:
        conditions.append("action = ?")
        params.append(action)
    if status:
        conditions.append("status = ?")
        params.append(status)

    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""

    row = await db.execute_fetchall(f"SELECT COUNT(*) as cnt FROM operation_logs {where}", params)
    total = row[0][0]

    offset = (page - 1) * page_size
    rows = await db.execute_fetchall(
        f"SELECT * FROM operation_logs {where} ORDER BY created_at DESC LIMIT ? OFFSET ?",
        params + [page_size, offset],
    )
    return total, [_row_to_log(r) for r in rows]


async def get_latest_success_for_target(action: str, target: str) -> dict | None:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT * FROM operation_logs
        WHERE action = ? AND lower(target) = lower(?) AND status = 'success'
        ORDER BY created_at DESC
        LIMIT 1
        """,
        (action, target),
    )
    return _row_to_log(rows[0]) if rows else None
