from typing import Any

from app.models.db import get_db


def _row_to_dict(row) -> dict:
    return dict(row)


async def insert_chain_snapshot(snapshot: dict[str, Any]) -> None:
    db = await get_db()
    await db.execute(
        """
        INSERT INTO chain_snapshots (
            sampled_at, chain_id, epoch, ledger_version, block_height, ledger_timestamp,
            current_period, power_period_in_epochs, retention_bps,
            reward_rate_numerator, reward_rate_denominator, reward_rate_bps,
            active_validator_count, pending_active_validator_count, pending_inactive_validator_count,
            total_staked_power, octas_per_power, cooldown_secs, voting_duration_secs
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            snapshot["sampled_at"],
            snapshot.get("chain_id", 0),
            snapshot.get("epoch", 0),
            snapshot.get("ledger_version", 0),
            snapshot.get("block_height", 0),
            snapshot.get("ledger_timestamp", ""),
            snapshot.get("current_period", 0),
            snapshot.get("power_period_in_epochs", 0),
            snapshot.get("retention_bps", 0),
            snapshot.get("reward_rate_numerator", 0),
            snapshot.get("reward_rate_denominator", 0),
            snapshot.get("reward_rate_bps", 0),
            snapshot.get("active_validator_count", 0),
            snapshot.get("pending_active_validator_count", 0),
            snapshot.get("pending_inactive_validator_count", 0),
            snapshot.get("total_staked_power", 0),
            snapshot.get("octas_per_power", 0),
            snapshot.get("cooldown_secs", 0),
            snapshot.get("voting_duration_secs", 0),
        ),
    )
    await db.commit()


async def insert_validator_snapshots(rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    db = await get_db()
    await db.executemany(
        """
        INSERT INTO validator_snapshots (
            sampled_at, epoch, address, label, status, status_code, in_watchlist,
            voting_power, commission_bps, delegator_count, total_pool_power,
            stake_active_octas, stake_inactive_octas, stake_pending_active_octas,
            stake_pending_inactive_octas, proposals_successful, proposals_failed,
            estimated_epoch_reward_octas, estimated_epoch_fee_octas,
            estimated_epoch_total_octas, estimated_commission_octas
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                row["sampled_at"],
                row.get("epoch", 0),
                row["address"],
                row.get("label", ""),
                row.get("status", "unknown"),
                row.get("status_code", 0),
                1 if row.get("in_watchlist") else 0,
                row.get("voting_power", 0),
                row.get("commission_bps", 0),
                row.get("delegator_count", 0),
                row.get("total_pool_power", 0),
                row.get("stake_active_octas", 0),
                row.get("stake_inactive_octas", 0),
                row.get("stake_pending_active_octas", 0),
                row.get("stake_pending_inactive_octas", 0),
                row.get("proposals_successful", 0),
                row.get("proposals_failed", 0),
                row.get("estimated_epoch_reward_octas", 0),
                row.get("estimated_epoch_fee_octas", 0),
                row.get("estimated_epoch_total_octas", 0),
                row.get("estimated_commission_octas", 0),
            )
            for row in rows
        ],
    )
    await db.commit()


async def insert_user_snapshots(rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    db = await get_db()
    await db.executemany(
        """
        INSERT INTO user_snapshots (
            sampled_at, epoch, address, label, balance_octas, committed_power,
            effective_power, power_for_next_epoch, deposit_octas, delegated_to,
            cooldown_until_secs, is_in_cooldown, estimated_epoch_reward_octas,
            estimated_epoch_fee_octas, estimated_epoch_total_octas,
            estimated_owner_commission_octas
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                row["sampled_at"],
                row.get("epoch", 0),
                row["address"],
                row.get("label", ""),
                row.get("balance_octas", 0),
                row.get("committed_power", 0),
                row.get("effective_power", 0),
                row.get("power_for_next_epoch", 0),
                row.get("deposit_octas", 0),
                row.get("delegated_to", "0x0"),
                row.get("cooldown_until_secs", 0),
                1 if row.get("is_in_cooldown") else 0,
                row.get("estimated_epoch_reward_octas", 0),
                row.get("estimated_epoch_fee_octas", 0),
                row.get("estimated_epoch_total_octas", 0),
                row.get("estimated_owner_commission_octas", 0),
            )
            for row in rows
        ],
    )
    await db.commit()


async def upsert_reward_epoch_estimates(kind: str, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    db = await get_db()
    await db.executemany(
        """
        INSERT INTO reward_epoch_estimates (
            kind, address, epoch, sampled_at, reward_octas, fee_octas,
            total_estimated_reward_octas, owner_commission_octas
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind, address, epoch) DO UPDATE SET
            sampled_at = excluded.sampled_at,
            reward_octas = excluded.reward_octas,
            fee_octas = excluded.fee_octas,
            total_estimated_reward_octas = excluded.total_estimated_reward_octas,
            owner_commission_octas = excluded.owner_commission_octas
        """,
        [
            (
                kind,
                row["address"],
                row.get("epoch", 0),
                row["sampled_at"],
                row.get("reward_octas", 0),
                row.get("fee_octas", 0),
                row.get("total_estimated_reward_octas", 0),
                row.get("owner_commission_octas", 0),
            )
            for row in rows
        ],
    )
    await db.commit()


async def get_chain_history(limit: int = 200) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT * FROM chain_snapshots
        ORDER BY sampled_at DESC, id DESC
        LIMIT ?
        """,
        (limit,),
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def get_validator_history(address: str, limit: int = 200) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT * FROM validator_snapshots
        WHERE lower(address) = lower(?)
        ORDER BY sampled_at DESC, id DESC
        LIMIT ?
        """,
        (address, limit),
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def get_user_history(address: str, limit: int = 200) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT * FROM user_snapshots
        WHERE lower(address) = lower(?)
        ORDER BY sampled_at DESC, id DESC
        LIMIT ?
        """,
        (address, limit),
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def get_cumulative_reward(kind: str, address: str) -> dict:
    db = await get_db()
    cursor = await db.execute(
        """
        SELECT
            COALESCE(SUM(reward_octas), 0) AS reward_octas,
            COALESCE(SUM(fee_octas), 0) AS fee_octas,
            COALESCE(SUM(total_estimated_reward_octas), 0) AS total_estimated_reward_octas,
            COALESCE(SUM(owner_commission_octas), 0) AS owner_commission_octas,
            COUNT(*) AS epochs
        FROM reward_epoch_estimates
        WHERE kind = ? AND lower(address) = lower(?)
        """,
        (kind, address),
    )
    row = await cursor.fetchone()
    return _row_to_dict(row)


async def get_recent_reward_estimates(kind: str, address: str, limit: int = 50) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT * FROM reward_epoch_estimates
        WHERE kind = ? AND lower(address) = lower(?)
        ORDER BY epoch DESC
        LIMIT ?
        """,
        (kind, address, limit),
    )
    return [_row_to_dict(row) for row in reversed(rows)]
