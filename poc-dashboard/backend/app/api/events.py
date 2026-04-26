from fastapi import APIRouter, Query
from app.chain.client import get_chain_client

router = APIRouter(tags=["events"])

EVENT_HANDLES = {
    "poc_power_store": ("0x1", "0x1::poc_power_store::PowerStore", "power_updated_events"),
    "staking_registry": ("0x1", "0x1::staking_registry::StakingRegistry", "delegation_events"),
    "stake": ("0x1", "0x1::stake::ValidatorSet", "join_validator_events"),
}


@router.get("/events")
async def list_events(
    module: str = Query(None),
    event_type: str = Query(None),
    limit: int = Query(25, le=100),
):
    client = get_chain_client()
    events = []

    if module and module in EVENT_HANDLES:
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
        for mod, (addr, handle, field) in EVENT_HANDLES.items():
            try:
                raw = await client.get_events(addr, handle, field, start=0, limit=limit // len(EVENT_HANDLES))
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
