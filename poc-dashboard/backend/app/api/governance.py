import asyncio

from fastapi import APIRouter
from pydantic import BaseModel, Field
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.services import dapp_svc, upgrade_svc
from app.services.cache_svc import invalidate_many
from app.api.errors import ChainTxError

router = APIRouter(tags=["governance"])


class UpdateGovernanceConfigReq(BaseModel):
    min_voting_threshold: int = Field(ge=0)
    required_proposer_stake: int = Field(ge=0)
    voting_duration_secs: int = Field(gt=0)
    max_gas: int = dapp_svc.DEFAULT_MAX_GAS
    gas_unit_price: int = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class SetOctasPerPowerReq(BaseModel):
    octas_per_power: int = Field(gt=0)
    max_gas: int = dapp_svc.DEFAULT_MAX_GAS
    gas_unit_price: int = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class SetCooldownSecsReq(BaseModel):
    cooldown_secs: int = Field(ge=0)
    max_gas: int = dapp_svc.DEFAULT_MAX_GAS
    gas_unit_price: int = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class SetEpochIntervalReq(BaseModel):
    epoch_interval_secs: int = Field(gt=0)
    max_gas: int = dapp_svc.DEFAULT_MAX_GAS
    gas_unit_price: int = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class UpgradeFrameworkReq(BaseModel):
    max_gas: int = 2_000_000
    gas_unit_price: int = 100


class CleanupStagingReq(BaseModel):
    max_gas: int = 200_000
    gas_unit_price: int = 100


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
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
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

    try:
        epoch_interval_secs = await view.get_epoch_interval_secs(client)
    except Exception:
        epoch_interval_secs = 0

    return {
        "chain": {
            "epoch_interval_secs": epoch_interval_secs,
        },
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


@router.post("/governance/update-config")
async def update_governance_config(req: UpdateGovernanceConfigReq):
    client = get_chain_client()
    km = get_key_manager()
    details = {
        "min_voting_threshold": req.min_voting_threshold,
        "required_proposer_stake": req.required_proposer_stake,
        "voting_duration_secs": req.voting_duration_secs,
    }
    try:
        tx = await dapp_svc.run_poc_framework_script(
            "update_governance_config.move",
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            args=[
                f"u128:{req.min_voting_threshold}",
                f"u64:{req.required_proposer_stake}",
                f"u64:{req.voting_duration_secs}",
            ],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("update_governance_config", None, details, tx, "success")
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("update_governance_config", None, details, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/governance/set-octas-per-power")
async def set_octas_per_power(req: SetOctasPerPowerReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await dapp_svc.run_poc_framework_script(
            "set_staking_octas_per_power.move",
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            args=[f"u64:{req.octas_per_power}"],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_octas_per_power", None, {"octas_per_power": req.octas_per_power}, tx, "success")
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_octas_per_power", None, {"octas_per_power": req.octas_per_power}, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/governance/set-epoch-interval")
async def set_epoch_interval(req: SetEpochIntervalReq):
    client = get_chain_client()
    km = get_key_manager()
    epoch_interval_microsecs = req.epoch_interval_secs * 1_000_000
    details = {
        "epoch_interval_secs": req.epoch_interval_secs,
        "epoch_interval_microsecs": epoch_interval_microsecs,
    }
    try:
        tx = await dapp_svc.run_poc_framework_script(
            "set_epoch_interval.move",
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            args=[f"u64:{epoch_interval_microsecs}"],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_epoch_interval", None, details, tx, "success")
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_epoch_interval", None, details, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/governance/set-cooldown-secs")
async def set_cooldown_secs(req: SetCooldownSecsReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await dapp_svc.run_poc_framework_script(
            "set_staking_cooldown_secs.move",
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            args=[f"u64:{req.cooldown_secs}"],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_cooldown_secs", None, {"cooldown_secs": req.cooldown_secs}, tx, "success")
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_cooldown_secs", None, {"cooldown_secs": req.cooldown_secs}, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.get("/governance/framework-status")
async def framework_status():
    try:
        status = await upgrade_svc.get_framework_status()
        return status
    except Exception as e:
        raise ChainTxError(str(e))


@router.post("/governance/upgrade-framework")
async def upgrade_framework(req: UpgradeFrameworkReq):
    if upgrade_svc.is_upgrading():
        raise ChainTxError("升级正在进行中，请等待完成")
    asyncio.create_task(
        upgrade_svc.upgrade_framework(max_gas=req.max_gas, gas_unit_price=req.gas_unit_price)
    )
    return {"started": True}


@router.post("/governance/cleanup-staging")
async def cleanup_staging(req: CleanupStagingReq):
    try:
        tx = await upgrade_svc.cleanup_staging_area(
            max_gas=req.max_gas, gas_unit_price=req.gas_unit_price
        )
        await operation_log.create_log("cleanup_staging_area", None, {}, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("cleanup_staging_area", None, {}, None, "failed", str(e))
        raise ChainTxError(str(e))
