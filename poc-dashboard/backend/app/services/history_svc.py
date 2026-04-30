import asyncio
import logging
import time
from datetime import datetime, timezone

from app.chain import view
from app.chain.client import ChainClient, get_chain_client
from app.api.ws import broadcast
from app.models import history, watchlist
from app.api.watchlist import _get_user_like_watch_items
from app.services import consensus_svc
from app.services import rewards_svc
from app.utils.address import address_key


logger = logging.getLogger(__name__)
VALIDATOR_STATUS_MAP = {1: "pending_active", 2: "active", 3: "pending_inactive", 4: "inactive"}
DEFAULT_SAMPLING_INTERVAL_SECS = 60

_sampler_task: asyncio.Task | None = None
_stop_event: asyncio.Event | None = None
_last_sample_epoch: int | None = None


async def sample_once(client: ChainClient | None = None) -> dict:
    client = client or get_chain_client()
    sampled_at = datetime.now(timezone.utc).isoformat()
    ledger = await client.get_ledger_info()
    epoch = int(ledger.get("epoch", 0))

    reward_context = await rewards_svc.get_reward_context(client)
    chain_snapshot = await _build_chain_snapshot(client, ledger, sampled_at, reward_context)
    await history.insert_chain_snapshot(chain_snapshot)

    validator_rows = await _build_validator_snapshots(client, sampled_at, epoch, reward_context)
    await history.insert_validator_snapshots(validator_rows)

    user_rows = await _build_user_snapshots(client, sampled_at, epoch, reward_context)
    await history.insert_user_snapshots(user_rows)

    user_power_period_rows = await _build_user_power_period_history_rows(client, sampled_at, epoch, user_rows)
    await history.upsert_user_power_period_history(user_power_period_rows)

    consensus_result = await _sample_consensus_voting_power_safely(force=True)

    global _last_sample_epoch
    if _last_sample_epoch is None or epoch != _last_sample_epoch:
        await _record_epoch_reward_estimates(epoch, validator_rows, user_rows)
        _last_sample_epoch = epoch

    result = {
        "sampled_at": sampled_at,
        "epoch": epoch,
        "validators": len(validator_rows),
        "users": len(user_rows),
        "user_power_periods": len(user_power_period_rows),
        "consensus_voting_power": consensus_result,
    }
    await broadcast("history_sampled", result)
    return result


async def start_sampler(interval_secs: int = DEFAULT_SAMPLING_INTERVAL_SECS) -> None:
    global _sampler_task, _stop_event
    if _sampler_task and not _sampler_task.done():
        return
    _stop_event = asyncio.Event()
    _sampler_task = asyncio.create_task(_sampler_loop(max(5, interval_secs), _stop_event))


async def stop_sampler() -> None:
    global _sampler_task, _stop_event
    if not _sampler_task:
        return
    if _stop_event:
        _stop_event.set()
    try:
        await asyncio.wait_for(_sampler_task, timeout=5)
    except asyncio.TimeoutError:
        _sampler_task.cancel()
    finally:
        _sampler_task = None
        _stop_event = None


async def _sampler_loop(interval_secs: int, stop_event: asyncio.Event) -> None:
    while not stop_event.is_set():
        try:
            await sample_once()
        except Exception as exc:
            logger.warning("history sampler failed: %s", exc)

        try:
            await asyncio.wait_for(stop_event.wait(), timeout=interval_secs)
        except asyncio.TimeoutError:
            pass


async def _sample_consensus_voting_power_safely(force: bool = False) -> dict:
    try:
        return await consensus_svc.sample_consensus_epoch_voting_power(force=force)
    except Exception as exc:
        logger.warning("consensus voting power sampler failed: %s", exc)
        return {"captured": False, "reason": str(exc)}


