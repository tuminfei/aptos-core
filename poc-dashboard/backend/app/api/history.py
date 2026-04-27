from fastapi import APIRouter, Query

from app.models import history
from app.services import history_svc

router = APIRouter(tags=["history"])


def _limit(value: int) -> int:
    return max(1, min(value, 1000))


def _offset(value: int) -> int:
    return max(0, value)


@router.post("/history/sample")
async def sample_history_now():
    result = await history_svc.sample_once()
    return {"success": True, **result}


@router.get("/history/chain")
async def chain_history(limit: int = Query(200), offset: int = Query(0)):
    normalized_limit = _limit(limit)
    normalized_offset = _offset(offset)
    rows = await history.get_chain_history(normalized_limit, normalized_offset)
    total = await history.count_chain_history()
    return {"total": total, "limit": normalized_limit, "offset": normalized_offset, "history": rows}


@router.get("/history/users/{address}")
async def user_history(address: str, limit: int = Query(200), offset: int = Query(0)):
    normalized_limit = _limit(limit)
    normalized_offset = _offset(offset)
    rows = await history.get_user_history(address, normalized_limit, normalized_offset)
    total = await history.count_user_history(address)
    cumulative = await history.get_cumulative_reward("user", address)
    reward_epochs = await history.get_recent_reward_estimates("user", address, 50)
    return {
        "address": address,
        "total": total,
        "limit": normalized_limit,
        "offset": normalized_offset,
        "history": rows,
        "cumulative_rewards": cumulative,
        "reward_epochs": reward_epochs,
    }


@router.get("/history/validators/{address}")
async def validator_history(address: str, limit: int = Query(200), offset: int = Query(0)):
    normalized_limit = _limit(limit)
    normalized_offset = _offset(offset)
    rows = await history.get_validator_history(address, normalized_limit, normalized_offset)
    total = await history.count_validator_history(address)
    cumulative = await history.get_cumulative_reward("validator", address)
    reward_epochs = await history.get_recent_reward_estimates("validator", address, 50)
    return {
        "address": address,
        "total": total,
        "limit": normalized_limit,
        "offset": normalized_offset,
        "history": rows,
        "cumulative_rewards": cumulative,
        "reward_epochs": reward_epochs,
    }
