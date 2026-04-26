from fastapi import APIRouter
from pydantic import BaseModel
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log, watchlist
from app.api.errors import ChainTxError

router = APIRouter(tags=["dapps"])

APP_STATE_MAP = {1: "active", 2: "paused", 3: "stopped"}
POC_STATUS_MAP = {1: "registered", 2: "whitelisted", 3: "suspended"}


class WhitelistReq(BaseModel):
    app_admin: str


class SuspendReq(BaseModel):
    app_admin: str


class SetWeightReq(BaseModel):
    app_admin: str
    weight_pbs: int


@router.get("/dapps")
async def list_dapps():
    addresses = await watchlist.get_addresses("dapp")
    if not addresses:
        return {"total": 0, "apps": []}

    client = get_chain_client()
    admins = [a["address"] for a in addresses]

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

    apps = []
    for i, admin in enumerate(valid_admins):
        info = infos[i] if i < len(infos) else {}
        try:
            state_code = await view.get_app_state(client, admin)
            poc_code = await view.get_poc_listing_status(client, admin)
            weight = await view.get_effective_weight_pbs(client, admin)
        except Exception:
            state_code = poc_code = weight = 0

        apps.append({
            "app_admin": admin,
            "app_state": APP_STATE_MAP.get(state_code, "unknown"),
            "app_state_code": state_code,
            "poc_listing_status": POC_STATUS_MAP.get(poc_code, "unknown"),
            "poc_listing_status_code": poc_code,
            "effective_weight_pbs": weight,
            "info": info,
        })

    return {"total": len(apps), "apps": apps}


@router.get("/dapps/{app_admin}")
async def dapp_detail(app_admin: str):
    client = get_chain_client()
    info = await view.get_app_info(client, app_admin)
    state_code = await view.get_app_state(client, app_admin)
    poc_code = await view.get_poc_listing_status(client, app_admin)
    weight = await view.get_effective_weight_pbs(client, app_admin)

    return {
        "app_admin": app_admin,
        "app_state": APP_STATE_MAP.get(state_code, "unknown"),
        "app_state_code": state_code,
        "poc_listing_status": POC_STATUS_MAP.get(poc_code, "unknown"),
        "poc_listing_status_code": poc_code,
        "effective_weight_pbs": weight,
        "info": info,
    }


@router.post("/dapps/whitelist")
async def whitelist_app(req: WhitelistReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::poc_registry::whitelist_app_for_poc",
            args=[req.app_admin],
        )
        await operation_log.create_log("whitelist_app", req.app_admin, None, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("whitelist_app", req.app_admin, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/suspend")
async def suspend_app(req: SuspendReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::poc_registry::suspend_poc_listing",
            args=[req.app_admin],
        )
        await operation_log.create_log("suspend_app", req.app_admin, None, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("suspend_app", req.app_admin, None, None, "failed", str(e))
        raise ChainTxError(str(e))


@router.post("/dapps/set-weight")
async def set_weight(req: SetWeightReq):
    client = get_chain_client()
    km = get_key_manager()
    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::poc_registry::set_effective_weight_pbs",
            args=[req.app_admin, str(req.weight_pbs)],
        )
        await operation_log.create_log("set_app_weight", req.app_admin, {"weight": req.weight_pbs}, tx, "success")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("set_app_weight", req.app_admin, None, None, "failed", str(e))
        raise ChainTxError(str(e))
