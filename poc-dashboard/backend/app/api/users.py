from fastapi import APIRouter, Query
from app.chain.client import get_chain_client
from app.chain import view
from app.services import rewards_svc

router = APIRouter(tags=["users"])


@router.get("/users/{address}")
async def user_detail(address: str):
    client = get_chain_client()

    balance_octas = await view.get_topo_balance(client, address)

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
