from fastapi import APIRouter, Query
from pydantic import BaseModel
from app.models import watchlist
from app.chain.client import get_chain_client
from app.chain import view
from app.api.ws import broadcast
from app.services import address_book_svc
from app.services import rewards_svc
from app.services.cache_svc import invalidate_many
from app.api.errors import ParamError

router = APIRouter(tags=["watchlist"])

VALID_WATCH_KINDS = {"user", "validator", "dapp"}


def _current_raw_power(power_versions: dict, current_period: int) -> dict:
    newer_period = int(power_versions.get("newer_period", 0) or 0)
    newer_power = int(power_versions.get("newer_power", 0) or 0)
    if (newer_period > 0 or newer_power > 0) and newer_period <= current_period:
        return {"raw_power": newer_power, "raw_power_period": newer_period, "raw_power_slot": "newer"}

    older_period = int(power_versions.get("older_period", 0) or 0)
    older_power = int(power_versions.get("older_power", 0) or 0)
    if (older_period > 0 or older_power > 0) and older_period <= current_period:
        return {"raw_power": older_power, "raw_power_period": older_period, "raw_power_slot": "older"}

    return {"raw_power": 0, "raw_power_period": 0, "raw_power_slot": "none"}


class AddAddressReq(BaseModel):
    kind: str
    address: str
    label: str | None = None


class UpdateLabelReq(BaseModel):
    label: str = ""


@router.get("/watchlist")
async def list_watchlist(kind: str = Query(None)):
    items = await watchlist.get_all_addresses(kind)
    return {"total": len(items), "items": items}


@router.post("/watchlist")
async def add_to_watchlist(req: AddAddressReq):
    wid = await watchlist.add_address(req.kind, req.address, req.label)
    await broadcast("address_book_changed", {"kind": req.kind, "address": req.address})
    return {"id": wid, "success": True}


class GenerateAccountReq(BaseModel):
    kind: str
    label: str | None = None


@router.delete("/watchlist/{kind}/{address}")
async def remove_from_watchlist(kind: str, address: str):
    await watchlist.remove_address(kind, address)
    await broadcast("address_book_changed", {"kind": kind, "address": address})
    return {"success": True}


@router.put("/watchlist/{kind}/{address}/label")
async def update_watchlist_label(kind: str, address: str, req: UpdateLabelReq):
    if kind not in VALID_WATCH_KINDS:
        raise ParamError(f"Unsupported watchlist kind: {kind}")
    label = (req.label or "").strip()
    await watchlist.upsert_label(kind, address, label)
    await invalidate_many("user:", "validators:", "validator:")
    await broadcast("address_book_changed", {"kind": kind, "address": address, "label": label})
    return {"success": True, "kind": kind, "address": address, "label": label}


@router.post("/watchlist/generate-account")
async def generate_account(req: GenerateAccountReq):
    """生成新的 Ed25519 账户，托管私钥并保存到 watchlist。"""
    if req.kind not in VALID_WATCH_KINDS:
        raise ParamError(f"Unsupported watchlist kind: {req.kind}")

    from app.chain.keys import get_key_manager
    km = get_key_manager()
    key, address = km.generate_account(req.label or "")
    await km.persist_key(key, address, req.label or "")
    await watchlist.add_address(req.kind, address, req.label)
    await broadcast("address_book_changed", {"kind": req.kind, "address": address})
    return {
        "address": address,
        "public_key": key.public_key_hex,
        "private_key": key.private_key_hex,
        "kind": req.kind,
        "label": req.label or "",
        "success": True,
    }


@router.get("/address-book")
async def address_book():
    client = get_chain_client()
    entries = await address_book_svc.build_address_book(client)
    return {"total": len(entries), "entries": entries}


