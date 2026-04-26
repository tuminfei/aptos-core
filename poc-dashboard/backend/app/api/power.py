from fastapi import APIRouter
from pydantic import BaseModel
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.api.errors import ChainTxError

router = APIRouter(tags=["power"])


class StageSingleReq(BaseModel):
    user_address: str
    power: int


class StageBatchReq(BaseModel):
    target_period: int
    updates: list[dict]


class SetPeriodReq(BaseModel):
    power_period_in_epochs: int


@router.get("/power/overview")
async def power_overview():
    client = get_chain_client()
    current_period = await view.get_current_period(client)
    period_in_epochs = await view.get_power_period_in_epochs(client)
    retention = await view.get_retention_bps(client)
    operator = await view.get_power_operator(client)

    ledger = await client.get_ledger_info()
    epoch = int(ledger.get("epoch", 0))
    epochs_until = period_in_epochs - (epoch % period_in_epochs) if period_in_epochs > 0 else 0

    return {
        "current_period": current_period,
        "power_period_in_epochs": period_in_epochs,
        "retention_bps": retention,
        "operator": operator,
        "current_epoch": epoch,
        "epochs_until_next_period": epochs_until,
    }


@router.post("/power/stage-single")
async def stage_single(req: StageSingleReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::topo_governance::stage_power_update_test_only",
            args=[req.user_address, str(req.power)],
        )
        await operation_log.create_log("stage_power", req.user_address, {"power": req.power}, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("stage_power", req.user_address, {"power": req.power}, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/power/stage-batch")
async def stage_batch(req: StageBatchReq):
    client = get_chain_client()
    km = get_key_manager()
    addresses = [u["address"] for u in req.updates]
    powers = [str(u["power"]) for u in req.updates]
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::poc_power_store::stage_batch_update",
            args=[str(req.target_period), addresses, powers],
        )
        await operation_log.create_log("stage_batch_power", None, {"count": len(addresses)}, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("stage_batch_power", None, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/power/set-period")
async def set_period(req: SetPeriodReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::topo_governance::set_power_period_in_epochs_test_only",
            args=[str(req.power_period_in_epochs)],
        )
        await operation_log.create_log("set_power_period", None, {"epochs": req.power_period_in_epochs}, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_power_period", None, None, None, "failed", str(e))
        raise ChainTxError(str(e))