async def _build_chain_snapshot(
    client: ChainClient,
    ledger: dict,
    sampled_at: str,
    reward_context: dict,
) -> dict:
    current_period = await _optional(view.get_current_period(client), 0)
    power_period_in_epochs = await _optional(view.get_power_period_in_epochs(client), 0)
    retention_bps = await _optional(view.get_retention_bps(client), 0)
    active_count = await _optional(view.get_active_validator_count(client), 0)
    pending_active_count = await _optional(view.get_pending_active_validator_count(client), 0)
    pending_inactive_count = await _optional(view.get_pending_inactive_validator_count(client), 0)
    total_staked_power = await _optional(view.get_total_staked_power(client), 0)
    octas_per_power = await _optional(view.get_octas_per_power(client), 0)
    cooldown_secs = await _optional(view.get_cooldown_secs(client), 0)
    voting_duration_secs = await _optional(view.get_voting_duration_secs(client), 0)
    reward_rate = reward_context.get("reward_rate") or {}

    return {
        "sampled_at": sampled_at,
        "chain_id": int(ledger.get("chain_id", 0)),
        "epoch": int(ledger.get("epoch", 0)),
        "ledger_version": int(ledger.get("ledger_version", 0)),
        "block_height": int(ledger.get("block_height", 0)),
        "ledger_timestamp": str(ledger.get("ledger_timestamp", "")),
        "current_period": current_period,
        "power_period_in_epochs": power_period_in_epochs,
        "retention_bps": retention_bps,
        "reward_rate_numerator": int(reward_rate.get("numerator", 0) or 0),
        "reward_rate_denominator": int(reward_rate.get("denominator", 0) or 0),
        "reward_rate_bps": int(reward_rate.get("bps", 0) or 0),
        "active_validator_count": active_count,
        "pending_active_validator_count": pending_active_count,
        "pending_inactive_validator_count": pending_inactive_count,
        "total_staked_power": total_staked_power,
        "octas_per_power": octas_per_power,
        "cooldown_secs": cooldown_secs,
        "voting_duration_secs": voting_duration_secs,
    }


async def _build_validator_snapshots(
    client: ChainClient,
    sampled_at: str,
    epoch: int,
    reward_context: dict,
) -> list[dict]:
    watched = await watchlist.get_addresses("validator")
    labels = {address_key(item["address"]): item.get("label", "") for item in watched}
    watched_keys = set(labels)
    addresses = {item["address"] for item in watched}

    for getter in (view.get_active_validators, view.get_pending_active_validators, view.get_pending_inactive_validators):
        for addr in await _optional(getter(client, 0, 200), []):
            addresses.add(addr)

    rows = []
    for addr in sorted(addresses):
        state = await _optional(view.get_validator_state(client, addr), 0)
        voting_power = await _optional(view.get_current_epoch_voting_power(client, addr), 0)
        stake = await _optional(
            view.get_stake(client, addr),
            {"active": 0, "inactive": 0, "pending_active": 0, "pending_inactive": 0},
        )
        validator_view = await _optional(view.get_validator_view(client, addr), {})
        commission_bps = int(validator_view.get("commission_bps", 0) or 0)
        delegator_count = int(validator_view.get("delegator_count", 0) or 0)
        total_pool_power = int(validator_view.get("total_power", 0) or 0)
        idx = await _optional(view.get_validator_index(client, addr), -1)
        proposals = await _optional(view.get_proposal_counts(client, idx), {"successful": 0, "failed": 0})
        rewards = await rewards_svc.estimate_validator_rewards(
            client,
            addr,
            idx,
            total_pool_power,
            commission_bps,
            proposals=proposals,
            context=reward_context,
        )

        key = address_key(addr)
        rows.append({
            "sampled_at": sampled_at,
            "epoch": epoch,
            "address": addr,
            "label": labels.get(key, ""),
            "status": VALIDATOR_STATUS_MAP.get(state, "unknown"),
            "status_code": state,
            "in_watchlist": key in watched_keys,
            "voting_power": voting_power,
            "commission_bps": commission_bps,
            "delegator_count": delegator_count,
            "total_pool_power": total_pool_power,
            "stake_active_octas": int(stake.get("active", 0) or 0),
            "stake_inactive_octas": int(stake.get("inactive", 0) or 0),
            "stake_pending_active_octas": int(stake.get("pending_active", 0) or 0),
            "stake_pending_inactive_octas": int(stake.get("pending_inactive", 0) or 0),
            "proposals_successful": int(proposals.get("successful", 0) or 0),
            "proposals_failed": int(proposals.get("failed", 0) or 0),
            "estimated_epoch_reward_octas": int(rewards.get("estimated_epoch_reward_octas", 0) or 0),
            "estimated_epoch_fee_octas": int(rewards.get("estimated_epoch_fee_octas", 0) or 0),
            "estimated_epoch_total_octas": int(rewards.get("estimated_epoch_total_octas", 0) or 0),
            "estimated_commission_octas": int(rewards.get("estimated_commission_octas", 0) or 0),
        })
    return rows