@router.get("/watchlist/users")
async def list_watched_users():
    """返回所有可作为用户操作的地址，附带链上状态。"""
    client = get_chain_client()
    items = await _get_user_like_watch_items(client)
    address_book = await address_book_svc.build_address_book(client)
    reward_context = await rewards_svc.get_reward_context(client)
    try:
        current_period = await view.get_current_period(client)
    except Exception:
        current_period = 0
    results = []
    for item in items:
        addr = item["address"]
        display_name = address_book.get(addr.lower(), {}).get("display_name", "")
        entry = {
            "address": addr,
            "label": item.get("label", ""),
            "display_name": display_name,
            "source": item.get("source", "user"),
            "sources": item.get("sources", ["user"]),
            "is_validator_user": bool(item.get("is_validator_user", False)),
            "in_user_watchlist": bool(item.get("in_user_watchlist", False)),
            "in_validator_watchlist": bool(item.get("in_validator_watchlist", False)),
        }
        try:
            balance = await view.get_topo_balance(client, addr)
            entry["balance_topo"] = balance / 1e8
        except Exception:
            entry["balance_topo"] = 0
        try:
            power_versions = await view.get_user_power_version(client, addr)
            entry.update(_current_raw_power(power_versions, current_period))
        except Exception:
            entry.update({"raw_power": 0, "raw_power_period": 0, "raw_power_slot": "none"})
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


async def _get_user_like_watch_items(client=None, include_chain_validators: bool = True) -> list[dict]:
    """Merge explicit users with validator addresses that are also self-delegated users."""
    users = await watchlist.get_addresses("user")
    validators = await watchlist.get_addresses("validator")
    address_book = await address_book_svc.build_address_book(client, include_chain_validators=False)
    by_address: dict[str, dict] = {}

    def add_item(item: dict, source: str, *, label: str = "", in_watchlist: bool = True) -> None:
        address = item.get("address", "")
        if not address:
            return
        key = address.lower()
        current = by_address.get(key)
        if not current:
            current = {
                "address": address,
                "label": "",
                "source": source,
                "sources": [],
                "is_validator_user": False,
                "in_user_watchlist": False,
                "in_validator_watchlist": False,
            }
            by_address[key] = current
        if source not in current["sources"]:
            current["sources"].append(source)
        if source == "user":
            current["in_user_watchlist"] = bool(current.get("in_user_watchlist")) or in_watchlist
            current["source"] = "user"
        if source == "validator":
            current["in_validator_watchlist"] = bool(current.get("in_validator_watchlist")) or in_watchlist
            current["is_validator_user"] = True
        if label and (not current.get("label") or source == "user"):
            current["label"] = label
        display_name = address_book.get(key, {}).get("display_name", "")
        if display_name:
            current["display_name"] = display_name

    for item in users:
        add_item(item, "user", label=item.get("label", ""), in_watchlist=True)
    for item in validators:
        add_item(item, "validator", label=item.get("label", ""), in_watchlist=True)

    if include_chain_validators:
        if client is None:
            client = get_chain_client()
        for getter in (view.get_active_validators, view.get_pending_active_validators):
            try:
                for address in await getter(client, 0, 200):
                    add_item({"address": address}, "validator", in_watchlist=False)
            except Exception:
                pass

    return sorted(
        by_address.values(),
        key=lambda item: (
            0 if item.get("in_user_watchlist") else 1,
            0 if item.get("in_validator_watchlist") else 1,
            item.get("label") or "",
            item.get("display_name") or "",
            item["address"].lower(),
        ),
    )


@router.get("/watchlist/validators")
async def list_watched_validators():
    """返回所有已添加的验证者（watchlist + 链上活跃），附带链上状态"""
    items = await watchlist.get_addresses("validator")
    watched_addrs = {item["address"].lower() for item in items}
    watched_labels = {item["address"].lower(): item.get("label", "") for item in items}

    client = get_chain_client()
    address_book = await address_book_svc.build_address_book(client, include_chain_validators=False)
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
        display_name = labels.get(addr.lower(), "") or address_book.get(addr.lower(), {}).get("display_name", "")
        entry = {
            "address": addr,
            "label": labels.get(addr.lower(), ""),
            "display_name": display_name,
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
            if not entry["display_name"]:
                entry["display_name"] = f"验证者{idx}"
            entry["validator_index"] = idx
            proposals = await view.get_proposal_counts(client, idx)
        except Exception:
            idx = -1
            entry["validator_index"] = -1
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
