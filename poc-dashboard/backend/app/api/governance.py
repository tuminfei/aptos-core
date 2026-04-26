from fastapi import APIRouter
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.api.errors import ChainTxError

router = APIRouter(tags=["governance"])


@router.post("/governance/force-end-epoch")
async def force_end_epoch():
    client = get_chain_client()
    km = get_key_manager()
    ledger = await client.get_ledger_info()
    old_epoch = int(ledger.get("epoch", 0))
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::topo_governance::force_end_epoch_test_only",
        )
        await operation_log.create_log("force_end_epoch", None, {"old_epoch": old_epoch}, tx, "success")
        return {"tx_hash": tx, "old_epoch": old_epoch, "success": True}
    except Exception as e:
        await operation_log.create_log("force_end_epoch", None, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.get("/governance/config")
async def governance_config():
    client = get_chain_client()

    try:
        voting_duration = await view.get_voting_duration_secs(client)
        min_threshold = await view.get_min_voting_threshold(client)
        proposer_stake = await view.get_required_proposer_stake(client)
    except Exception:
        voting_duration = min_threshold = proposer_stake = 0

    try:
        cooldown = await view.get_cooldown_secs(client)
        octas_per_power = await view.get_octas_per_power(client)
    except Exception:
        cooldown = octas_per_power = 0

    try:
        period_in_epochs = await view.get_power_period_in_epochs(client)
        retention = await view.get_retention_bps(client)
    except Exception:
        period_in_epochs = retention = 0

    return {
        "governance": {
            "min_voting_threshold": min_threshold,
            "required_proposer_stake": proposer_stake,
            "voting_duration_secs": voting_duration,
        },
        "staking": {
            "cooldown_secs": cooldown,
            "octas_per_power": octas_per_power,
        },
        "power": {
            "power_period_in_epochs": period_in_epochs,
            "retention_bps": retention,
        },
    }
