import time
from fastapi import APIRouter
from app.chain.client import get_chain_client
from app.chain import view
from app.api.errors import ChainUnreachable
from app.services import address_book_svc
from app.utils.address import address_key

router = APIRouter(tags=["dashboard"])

_cache: dict = {}
_cache_ts: float = 0
CACHE_TTL = 5.0


@router.get("/dashboard/overview")
async def overview():
    global _cache, _cache_ts
    now = time.time()
    if _cache and (now - _cache_ts) < CACHE_TTL:
        return _cache

    client = get_chain_client()
    try:
        ledger = await client.get_ledger_info()
    except Exception as e:
        raise ChainUnreachable(str(e))

    epoch = int(ledger.get("epoch", 0))

    try:
        active_count = await view.get_active_validator_count(client)
        pending_active_count = await view.get_pending_active_validator_count(client)
        pending_inactive_count = await view.get_pending_inactive_validator_count(client)
    except Exception:
        active_count = pending_active_count = pending_inactive_count = 0

    try:
        current_period = await view.get_current_period(client)
        power_period_in_epochs = await view.get_power_period_in_epochs(client)
        retention_bps = await view.get_retention_bps(client)
        power_operator = await view.get_power_operator(client)
    except Exception:
        current_period = power_period_in_epochs = retention_bps = 0
        power_operator = ""

    try:
        total_staked_power = await view.get_total_staked_power(client)
        octas_per_power = await view.get_octas_per_power(client)
        cooldown_secs = await view.get_cooldown_secs(client)
    except Exception:
        total_staked_power = octas_per_power = cooldown_secs = 0

    epochs_until_next = 0
    if power_period_in_epochs > 0:
        epochs_until_next = power_period_in_epochs - (epoch % power_period_in_epochs)

    validators_summary = []
    try:
        address_book = await address_book_svc.build_address_book(client)
        active_addrs = await view.get_active_validators(client, 0, 100)
        for addr in active_addrs:
            try:
                address_entry = address_book.get(address_key(addr), {})
                vp = await view.get_current_epoch_voting_power(client, addr)
                dc = await view.get_validator_delegator_count(client, addr)
                idx = await view.get_validator_index(client, addr)
                proposals = await view.get_proposal_counts(client, idx)
                total_p = proposals["successful"] + proposals["failed"]
                rate = proposals["successful"] / total_p if total_p > 0 else 0
                validators_summary.append({
                    "address": addr, "voting_power": vp,
                    "display_name": address_entry.get("display_name", ""),
                    "delegator_count": dc, "success_rate": round(rate, 3),
                })
            except Exception:
                validators_summary.append({"address": addr, "voting_power": 0, "delegator_count": 0, "success_rate": 0})
    except Exception:
        pass

    result = {
        "chain": {
            "chain_id": int(ledger.get("chain_id", 0)),
            "epoch": epoch,
            "ledger_version": int(ledger.get("ledger_version", 0)),
            "block_height": int(ledger.get("block_height", 0)),
            "ledger_timestamp": ledger.get("ledger_timestamp", ""),
        },
        "validators": {
            "total": active_count + pending_active_count + pending_inactive_count,
            "active": active_count,
            "pending_active": pending_active_count,
            "pending_inactive": pending_inactive_count,
        },
        "power": {
            "current_period": current_period,
            "power_period_in_epochs": power_period_in_epochs,
            "retention_bps": retention_bps,
            "operator": power_operator,
            "epochs_until_next_period": epochs_until_next,
        },
        "staking": {
            "total_staked_power": total_staked_power,
            "octas_per_power": octas_per_power,
            "cooldown_secs": cooldown_secs,
        },
        "active_validators_summary": validators_summary,
    }

    _cache = result
    _cache_ts = now
    return result
