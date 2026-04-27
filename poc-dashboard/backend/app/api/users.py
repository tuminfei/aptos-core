from fastapi import APIRouter, Query
from app.chain.client import get_chain_client
from app.chain import view
from app.services import rewards_svc

router = APIRouter(tags=["users"])
BPS_DENOMINATOR = 10000


def apply_retention(power: int, periods_elapsed: int, retention_bps: int) -> int:
    retained = max(0, int(power or 0))
    if retained == 0 or periods_elapsed <= 0:
        return retained
    for _ in range(periods_elapsed):
        if retained == 0:
            return 0
        retained = retained * retention_bps // BPS_DENOMINATOR
    return retained


def select_power_version(versions: dict, target_period: int) -> dict:
    newer = {
        "slot": "newer",
        "effective_period": int(versions.get("newer_period", 0) or 0),
        "power": int(versions.get("newer_power", 0) or 0),
    }
    if (newer["effective_period"] > 0 or newer["power"] > 0) and newer["effective_period"] <= target_period:
        return newer

    older = {
        "slot": "older",
        "effective_period": int(versions.get("older_period", 0) or 0),
        "power": int(versions.get("older_power", 0) or 0),
    }
    if (older["effective_period"] > 0 or older["power"] > 0) and older["effective_period"] <= target_period:
        return older

    return {"slot": "none", "effective_period": 0, "power": 0}


def build_power_calculation(versions: dict, target_period: int, retention_bps: int, chain_power: int) -> dict:
    selected = select_power_version(versions, target_period)
    periods_elapsed = max(0, target_period - selected["effective_period"]) if selected["slot"] != "none" else 0
    calculated = apply_retention(selected["power"], periods_elapsed, retention_bps)
    return {
        "target_period": target_period,
        "selected_slot": selected["slot"],
        "base_period": selected["effective_period"],
        "base_power": selected["power"],
        "periods_elapsed": periods_elapsed,
        "retention_bps": retention_bps,
        "calculated_power": calculated,
        "chain_power": int(chain_power or 0),
        "delta": int(chain_power or 0) - calculated,
    }


def period_for_epoch(epoch: int, power_period_in_epochs: int) -> int:
    if epoch <= 0 or power_period_in_epochs <= 0:
        return 0
    return (epoch - 1) // power_period_in_epochs


@router.get("/users/{address}")
async def user_detail(address: str):
    client = get_chain_client()

    balance_octas = await view.get_topo_balance(client, address)

    current_period = power_period_in_epochs = retention_bps = 0
    current_epoch = next_epoch_period = 0
    try:
        current_period = await view.get_current_period(client)
        power_period_in_epochs = await view.get_power_period_in_epochs(client)
        retention_bps = await view.get_retention_bps(client)
        ledger = await client.get_ledger_info()
        current_epoch = int(ledger.get("epoch", 0))
        next_epoch_period = period_for_epoch(current_epoch + 1, power_period_in_epochs)
    except Exception:
        pass

    power_versions = {
        "older_period": 0,
        "older_power": 0,
        "newer_period": 0,
        "newer_power": 0,
        "committed_power": 0,
    }
    try:
        power_versions = await view.get_user_power_version(client, address)
    except Exception:
        pass

    try:
        committed = await view.get_user_committed_power(client, address)
        next_epoch = await view.get_user_power_for_next_epoch(client, address)
    except Exception:
        committed = next_epoch = 0

    try:
        effective = await view.get_effective_power(client, address)
    except Exception:
        effective = 0

    stake_info = {"deposit": 0, "delegated_to": "0x0", "cooldown_until_secs": 0}
    try:
        stake_info = await view.get_user_stake_info(client, address)
    except Exception:
        pass
    deposit_octas = stake_info["deposit"]
    delegated_to = stake_info["delegated_to"]
    cooldown_until = stake_info["cooldown_until_secs"]

    rewards = await rewards_svc.estimate_user_rewards(
        client,
        address,
        stake_info=stake_info,
        effective_power=effective,
    )

    import time
    return {
        "address": address,
        "balance": {
            "topo_octas": balance_octas,
            "topo": balance_octas / 1e8,
        },
        "power": {
            "committed_power": committed,
            "power_for_next_epoch": next_epoch,
            "effective_power": effective,
        },
        "power_store": {
            "current_epoch": current_epoch,
            "current_period": current_period,
            "next_epoch_period": next_epoch_period,
            "power_period_in_epochs": power_period_in_epochs,
            "retention_bps": retention_bps,
            "retention_ratio": retention_bps / BPS_DENOMINATOR if retention_bps else 0,
            "decay_bps": max(0, BPS_DENOMINATOR - retention_bps),
            "decay_ratio": max(0, BPS_DENOMINATOR - retention_bps) / BPS_DENOMINATOR if retention_bps else 0,
            "versions": {
                "older": {
                    "effective_period": int(power_versions.get("older_period", 0) or 0),
                    "raw_power": int(power_versions.get("older_power", 0) or 0),
                },
                "newer": {
                    "effective_period": int(power_versions.get("newer_period", 0) or 0),
                    "raw_power": int(power_versions.get("newer_power", 0) or 0),
                },
            },
            "current_calculation": build_power_calculation(
                power_versions,
                current_period,
                retention_bps,
                committed,
            ),
            "next_epoch_calculation": build_power_calculation(
                power_versions,
                next_epoch_period,
                retention_bps,
                next_epoch,
            ),
            "staking_effective_power": effective,
        },
        "staking": {
            "deposit_octas": deposit_octas,
            "deposit_topo": deposit_octas / 1e8,
            "delegated_to": delegated_to,
            "cooldown_until": cooldown_until,
            "is_in_cooldown": cooldown_until > int(time.time()),
        },
        "rewards": rewards,
    }


@router.get("/users/{address}/power-history")
async def power_history(address: str, periods: int = Query(10)):
    client = get_chain_client()
    current_period = await view.get_current_period(client)

    history = []
    for p in range(max(0, current_period - periods + 1), current_period + 1):
        try:
            power = await view.get_user_power_for_period(client, address, p)
            history.append({"period": p, "power": power})
        except Exception:
            history.append({"period": p, "power": 0})

    return {
        "address": address,
        "current_period": current_period,
        "history": history,
    }
