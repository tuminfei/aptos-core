from fastapi import APIRouter, Query
from app.chain.client import get_chain_client

router = APIRouter(tags=["events"])

EVENT_HANDLES = {
    "staking_registry": ("0x1", "0x1::staking_registry::StakingRegistry", "delegation_events"),
    "stake": ("0x1", "0x1::stake::ValidatorSet", "join_validator_events"),
}

MODULE_EVENT_TYPES = {
    "poc_power_store": (
        "0x1::poc_power_store::OperatorChangedEvent",
        "0x1::poc_power_store::PowerUpdateStagedEvent",
        "0x1::poc_power_store::PowerPeriodCommittedEvent",
    ),
}


@router.get("/events")
async def list_events(
    module: str = Query(None),
    event_type: str = Query(None),
    limit: int = Query(25, le=100),
):
    client = get_chain_client()
    events = []

    if module and module in MODULE_EVENT_TYPES:
        events.extend(await _get_module_events(client, module, limit))
    elif module and module in EVENT_HANDLES:
        addr, handle, field = EVENT_HANDLES[module]
        try:
            raw = await client.get_events(addr, handle, field, start=0, limit=limit)
            for e in raw:
                events.append({
                    "version": int(e.get("version", 0)),
                    "sequence_number": int(e.get("sequence_number", 0)),
                    "type": e.get("type", ""),
                    "data": e.get("data", {}),
                })
        except Exception:
            pass
    else:
        for mod in MODULE_EVENT_TYPES:
            try:
                events.extend(await _get_module_events(client, mod, limit // (len(EVENT_HANDLES) + len(MODULE_EVENT_TYPES))))
            except Exception:
                pass
        for mod, (addr, handle, field) in EVENT_HANDLES.items():
            try:
                raw = await client.get_events(addr, handle, field, start=0, limit=limit // (len(EVENT_HANDLES) + len(MODULE_EVENT_TYPES)))
                for e in raw:
                    events.append({
                        "version": int(e.get("version", 0)),
                        "sequence_number": int(e.get("sequence_number", 0)),
                        "type": e.get("type", ""),
                        "data": e.get("data", {}),
                        "module": mod,
                    })
            except Exception:
                pass

    events.sort(key=lambda x: x["version"], reverse=True)
    return {"events": events[:limit]}


async def _get_module_events(client, module: str, limit: int) -> list[dict]:
    event_types = MODULE_EVENT_TYPES[module]
    scan_limit = min(max(limit * 20, 100), 500)
    transactions = await client.get_transactions(limit=scan_limit)
    events = []
    for txn in transactions:
        try:
            version = int(txn.get("version", 0))
        except Exception:
            version = 0
        for index, event in enumerate(txn.get("events") or []):
            event_type = event.get("type", "")
            if event_type not in event_types:
                continue
            events.append({
                "version": version,
                "sequence_number": int(event.get("sequence_number", index) or index),
                "type": event_type,
                "data": event.get("data", {}),
                "module": module,
            })
            if len(events) >= limit:
                return events
    return events
