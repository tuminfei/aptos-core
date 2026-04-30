from fastapi import APIRouter
from pydantic import BaseModel, Field
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.services import dapp_svc
from app.services.cache_svc import invalidate_many
from app.api.errors import ChainTxError
from app.api.users import build_power_calculation, build_version_rows, period_for_epoch
from app.api.watchlist import _get_user_like_watch_items
from app.utils.address import address_key

router = APIRouter(tags=["power"])


class StageSingleReq(BaseModel):
    user_address: str
    power: int


class StageBatchReq(BaseModel):
    target_period: int
    updates: list[dict]


class SetPeriodReq(BaseModel):
    power_period_in_epochs: int


class SetRetentionReq(BaseModel):
    retention_bps_per_period: int = Field(gt=0, le=10000)
    max_gas: int = dapp_svc.DEFAULT_MAX_GAS
    gas_unit_price: int = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class SetOperatorReq(BaseModel):
    operator: str
    max_gas: int = dapp_svc.DEFAULT_MAX_GAS
    gas_unit_price: int = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class UserPowerQueryReq(BaseModel):
    addresses: list[str]
    target_period: int | None = None


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


@router.get("/power/store")
async def power_store_overview():
    client = get_chain_client()
    current_period = await view.get_current_period(client)
    period_in_epochs = await view.get_power_period_in_epochs(client)
    retention = await view.get_retention_bps(client)
    operator = await view.get_power_operator(client)

    ledger = await client.get_ledger_info()
    epoch = int(ledger.get("epoch", 0))
    next_epoch_period = period_for_epoch(epoch + 1, period_in_epochs)
    epochs_until = period_in_epochs - (epoch % period_in_epochs) if period_in_epochs > 0 else 0

    watched_users = await _get_user_like_watch_items(client)
    user_addresses = [item["address"] for item in watched_users[:200]]
    watched_summary = await _build_power_store_user_rows(
        user_addresses,
        target_period=next_epoch_period,
        current_period=current_period,
        next_epoch_period=next_epoch_period,
        retention_bps=retention,
    )

    return {
        "operator": operator,
        "current_epoch": epoch,
        "current_period": current_period,
        "next_epoch_period": next_epoch_period,
        "power_period_in_epochs": period_in_epochs,
        "retention_bps": retention,
        "retention_percent": retention / 100,
        "decay_bps": max(0, 10000 - retention),
        "epochs_until_next_period": epochs_until,
        "watched_user_count": len(watched_users),
        "validator_user_count": sum(1 for item in watched_users if item.get("is_validator_user")),
        "watched_users": watched_summary,
    }


@router.post("/power/store/users")
async def query_power_store_users(req: UserPowerQueryReq):
    client = get_chain_client()
    current_period = await view.get_current_period(client)
    period_in_epochs = await view.get_power_period_in_epochs(client)
    retention = await view.get_retention_bps(client)
    ledger = await client.get_ledger_info()
    epoch = int(ledger.get("epoch", 0))
    next_epoch_period = period_for_epoch(epoch + 1, period_in_epochs)
    target_period = req.target_period if req.target_period is not None else next_epoch_period
    addresses = [_normalize_address(address) for address in req.addresses if address.strip()]
    return {
        "current_epoch": epoch,
        "current_period": current_period,
        "next_epoch_period": next_epoch_period,
        "target_period": target_period,
        "retention_bps": retention,
        "users": await _build_power_store_user_rows(
            addresses,
            target_period=target_period,
            current_period=current_period,
            next_epoch_period=next_epoch_period,
            retention_bps=retention,
        ),
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
        await invalidate_many(f"user:detail:{req.user_address.lower()}", "validators:", "validator:")
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
        await invalidate_many("user:", "validators:", "validator:")
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
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_power_period", None, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/power/set-retention")
async def set_retention(req: SetRetentionReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await dapp_svc.run_poc_framework_script(
            "set_power_store_retention.move",
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            args=[f"u64:{req.retention_bps_per_period}"],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_power_store_retention", None, {"retention_bps": req.retention_bps_per_period}, tx, "success")
        await invalidate_many("user:", "validators:", "validator:", "dapps:", "dapp:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_power_store_retention", None, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/power/set-operator")
async def set_operator(req: SetOperatorReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await dapp_svc.run_poc_framework_script(
            "set_power_store_operator.move",
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            args=[f"address:{_normalize_address(req.operator)}"],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_power_store_operator", req.operator, None, tx, "success")
        await invalidate_many("user:", "validators:", "validator:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_power_store_operator", req.operator, None, None, "failed", str(e))
        raise ChainTxError(str(e))


async def _build_power_store_user_rows(
    addresses: list[str],
    *,
    target_period: int,
    current_period: int,
    next_epoch_period: int,
    retention_bps: int,
) -> list[dict]:
    if not addresses:
        return []
    client = get_chain_client()
    versions = await view.get_user_power_versions(client, addresses)
    committed_powers = await _optional(view.get_user_committed_powers(client, addresses), [0] * len(addresses))
    target_powers = await _optional(view.get_user_powers_for_period(client, addresses, target_period), [0] * len(addresses))
    watch_items = await _get_user_like_watch_items(client)
    metadata = {address_key(item["address"]): item for item in watch_items}
    rows = []
    by_address = {address_key(item["user"]): item for item in versions}
    for index, address in enumerate(addresses):
        key = address_key(address)
        meta = metadata.get(key, {})
        version = by_address.get(key, {
            "older_period": 0,
            "older_power": 0,
            "newer_period": 0,
            "newer_power": 0,
            "committed_power": 0,
        })
        current_power = int(committed_powers[index] if index < len(committed_powers) else 0)
        target_power = int(target_powers[index] if index < len(target_powers) else 0)
        rows.append({
            "address": address,
            "label": meta.get("label", ""),
            "source": meta.get("source", ""),
            "sources": meta.get("sources", []),
            "is_validator_user": bool(meta.get("is_validator_user", False)),
            "in_user_watchlist": bool(meta.get("in_user_watchlist", False)),
            "in_validator_watchlist": bool(meta.get("in_validator_watchlist", False)),
            "committed_power": current_power,
            "target_period": target_period,
            "target_power": target_power,
            "version_rows": build_version_rows(version, current_period, next_epoch_period, retention_bps),
            "target_calculation": build_power_calculation(version, target_period, retention_bps, target_power),
        })
    return rows


async def _optional(awaitable, default):
    try:
        return await awaitable
    except Exception:
        return default


def _normalize_address(address: str) -> str:
    value = (address or "").strip()
    if not value:
        return value
    return value if value.startswith("0x") else f"0x{value}"
