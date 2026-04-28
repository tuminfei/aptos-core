from fastapi import APIRouter
from pydantic import BaseModel
from app.chain.client import get_chain_client
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.services.staking_svc import USER_MAX_GAS, proxy_stake
from app.services.cache_svc import invalidate_many
from app.api.errors import ParamError, ChainTxError

router = APIRouter(tags=["staking"])


class DepositReq(BaseModel):
    user_address: str
    amount: int


class DelegateReq(BaseModel):
    user_address: str
    validator_address: str


class UndelegateReq(BaseModel):
    user_address: str


class WithdrawReq(BaseModel):
    user_address: str


class ProxyStakeReq(BaseModel):
    target_user: str = ""
    label: str = ""
    mint_amount: int
    set_power: int
    deposit_amount: int
    delegate_to: str
    force_epoch: bool = False
    force_epochs: int = 0


@router.post("/staking/deposit")
async def deposit(req: DepositReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.user_address)
    if not key:
        raise ParamError(f"No key found for user {req.user_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.user_address,
            "0x1::staking_registry::deposit",
            args=[str(req.amount)],
            max_gas=USER_MAX_GAS,
        )
        await operation_log.create_log("deposit", req.user_address, {"amount": req.amount}, tx, "success")
        await invalidate_many(f"user:detail:{req.user_address.lower()}", "validators:", "validator:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("deposit", req.user_address, {"amount": req.amount}, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/staking/delegate")
async def delegate(req: DelegateReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.user_address)
    if not key:
        raise ParamError(f"No key found for user {req.user_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.user_address,
            "0x1::staking_registry::delegate",
            args=[req.validator_address],
            max_gas=USER_MAX_GAS,
        )
        await operation_log.create_log("delegate", req.user_address, {"validator": req.validator_address}, tx, "success")
        await invalidate_many(f"user:detail:{req.user_address.lower()}", "validators:", f"validator:detail:{req.validator_address.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("delegate", req.user_address, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/staking/undelegate")
async def undelegate(req: UndelegateReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.user_address)
    if not key:
        raise ParamError(f"No key found for user {req.user_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.user_address,
            "0x1::staking_registry::undelegate",
            max_gas=USER_MAX_GAS,
        )
        await operation_log.create_log("undelegate", req.user_address, None, tx, "success")
        await invalidate_many(f"user:detail:{req.user_address.lower()}", "validators:", "validator:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("undelegate", req.user_address, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/staking/withdraw")
async def withdraw(req: WithdrawReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.user_address)
    if not key:
        raise ParamError(f"No key found for user {req.user_address}")
    try:
        tx = await submit_entry_function(
            client, key, req.user_address,
            "0x1::staking_registry::withdraw_deposit",
            max_gas=USER_MAX_GAS,
        )
        await operation_log.create_log("withdraw", req.user_address, None, tx, "success")
        await invalidate_many(f"user:detail:{req.user_address.lower()}", "validators:", "validator:")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("withdraw", req.user_address, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/staking/proxy")
async def proxy_stake_endpoint(req: ProxyStakeReq):
    client = get_chain_client()
    km = get_key_manager()

    if not req.target_user:
        user_key, user_address = km.generate_account(req.label or "")
    else:
        user_address = req.target_user
        user_key = km.get_operator_key_by_address(user_address)
        if not user_key:
            user_key, user_address = km.generate_account(req.label or "")

    await km.persist_key(user_key, user_address, req.label)

    from app.models import watchlist
    await watchlist.add_address("user", user_address, req.label)

    result = await proxy_stake(
        client=client,
        core_key=km.core_resources_key,
        core_address=km.core_resources_address,
        user_key=user_key,
        user_address=user_address,
        mint_amount=req.mint_amount,
        power=req.set_power,
        deposit_amount=req.deposit_amount,
        delegate_to=req.delegate_to,
        force_epoch=req.force_epoch,
        force_epochs=req.force_epochs,
    )
    result["user_address"] = user_address
    await invalidate_many(f"user:detail:{user_address.lower()}", "validators:", f"validator:detail:{req.delegate_to.lower()}")
    return result
