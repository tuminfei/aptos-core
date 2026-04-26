from fastapi import APIRouter, Query
from pydantic import BaseModel
from app.models import watchlist
from app.chain.client import get_chain_client
from app.chain import view
from app.services import rewards_svc

router = APIRouter(tags=["watchlist"])


class AddAddressReq(BaseModel):
    kind: str
    address: str
    label: str | None = None


@router.get("/watchlist")
async def list_watchlist(kind: str = Query(None)):
    items = await watchlist.get_all_addresses(kind)
    return {"total": len(items), "items": items}


@router.post("/watchlist")
async def add_to_watchlist(req: AddAddressReq):
    wid = await watchlist.add_address(req.kind, req.address, req.label)
    return {"id": wid, "success": True}


class GenerateAccountReq(BaseModel):
    kind: str
    label: str | None = None


@router.delete("/watchlist/{kind}/{address}")
async def remove_from_watchlist(kind: str, address: str):
    await watchlist.remove_address(kind, address)
    return {"success": True}


@router.post("/watchlist/generate-account")
async def generate_account(req: GenerateAccountReq):
    """生成新的 Ed25519 账户，注册到 KeyManager 并保存到 watchlist"""
    from app.chain.keys import get_key_manager
    km = get_key_manager()
    key, address = km.generate_account(req.label or "")
    await watchlist.add_address(req.kind, address, req.label)
    return {"address": address, "public_key": key.public_key_hex, "success": True}


@router.get("/watchlist/users")
async def list_watched_users():
    """返回所有已添加的用户，附带链上状态"""
    items = await watchlist.get_addresses("user")
    client = get_chain_client()
    reward_context = await rewards_svc.get_reward_context(client)
    results = []
    for item in items:
        addr = item["address"]
        entry = {"address": addr, "label": item.get("label", "")}
        try:
            balance = await view.get_topo_balance(client, addr)
            entry["balance_topo"] = balance / 1e8
        except Exception:
            entry["balance_topo"] = 0
        try:
            power = await view.get_user_committed_power(client, addr)
            entry["committed_power"] = power
        except Exception:
            entry["committed_power"] = 0
        stake = {"deposit": 0, "delegated_to": "0x0", "cooldown_until_secs": 0}
        try:
            stake = await view.get_user_stake_info(client, addr)
        except Exception:
            pass
        entry["deposit_topo"] = stake["deposit"] / 1e8
        entry["delegated_to"] = stake["delegated_to"]
        try:
            effective_power = await view.get_effective_power(client, addr)
        except Exception:
            effective_power = 0
        entry["effective_power"] = effective_power
        rewards = await rewards_svc.estimate_user_rewards(
            client,
            addr,
            stake_info=stake,
            effective_power=effective_power,
            context=reward_context,
        )
        entry["estimated_epoch_reward_topo"] = rewards["estimated_epoch_reward_octas"] / 1e8
        entry["estimated_epoch_fee_topo"] = rewards["estimated_epoch_fee_octas"] / 1e8
        entry["estimated_epoch_total_topo"] = rewards["estimated_epoch_total_octas"] / 1e8
        entry["rewards"] = rewards
        results.append(entry)
    return {"total": len(results), "users": results}


@router.get("/watchlist/validators")
async def list_watched_validators():
    """返回所有已添加的验证者（watchlist + 链上活跃），附带链上状态"""
    items = await watchlist.get_addresses("validator")
    watched_addrs = {item["address"].lower() for item in items}
    watched_labels = {item["address"].lower(): item.get("label", "") for item in items}

    client = get_chain_client()
    reward_context = await rewards_svc.get_reward_context(client)
    all_addrs = set()
    labels = {}

    for item in items:
        all_addrs.add(item["address"])
        labels[item["address"].lower()] = item.get("label", "")

    try:
        active = await view.get_active_validators(client, 0, 200)
        for a in active:
            all_addrs.add(a)
            if a.lower() not in labels:
                labels[a.lower()] = ""
    except Exception:
        pass
    try:
        pending = await view.get_pending_active_validators(client, 0, 200)
        for a in pending:
            all_addrs.add(a)
            if a.lower() not in labels:
                labels[a.lower()] = ""
    except Exception:
        pass

    results = []
    for addr in all_addrs:
        entry = {
            "address": addr,
            "label": labels.get(addr.lower(), ""),
            "in_watchlist": addr.lower() in watched_addrs,
        }
        try:
            state = await view.get_validator_state(client, addr)
            status_map = {1: "pending_active", 2: "active", 3: "pending_inactive", 4: "inactive"}
            entry["status"] = status_map.get(state, "unknown")
            entry["status_code"] = state
        except Exception:
            entry["status"] = "unknown"
            entry["status_code"] = 0
        try:
            vp = await view.get_current_epoch_voting_power(client, addr)
            entry["voting_power"] = vp
        except Exception:
            entry["voting_power"] = 0
        try:
            validator_view = await view.get_validator_view(client, addr)
            entry["commission_bps"] = validator_view["commission_bps"]
            entry["delegator_count"] = validator_view["delegator_count"]
            entry["total_pool_power"] = validator_view["total_power"]
        except Exception:
            entry["commission_bps"] = 0
            entry["delegator_count"] = 0
            entry["total_pool_power"] = 0
        try:
            idx = await view.get_validator_index(client, addr)
            proposals = await view.get_proposal_counts(client, idx)
        except Exception:
            idx = -1
            proposals = {"successful": 0, "failed": 0}
        rewards = await rewards_svc.estimate_validator_rewards(
            client,
            addr,
            idx,
            entry["total_pool_power"],
            entry["commission_bps"],
            proposals=proposals,
            context=reward_context,
        )
        entry["estimated_epoch_reward_topo"] = rewards["estimated_epoch_reward_octas"] / 1e8
        entry["estimated_epoch_fee_topo"] = rewards["estimated_epoch_fee_octas"] / 1e8
        entry["estimated_epoch_total_topo"] = rewards["estimated_epoch_total_octas"] / 1e8
        entry["rewards"] = rewards
        results.append(entry)

    results.sort(key=lambda x: (-x.get("voting_power", 0), x["address"]))
    return {"total": len(results), "validators": results}
