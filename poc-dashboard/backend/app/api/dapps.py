from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.api.ws import broadcast
from app.api.errors import ChainTxError, ParamError
from app.chain import view
from app.chain.client import get_chain_client
from app.chain.keys import get_key_manager
from app.chain.transaction import submit_entry_function
from app.models import dapp_demo, operation_log, watchlist
from app.services import dapp_svc
from app.services.cache_svc import get_or_set, invalidate_many

router = APIRouter(tags=["dapps"])

APP_STATE_MAP = {1: "active", 2: "paused", 3: "stopped"}
POC_STATUS_MAP = {1: "registered", 2: "whitelisted", 3: "suspended"}
DEFAULT_MAX_GAS = dapp_svc.DEFAULT_MAX_GAS
DEFAULT_GAS_UNIT_PRICE = dapp_svc.DEFAULT_GAS_UNIT_PRICE


class AppAdminReq(BaseModel):
    app_admin: str
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class RegisterAppReq(BaseModel):
    app_admin: str
    app_address: str
    equity_token_address: str
    custody_address: str
    metadata_uri: str = ""
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class UpdateAddressReq(BaseModel):
    app_admin: str
    new_address: str
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class SetPocStatusReq(BaseModel):
    app_admin: str
    status: int = Field(ge=1, le=3)
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class SetWeightReq(BaseModel):
    app_admin: str
    weight_pbs: int = Field(ge=0, le=10000)
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class CreateDemoReq(BaseModel):
    label: str = "demo-dapp"
    metadata_uri: str = "https://demo.topo.local/poc"
    initial_supply: int = 1_000_000
    price_per_equity: int = 1
    auto_whitelist: bool = True
    gas_mint_octas: int = 1_000_000_000_000
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class MintEquityReq(BaseModel):
    app_admin: str
    amount: int
    module_address: str = ""
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class BuyEquityReq(BaseModel):
    app_admin: str
    equity_amount: int
    buyer_address: str = ""
    buyer_label: str = "demo-buyer"
    module_address: str = ""
    auto_create_buyer: bool = True
    mint_octas: int = dapp_svc.DEFAULT_BUYER_MINT_OCTAS
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


class AutoTradeReq(BaseModel):
    app_admin: str
    module_address: str = ""
    interval_secs: float = 5
    tx_per_tick: int = 1
    amount_min: int = 1
    amount_max: int = 10
    max_runs: int = 0
    buyer_addresses: list[str] = Field(default_factory=list)
    auto_create_buyers: int = 1
    mint_octas: int = dapp_svc.DEFAULT_BUYER_MINT_OCTAS
    max_gas: int = DEFAULT_MAX_GAS
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE


@router.get("/dapps")
async def list_dapps():
    return await get_or_set("dapps:list", _list_dapps_uncached, ttl_secs=10.0)


async def _list_dapps_uncached():
    addresses = await watchlist.get_addresses("dapp")
    if not addresses:
        return {"total": 0, "apps": []}

    client = get_chain_client()
    admins = [a["address"] for a in addresses]
    labels = {a["address"].lower(): a.get("label", "") for a in addresses}

    try:
        exists = await view.exists_apps(client, admins)
        valid_admins = [a for a, e in zip(admins, exists) if e]
    except Exception:
        valid_admins = admins

    if not valid_admins:
        return {"total": 0, "apps": []}

    try:
        infos = await view.get_app_infos_by_admins(client, valid_admins)
    except Exception:
        infos = []

    demo_configs = await dapp_demo.get_configs(valid_admins)
    apps = []
    for i, admin in enumerate(valid_admins):
        info = infos[i] if i < len(infos) else {}
        try:
            state_code = await view.get_app_state(client, admin)
            poc_code = await view.get_poc_listing_status(client, admin)
            weight = await view.get_effective_weight_pbs(client, admin)
            eligible = await view.is_app_eligible_for_poc(client, admin)
        except Exception:
            state_code = poc_code = weight = 0
            eligible = False

        apps.append({
            "app_admin": admin,
            "label": labels.get(admin.lower(), ""),
            "app_state": APP_STATE_MAP.get(state_code, "unknown"),
            "app_state_code": state_code,
            "poc_listing_status": POC_STATUS_MAP.get(poc_code, "unknown"),
            "poc_listing_status_code": poc_code,
            "effective_weight_pbs": weight,
            "eligible_for_poc": eligible,
            "info": info,
            "demo": demo_configs.get(admin),
        })

    return {"total": len(apps), "apps": apps}


@router.get("/dapps/{app_admin}")
async def dapp_detail(app_admin: str):
    return await get_or_set(f"dapp:detail:{app_admin.lower()}", lambda: _dapp_detail_uncached(app_admin), ttl_secs=10.0)


