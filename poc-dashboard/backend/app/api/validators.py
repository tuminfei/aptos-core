from fastapi import APIRouter, Query
from pydantic import BaseModel
from app.config import get_settings, load_settings
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.services.validator_svc import get_validators, get_validator_detail, prepare_join
from app.api.errors import ValidatorNotFound, ParamError, ChainTxError

router = APIRouter(tags=["validators"])


class StagePowerReq(BaseModel):
    user_address: str
    power: int


class RegisterReq(BaseModel):
    validator_address: str
    commission_bps: int = 1000


class JoinLeaveReq(BaseModel):
    operator_address: str
    pool_address: str


class PrepareJoinReq(BaseModel):
    validator_address: str = ""
    label: str = ""
    power: int = 10000000000
    set_power_period: int = 5
    force_epochs_before_delegate: int = 5
    force_epochs_after_join: int = 1
    mint_amount: int = 11000000000
    deposit_amount: int = 10000000000
    commission_bps: int = 0


@router.get("/validators")
async def list_validators(status: str = Query("all")):
    client = get_chain_client()
    validators = await get_validators(client, status)
    return {"total": len(validators), "validators": validators}


@router.get("/validators/{address}")
async def validator_detail(address: str):
    client = get_chain_client()
    try:
        detail = await get_validator_detail(client, address)
        return detail
    except Exception as e:
        raise ValidatorNotFound(str(e))


@router.post("/validators/stage-power")
async def stage_power(req: StagePowerReq):
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


@router.post("/validators/register")
async def register_validator(req: RegisterReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.validator_address)
    if not key:
        raise ParamError(f"No key found for validator {req.validator_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.validator_address,
            "0x1::staking_registry::register_validator",
            args=[str(req.commission_bps)],
        )
        await operation_log.create_log("register_validator", req.validator_address, {"commission_bps": req.commission_bps}, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("register_validator", req.validator_address, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/validators/join")
async def join_validator_set(req: JoinLeaveReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.operator_address)
    if not key:
        raise ParamError(f"No key found for operator {req.operator_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.operator_address,
            "0x1::stake::join_validator_set",
            args=[req.pool_address],
        )
        await operation_log.create_log("join_validator_set", req.pool_address, None, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("join_validator_set", req.pool_address, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/validators/leave")
async def leave_validator_set(req: JoinLeaveReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.operator_address)
    if not key:
        raise ParamError(f"No key found for operator {req.operator_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.operator_address,
            "0x1::stake::leave_validator_set",
            args=[req.pool_address],
        )
        await operation_log.create_log("leave_validator_set", req.pool_address, None, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("leave_validator_set", req.pool_address, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/validators/prepare-join")
async def prepare_join_endpoint(req: PrepareJoinReq):
    client = get_chain_client()
    km = get_key_manager()
    settings = get_settings()

    # If address not provided, generate a new account
    if not req.validator_address:
        validator_key, validator_address = km.generate_account(req.label or "")
    else:
        validator_address = req.validator_address
        validator_key = km.get_operator_key_by_address(validator_address)
        if not validator_key:
            settings = load_settings()
            km.load_from_config(settings.keys)
            await km.load_managed_keys()
            validator_key = km.get_operator_key_by_address(validator_address)
        if not validator_key:
            raise ParamError(f"No key found for validator {validator_address}")

    # Persist key to DB so it survives restarts
    await km.persist_key(validator_key, validator_address, req.label)

    from app.models import watchlist
    await watchlist.add_address("validator", validator_address, req.label)

    result = await prepare_join(
        client=client,
        core_key=km.core_resources_key,
        core_address=km.core_resources_address,
        validator_key=validator_key,
        validator_address=validator_address,
        operator_key=validator_key,
        operator_address=validator_address,
        power=req.power,
        set_power_period=req.set_power_period,
        force_epochs=req.force_epochs_before_delegate,
        mint_amount=req.mint_amount,
        deposit_amount=req.deposit_amount,
        commission_bps=req.commission_bps,
        cluster_dir=settings.cluster_dir,
        force_epochs_after_join=req.force_epochs_after_join,
    )
    result["validator_address"] = validator_address
    return result
