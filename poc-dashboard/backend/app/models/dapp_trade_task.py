import json

from app.models.db import get_db


TASK_COLUMNS = """
    app_admin, task_id, module_address, interval_secs, tx_per_tick,
    amount_min, amount_max, max_runs, buyer_addresses, buyer_selection_mode,
    auto_create_buyers, mint_octas, max_gas, gas_unit_price, status,
    run_count, success_count, failure_count, last_tx_hash, last_error,
    created_at_epoch, created_at, updated_at
"""


async def upsert_task(task: dict) -> None:
    db = await get_db()
    await db.execute(
        """
        INSERT INTO dapp_demo_trade_tasks (
            app_admin, task_id, module_address, interval_secs, tx_per_tick,
            amount_min, amount_max, max_runs, buyer_addresses, buyer_selection_mode,
            auto_create_buyers, mint_octas, max_gas, gas_unit_price, status,
            run_count, success_count, failure_count, last_tx_hash, last_error,
            created_at_epoch, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(app_admin) DO UPDATE SET
            task_id = excluded.task_id,
            module_address = excluded.module_address,
            interval_secs = excluded.interval_secs,
            tx_per_tick = excluded.tx_per_tick,
            amount_min = excluded.amount_min,
            amount_max = excluded.amount_max,
            max_runs = excluded.max_runs,
            buyer_addresses = excluded.buyer_addresses,
            buyer_selection_mode = excluded.buyer_selection_mode,
            auto_create_buyers = excluded.auto_create_buyers,
            mint_octas = excluded.mint_octas,
            max_gas = excluded.max_gas,
            gas_unit_price = excluded.gas_unit_price,
            status = excluded.status,
            run_count = excluded.run_count,
            success_count = excluded.success_count,
            failure_count = excluded.failure_count,
            last_tx_hash = excluded.last_tx_hash,
            last_error = excluded.last_error,
            created_at_epoch = excluded.created_at_epoch,
            updated_at = datetime('now')
        """,
        _task_params(task),
    )
    await db.commit()


async def update_task_state(app_admin: str, **updates) -> None:
    if not updates:
        return

    allowed = {
        "status",
        "run_count",
        "success_count",
        "failure_count",
        "last_tx_hash",
        "last_error",
    }
    fields = [key for key in updates if key in allowed]
    if not fields:
        return

    assignments = ", ".join([f"{field} = ?" for field in fields])
    params = [updates[field] for field in fields]
    params.append(app_admin)

    db = await get_db()
    await db.execute(
        f"""
        UPDATE dapp_demo_trade_tasks
        SET {assignments}, updated_at = datetime('now')
        WHERE app_admin = ?
        """,
        params,
    )
    await db.commit()


async def get_task(app_admin: str) -> dict | None:
    db = await get_db()
    rows = await db.execute_fetchall(
        f"""
        SELECT {TASK_COLUMNS}
        FROM dapp_demo_trade_tasks
        WHERE app_admin = ?
        """,
        (app_admin,),
    )
    return _row_to_task(rows[0]) if rows else None


async def get_running_tasks() -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        f"""
        SELECT {TASK_COLUMNS}
        FROM dapp_demo_trade_tasks
        WHERE status = 'running'
        ORDER BY updated_at ASC
        """
    )
    return [_row_to_task(row) for row in rows]


def _task_params(task: dict) -> tuple:
    return (
        task.get("app_admin", ""),
        task.get("task_id", ""),
        task.get("module_address", ""),
        float(task.get("interval_secs", 0) or 0),
        int(task.get("tx_per_tick", 0) or 0),
        int(task.get("amount_min", 0) or 0),
        int(task.get("amount_max", 0) or 0),
        int(task.get("max_runs", 0) or 0),
        json.dumps(task.get("buyer_addresses") or []),
        task.get("buyer_selection_mode", "fixed"),
        int(task.get("auto_create_buyers", 0) or 0),
        int(task.get("mint_octas", 0) or 0),
        int(task.get("max_gas", 0) or 0),
        int(task.get("gas_unit_price", 0) or 0),
        task.get("status", "running"),
        int(task.get("run_count", 0) or 0),
        int(task.get("success_count", 0) or 0),
        int(task.get("failure_count", 0) or 0),
        task.get("last_tx_hash", ""),
        task.get("last_error", ""),
        float(task.get("created_at", 0) or 0),
    )


def _row_to_task(row) -> dict:
    return {
        "app_admin": row[0],
        "task_id": row[1],
        "module_address": row[2],
        "interval_secs": float(row[3] or 0),
        "tx_per_tick": int(row[4] or 0),
        "amount_min": int(row[5] or 0),
        "amount_max": int(row[6] or 0),
        "max_runs": int(row[7] or 0),
        "buyer_addresses": json.loads(row[8] or "[]"),
        "buyer_selection_mode": row[9] or "fixed",
        "auto_create_buyers": int(row[10] or 0),
        "mint_octas": int(row[11] or 0),
        "max_gas": int(row[12] or 0),
        "gas_unit_price": int(row[13] or 0),
        "status": row[14] or "running",
        "run_count": int(row[15] or 0),
        "success_count": int(row[16] or 0),
        "failure_count": int(row[17] or 0),
        "last_tx_hash": row[18] or "",
        "last_error": row[19] or "",
        "created_at": float(row[20] or 0),
        "created_at_text": row[21],
        "updated_at": row[22],
    }
