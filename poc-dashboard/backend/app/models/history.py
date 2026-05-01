from typing import Any

from app.models.db import get_db
from app.utils.address import address_variants


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


async def upsert_user_power_period_history(rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    db = await get_db()
    await db.executemany(
        """
        INSERT INTO user_power_period_history (
            sampled_at, epoch, address, label, period, raw_power, source_slot,
            observed_current_period, observed_next_epoch_period, observed_committed_power
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(address, period) DO UPDATE SET
            sampled_at = excluded.sampled_at,
            epoch = excluded.epoch,
            label = excluded.label,
            raw_power = excluded.raw_power,
            source_slot = excluded.source_slot,
            observed_current_period = excluded.observed_current_period,
            observed_next_epoch_period = excluded.observed_next_epoch_period,
            observed_committed_power = excluded.observed_committed_power,
            updated_at = datetime('now')
        """,
        [
            (
                row["sampled_at"],
                row.get("epoch", 0),
                row["address"],
                row.get("label", ""),
                row.get("period", 0),
                row.get("raw_power", 0),
                row.get("source_slot", ""),
                row.get("observed_current_period", 0),
                row.get("observed_next_epoch_period", 0),
                row.get("observed_committed_power", 0),
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


async def upsert_consensus_validator_epoch_snapshot(
    sampled_at: str,
    epoch: int,
    source_url: str,
    rows: list[dict[str, Any]],
    total_voting_power: int = 0,
    validator_count: int = 0,
) -> None:
    if not rows:
        return
    normalized_total = int(total_voting_power or 0)
    normalized_count = int(validator_count or 0) or len(rows)
    db = await get_db()
    await db.executemany(
        """
        INSERT INTO consensus_validator_epoch_snapshots (
            sampled_at, epoch, source_url, peer_id, voting_power,
            total_voting_power, validator_count
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(epoch, peer_id) DO UPDATE SET
            sampled_at = excluded.sampled_at,
            source_url = excluded.source_url,
            voting_power = excluded.voting_power,
            total_voting_power = excluded.total_voting_power,
            validator_count = excluded.validator_count
        """,
        [
            (
                sampled_at,
                epoch,
                source_url,
                row["peer_id"],
                int(row.get("voting_power", 0) or 0),
                normalized_total,
                normalized_count,
            )
            for row in rows
        ],
    )
    await db.commit()


async def count_chain_history() -> int:
    db = await get_db()
    cursor = await db.execute("SELECT COUNT(*) AS total FROM chain_snapshots")
    row = await cursor.fetchone()
    return int(row["total"] or 0)


async def get_chain_history(limit: int = 200, offset: int = 0) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT * FROM chain_snapshots
        ORDER BY sampled_at DESC, id DESC
        LIMIT ? OFFSET ?
        """,
        (limit, offset),
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def count_validator_history(address: str) -> int:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    cursor = await db.execute(
        f"""
        SELECT COUNT(*) AS total FROM validator_snapshots
        WHERE lower(address) IN ({placeholders})
        """,
        variants,
    )
    row = await cursor.fetchone()
    return int(row["total"] or 0)


async def get_validator_history(address: str, limit: int = 200, offset: int = 0) -> list[dict]:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    rows = await db.execute_fetchall(
        f"""
        SELECT * FROM validator_snapshots
        WHERE lower(address) IN ({placeholders})
        ORDER BY sampled_at DESC, id DESC
        LIMIT ? OFFSET ?
        """,
        [*variants, limit, offset],
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def count_user_history(address: str) -> int:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    cursor = await db.execute(
        f"""
        SELECT COUNT(*) AS total FROM user_snapshots
        WHERE lower(address) IN ({placeholders})
        """,
        variants,
    )
    row = await cursor.fetchone()
    return int(row["total"] or 0)


async def get_user_history(address: str, limit: int = 200, offset: int = 0) -> list[dict]:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    rows = await db.execute_fetchall(
        f"""
        SELECT
            user_snapshots.*,
            (
                SELECT chain_snapshots.current_period
                FROM chain_snapshots
                WHERE chain_snapshots.sampled_at <= user_snapshots.sampled_at
                ORDER BY chain_snapshots.sampled_at DESC, chain_snapshots.id DESC
                LIMIT 1
            ) AS current_period,
            (
                SELECT chain_snapshots.power_period_in_epochs
                FROM chain_snapshots
                WHERE chain_snapshots.sampled_at <= user_snapshots.sampled_at
                ORDER BY chain_snapshots.sampled_at DESC, chain_snapshots.id DESC
                LIMIT 1
            ) AS power_period_in_epochs
        FROM user_snapshots
        WHERE lower(user_snapshots.address) IN ({placeholders})
        ORDER BY user_snapshots.sampled_at DESC, user_snapshots.id DESC
        LIMIT ? OFFSET ?
        """,
        [*variants, limit, offset],
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def count_user_power_period_history(address: str) -> int:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    cursor = await db.execute(
        f"""
        SELECT COUNT(*) AS total FROM user_power_period_history
        WHERE lower(address) IN ({placeholders})
        """,
        variants,
    )
    row = await cursor.fetchone()
    return int(row["total"] or 0)


async def get_user_power_period_history(address: str, limit: int = 200, offset: int = 0) -> list[dict]:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    rows = await db.execute_fetchall(
        f"""
        SELECT * FROM user_power_period_history
        WHERE lower(address) IN ({placeholders})
        ORDER BY period DESC
        LIMIT ? OFFSET ?
        """,
        [*variants, limit, offset],
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def get_cumulative_reward(kind: str, address: str) -> dict:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    cursor = await db.execute(
        f"""
        SELECT
            COALESCE(SUM(reward_octas), 0) AS reward_octas,
            COALESCE(SUM(fee_octas), 0) AS fee_octas,
            COALESCE(SUM(total_estimated_reward_octas), 0) AS total_estimated_reward_octas,
            COALESCE(SUM(owner_commission_octas), 0) AS owner_commission_octas,
            COUNT(*) AS epochs
        FROM reward_epoch_estimates
        WHERE kind = ? AND lower(address) IN ({placeholders})
        """,
        [kind, *variants],
    )
    row = await cursor.fetchone()
    return _row_to_dict(row)


async def get_recent_reward_estimates(kind: str, address: str, limit: int = 50) -> list[dict]:
    db = await get_db()
    variants = address_variants(address)
    placeholders = ",".join("lower(?)" for _ in variants)
    rows = await db.execute_fetchall(
        f"""
        SELECT * FROM reward_epoch_estimates
        WHERE kind = ? AND lower(address) IN ({placeholders})
        ORDER BY epoch DESC
        LIMIT ?
        """,
        [kind, *variants, limit],
    )
    return [_row_to_dict(row) for row in reversed(rows)]


async def count_consensus_validator_power_epochs() -> int:
    db = await get_db()
    cursor = await db.execute(
        """
        SELECT COUNT(*) AS total
        FROM (
            SELECT epoch FROM consensus_validator_epoch_snapshots
            GROUP BY epoch
        )
        """
    )
    row = await cursor.fetchone()
    return int(row["total"] or 0)


async def get_consensus_validator_power_epochs(
    limit: int = 50,
    offset: int = 0,
    include_validators: bool = False,
) -> list[dict]:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT
            epoch,
            MAX(sampled_at) AS sampled_at,
            MAX(source_url) AS source_url,
            MAX(total_voting_power) AS total_voting_power,
            MAX(validator_count) AS validator_count,
            COUNT(*) AS captured_validator_count
        FROM consensus_validator_epoch_snapshots
        GROUP BY epoch
        ORDER BY epoch DESC
        LIMIT ? OFFSET ?
        """,
        (limit, offset),
    )
    summaries = [_row_to_dict(row) for row in reversed(rows)]
    if not include_validators or not summaries:
        return summaries

    epochs = [int(row["epoch"]) for row in summaries]
    placeholders = ",".join("?" for _ in epochs)
    validator_rows = await db.execute_fetchall(
        f"""
        SELECT epoch, peer_id, voting_power
        FROM consensus_validator_epoch_snapshots
        WHERE epoch IN ({placeholders})
        ORDER BY epoch ASC, voting_power DESC, lower(peer_id) ASC
        """,
        epochs,
    )
    by_epoch: dict[int, list[dict]] = {epoch: [] for epoch in epochs}
    totals = {int(row["epoch"]): int(row.get("total_voting_power") or 0) for row in summaries}
    for row in validator_rows:
        item = _row_to_dict(row)
        epoch = int(item.pop("epoch"))
        voting_power = int(item.get("voting_power") or 0)
        total = totals.get(epoch, 0)
        item["share_bps"] = int(round((voting_power / total) * 10000)) if total > 0 else 0
        by_epoch.setdefault(epoch, []).append(item)
    for row in summaries:
        row["validators"] = by_epoch.get(int(row["epoch"]), [])
    return summaries


async def get_consensus_validator_power_epochs_between(
    start_epoch: int,
    end_epoch: int,
    include_validators: bool = False,
) -> list[dict]:
    if start_epoch <= 0 or end_epoch <= 0:
        return []
    low = min(start_epoch, end_epoch)
    high = max(start_epoch, end_epoch)
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT
            epoch,
            MAX(sampled_at) AS sampled_at,
            MAX(source_url) AS source_url,
            MAX(total_voting_power) AS total_voting_power,
            MAX(validator_count) AS validator_count,
            COUNT(*) AS captured_validator_count
        FROM consensus_validator_epoch_snapshots
        WHERE epoch BETWEEN ? AND ?
        GROUP BY epoch
        ORDER BY epoch ASC
        """,
        (low, high),
    )
    summaries = [_row_to_dict(row) for row in rows]
    if not include_validators or not summaries:
        return summaries

    epochs = [int(row["epoch"]) for row in summaries]
    placeholders = ",".join("?" for _ in epochs)
    validator_rows = await db.execute_fetchall(
        f"""
        SELECT epoch, peer_id, voting_power
        FROM consensus_validator_epoch_snapshots
        WHERE epoch IN ({placeholders})
        ORDER BY epoch ASC, voting_power DESC, lower(peer_id) ASC
        """,
        epochs,
    )
    by_epoch: dict[int, list[dict]] = {epoch: [] for epoch in epochs}
    totals = {int(row["epoch"]): int(row.get("total_voting_power") or 0) for row in summaries}
    for row in validator_rows:
        item = _row_to_dict(row)
        epoch = int(item.pop("epoch"))
        voting_power = int(item.get("voting_power") or 0)
        total = totals.get(epoch, 0)
        item["share_bps"] = int(round((voting_power / total) * 10000)) if total > 0 else 0
        by_epoch.setdefault(epoch, []).append(item)
    for row in summaries:
        row["validators"] = by_epoch.get(int(row["epoch"]), [])
    return summaries


async def get_consensus_validator_power_epoch(epoch: int) -> dict:
    db = await get_db()
    summary_cursor = await db.execute(
        """
        SELECT
            epoch,
            MAX(sampled_at) AS sampled_at,
            MAX(source_url) AS source_url,
            MAX(total_voting_power) AS total_voting_power,
            MAX(validator_count) AS validator_count,
            COUNT(*) AS captured_validator_count
        FROM consensus_validator_epoch_snapshots
        WHERE epoch = ?
        GROUP BY epoch
        """,
        (epoch,),
    )
    summary_row = await summary_cursor.fetchone()
    rows = await db.execute_fetchall(
        """
        SELECT peer_id, voting_power
        FROM consensus_validator_epoch_snapshots
        WHERE epoch = ?
        ORDER BY voting_power DESC, lower(peer_id) ASC
        """,
        (epoch,),
    )
    summary = _row_to_dict(summary_row) if summary_row else {
        "epoch": epoch,
        "sampled_at": "",
        "source_url": "",
        "total_voting_power": 0,
        "validator_count": 0,
        "captured_validator_count": 0,
    }
    total = int(summary.get("total_voting_power") or 0)
    validators = []
    for row in rows:
        item = _row_to_dict(row)
        voting_power = int(item.get("voting_power") or 0)
        item["share_bps"] = int(round((voting_power / total) * 10000)) if total > 0 else 0
        validators.append(item)
    return {**summary, "validators": validators}