async def _build_user_snapshots(
    client: ChainClient,
    sampled_at: str,
    epoch: int,
    reward_context: dict,
) -> list[dict]:
    watched = await _get_user_like_watch_items(client)
    rows = []
    now_secs = int(time.time())
    for item in watched:
        addr = item["address"]
        balance = await _optional(view.get_topo_balance(client, addr), 0)
        committed = await _optional(view.get_user_committed_power(client, addr), 0)
        next_epoch = await _optional(view.get_user_power_for_next_epoch(client, addr), 0)
        effective = await _optional(view.get_effective_power(client, addr), 0)
        stake = await _optional(
            view.get_user_stake_info(client, addr),
            {"deposit": 0, "delegated_to": "0x0", "cooldown_until_secs": 0},
        )
        rewards = await rewards_svc.estimate_user_rewards(
            client,
            addr,
            stake_info=stake,
            effective_power=effective,
            context=reward_context,
        )
        cooldown_until = int(stake.get("cooldown_until_secs", 0) or 0)
        rows.append({
            "sampled_at": sampled_at,
            "epoch": epoch,
            "address": addr,
            "label": item.get("label", ""),
            "balance_octas": balance,
            "committed_power": committed,
            "effective_power": effective,
            "power_for_next_epoch": next_epoch,
            "deposit_octas": int(stake.get("deposit", 0) or 0),
            "delegated_to": stake.get("delegated_to", "0x0"),
            "cooldown_until_secs": cooldown_until,
            "is_in_cooldown": cooldown_until > now_secs,
            "estimated_epoch_reward_octas": int(rewards.get("estimated_epoch_reward_octas", 0) or 0),
            "estimated_epoch_fee_octas": int(rewards.get("estimated_epoch_fee_octas", 0) or 0),
            "estimated_epoch_total_octas": int(rewards.get("estimated_epoch_total_octas", 0) or 0),
            "estimated_owner_commission_octas": int(rewards.get("estimated_owner_commission_octas", 0) or 0),
        })
    return rows


async def _build_user_power_period_history_rows(
    client: ChainClient,
    sampled_at: str,
    epoch: int,
    user_rows: list[dict],
) -> list[dict]:
    if not user_rows:
        return []

    addresses = [row["address"] for row in user_rows]
    labels = {address_key(row["address"]): row.get("label", "") for row in user_rows}
    current_period = await _optional(view.get_current_period(client), 0)
    power_period_in_epochs = await _optional(view.get_power_period_in_epochs(client), 0)
    next_epoch_period = _period_for_epoch(epoch + 1, power_period_in_epochs)
    versions = await _optional(view.get_user_power_versions(client, addresses), [])
    committed = await _optional(view.get_user_committed_powers(client, addresses), [0] * len(addresses))
    committed_by_address = {
        address_key(address): int(committed[index] if index < len(committed) else 0)
        for index, address in enumerate(addresses)
    }

    rows: list[dict] = []
    seen: set[tuple[str, int]] = set()
    for version in versions:
        address = version.get("user", "")
        if not address:
            continue
        key = address_key(address)
        for slot in ("older", "newer"):
            period = int(version.get(f"{slot}_period", 0) or 0)
            raw_power = int(version.get(f"{slot}_power", 0) or 0)
            if period <= 0 and raw_power <= 0:
                continue
            unique = (key, period)
            if unique in seen:
                continue
            seen.add(unique)
            rows.append({
                "sampled_at": sampled_at,
                "epoch": epoch,
                "address": address,
                "label": labels.get(key, ""),
                "period": period,
                "raw_power": raw_power,
                "source_slot": slot,
                "observed_current_period": current_period,
                "observed_next_epoch_period": next_epoch_period,
                "observed_committed_power": committed_by_address.get(key, int(version.get("committed_power", 0) or 0)),
            })
    return rows


def _period_for_epoch(epoch: int, power_period_in_epochs: int) -> int:
    if epoch <= 0 or power_period_in_epochs <= 0:
        return 0
    return (epoch - 1) // power_period_in_epochs


async def _record_epoch_reward_estimates(
    epoch: int,
    validator_rows: list[dict],
    user_rows: list[dict],
) -> None:
    await history.upsert_reward_epoch_estimates(
        "validator",
        [
            {
                "address": row["address"],
                "epoch": epoch,
                "sampled_at": row["sampled_at"],
                "reward_octas": row.get("estimated_epoch_reward_octas", 0),
                "fee_octas": row.get("estimated_epoch_fee_octas", 0),
                "total_estimated_reward_octas": row.get("estimated_epoch_total_octas", 0),
                "owner_commission_octas": row.get("estimated_commission_octas", 0),
            }
            for row in validator_rows
        ],
    )
    await history.upsert_reward_epoch_estimates(
        "user",
        [
            {
                "address": row["address"],
                "epoch": epoch,
                "sampled_at": row["sampled_at"],
                "reward_octas": row.get("estimated_epoch_reward_octas", 0),
                "fee_octas": row.get("estimated_epoch_fee_octas", 0),
                "total_estimated_reward_octas": row.get("estimated_epoch_total_octas", 0),
                "owner_commission_octas": row.get("estimated_owner_commission_octas", 0),
            }
            for row in user_rows
        ],
    )


async def _optional(awaitable, default):
    try:
        return await awaitable
    except Exception:
        return default