async def _dapp_detail_uncached(app_admin: str):
    client = get_chain_client()
    info = await view.get_app_info(client, app_admin)
    state_code = await view.get_app_state(client, app_admin)
    poc_code = await view.get_poc_listing_status(client, app_admin)
    weight = await view.get_effective_weight_pbs(client, app_admin)
    try:
        eligible = await view.is_app_eligible_for_poc(client, app_admin)
    except Exception:
        eligible = False
    demo = await dapp_svc.get_demo_runtime(app_admin)
    task = dapp_svc.get_trade_task_status(app_admin)

    return {
        "app_admin": app_admin,
        "app_state": APP_STATE_MAP.get(state_code, "unknown"),
        "app_state_code": state_code,
        "poc_listing_status": POC_STATUS_MAP.get(poc_code, "unknown"),
        "poc_listing_status_code": poc_code,
        "effective_weight_pbs": weight,
        "eligible_for_poc": eligible,
        "info": info,
        "demo": demo,
        "auto_trade": task,
    }


async def _submit_admin_action(req: AppAdminReq, function_id: str, action: str):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.app_admin)
    if not key:
        raise ParamError(f"找不到 DApp 管理员托管私钥: {req.app_admin}")
    try:
        tx = await submit_entry_function(
            client,
            key,
            req.app_admin,
            function_id,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log(action, req.app_admin, None, tx, "success")
        await broadcast("dapp_operation", {"action": action, "target": req.app_admin, "status": "success", "tx_hash": tx})
        await broadcast("dapp_changed", {"app_admin": req.app_admin})
        await invalidate_many("dapps:", f"dapp:detail:{req.app_admin.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log(action, req.app_admin, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/register")
async def register_app(req: RegisterAppReq):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.app_admin)
    if not key:
        raise ParamError(f"找不到 DApp 管理员托管私钥: {req.app_admin}")
    params = {
        "app_address": req.app_address,
        "equity_token_address": req.equity_token_address,
        "custody_address": req.custody_address,
        "metadata_uri": req.metadata_uri,
    }
    try:
        tx = await submit_entry_function(
            client,
            key,
            req.app_admin,
            "0x1::poc_registry::register_app",
            args=[req.app_address, req.equity_token_address, req.custody_address, req.metadata_uri],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("register_app", req.app_admin, params, tx, "success")
        await watchlist.add_address("dapp", req.app_admin)
        await broadcast("dapp_operation", {"action": "register_app", "target": req.app_admin, "status": "success", "tx_hash": tx})
        await broadcast("dapp_changed", {"app_admin": req.app_admin})
        await invalidate_many("dapps:", f"dapp:detail:{req.app_admin.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("register_app", req.app_admin, params, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/pause")
async def pause_app(req: AppAdminReq):
    return await _submit_admin_action(req, "0x1::poc_registry::pause_app", "pause_app")


@router.post("/dapps/resume")
async def resume_app(req: AppAdminReq):
    return await _submit_admin_action(req, "0x1::poc_registry::resume_app", "resume_app")


@router.post("/dapps/stop")
async def stop_app(req: AppAdminReq):
    return await _submit_admin_action(req, "0x1::poc_registry::stop_app", "stop_app")


async def _submit_update_address(req: UpdateAddressReq, function_id: str, action: str):
    client = get_chain_client()
    km = get_key_manager()
    key = km.get_operator_key_by_address(req.app_admin)
    if not key:
        raise ParamError(f"找不到 DApp 管理员托管私钥: {req.app_admin}")
    params = {"new_address": req.new_address}
    try:
        tx = await submit_entry_function(
            client,
            key,
            req.app_admin,
            function_id,
            args=[req.new_address],
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log(action, req.app_admin, params, tx, "success")
        await broadcast("dapp_operation", {"action": action, "target": req.app_admin, "status": "success", "tx_hash": tx})
        await broadcast("dapp_changed", {"app_admin": req.app_admin})
        await invalidate_many("dapps:", f"dapp:detail:{req.app_admin.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log(action, req.app_admin, params, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/update-app-address")
async def update_app_address(req: UpdateAddressReq):
    return await _submit_update_address(req, "0x1::poc_registry::update_app_address", "update_app_address")


@router.post("/dapps/update-custody-address")
async def update_custody_address(req: UpdateAddressReq):
    return await _submit_update_address(req, "0x1::poc_registry::update_custody_address", "update_custody_address")


@router.post("/dapps/update-equity-token-address")
async def update_equity_token_address(req: UpdateAddressReq):
    return await _submit_update_address(req, "0x1::poc_registry::update_equity_token_address", "update_equity_token_address")


@router.post("/dapps/whitelist")
async def whitelist_app(req: AppAdminReq):
    req = SetPocStatusReq(app_admin=req.app_admin, status=2, max_gas=req.max_gas, gas_unit_price=req.gas_unit_price)
    return await set_poc_status(req)


@router.post("/dapps/suspend")
async def suspend_app(req: AppAdminReq):
    req = SetPocStatusReq(app_admin=req.app_admin, status=3, max_gas=req.max_gas, gas_unit_price=req.gas_unit_price)
    return await set_poc_status(req)


@router.post("/dapps/set-poc-status")
async def set_poc_status(req: SetPocStatusReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await dapp_svc.set_poc_listing_status_with_core_resources(
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            app_admin=req.app_admin,
            status=req.status,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_poc_listing_status", req.app_admin, {"status": req.status}, tx, "success")
        await broadcast("dapp_operation", {"action": "set_poc_listing_status", "target": req.app_admin, "status": "success", "tx_hash": tx})
        await broadcast("dapp_changed", {"app_admin": req.app_admin})
        await invalidate_many("dapps:", f"dapp:detail:{req.app_admin.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_poc_listing_status", req.app_admin, {"status": req.status}, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/set-weight")
async def set_weight(req: SetWeightReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await dapp_svc.set_effective_weight_with_core_resources(
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            app_admin=req.app_admin,
            weight_pbs=req.weight_pbs,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("set_app_weight", req.app_admin, {"weight": req.weight_pbs}, tx, "success")
        await broadcast("dapp_operation", {"action": "set_app_weight", "target": req.app_admin, "status": "success", "tx_hash": tx})
        await broadcast("dapp_changed", {"app_admin": req.app_admin})
        await invalidate_many("dapps:", f"dapp:detail:{req.app_admin.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_app_weight", req.app_admin, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/demo/create")
async def create_demo(req: CreateDemoReq):
    try:
        return await dapp_svc.create_demo_dapp(
            label=req.label,
            metadata_uri=req.metadata_uri,
            initial_supply=req.initial_supply,
            price_per_equity=req.price_per_equity,
            auto_whitelist=req.auto_whitelist,
            gas_mint_octas=req.gas_mint_octas,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
    except Exception as e:
        raise ChainTxError(str(e))


@router.post("/dapps/demo/mint-equity")
async def mint_demo_equity(req: MintEquityReq):
    try:
        tx = await dapp_svc.mint_equity_to_custody(
            app_admin=req.app_admin,
            amount=req.amount,
            module_address=req.module_address,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
        await operation_log.create_log("demo_dapp_mint_equity", req.app_admin, {"amount": req.amount}, tx, "success")
        await broadcast("dapp_operation", {"action": "demo_dapp_mint_equity", "target": req.app_admin, "status": "success", "tx_hash": tx})
        await broadcast("dapp_changed", {"app_admin": req.app_admin})
        await invalidate_many("dapps:", f"dapp:detail:{req.app_admin.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("demo_dapp_mint_equity", req.app_admin, {"amount": req.amount}, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/demo/buy-equity")
async def buy_demo_equity(req: BuyEquityReq):
    try:
        return await dapp_svc.buy_equity(
            app_admin=req.app_admin,
            equity_amount=req.equity_amount,
            buyer_address=req.buyer_address,
            buyer_label=req.buyer_label,
            module_address=req.module_address,
            auto_create_buyer=req.auto_create_buyer,
            mint_octas=req.mint_octas,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
    except Exception as e:
        raise ChainTxError(str(e))


@router.post("/dapps/demo/auto-trade/start")
async def start_demo_auto_trade(req: AutoTradeReq):
    try:
        return await dapp_svc.start_trade_task(
            app_admin=req.app_admin,
            module_address=req.module_address,
            interval_secs=req.interval_secs,
            tx_per_tick=req.tx_per_tick,
            amount_min=req.amount_min,
            amount_max=req.amount_max,
            max_runs=req.max_runs,
            buyer_addresses=req.buyer_addresses,
            auto_create_buyers=req.auto_create_buyers,
            mint_octas=req.mint_octas,
            max_gas=req.max_gas,
            gas_unit_price=req.gas_unit_price,
        )
    except Exception as e:
        raise ChainTxError(str(e))


@router.post("/dapps/demo/auto-trade/stop")
async def stop_demo_auto_trade(req: AppAdminReq):
    try:
        return await dapp_svc.stop_trade_task(req.app_admin)
    except Exception as e:
        raise ChainTxError(str(e))


@router.get("/dapps/demo/auto-trade/status")
async def demo_auto_trade_status(app_admin: str | None = None):
    return dapp_svc.get_trade_task_status(app_admin)
