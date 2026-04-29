from fastapi import APIRouter, Query

from app.models import history
from app.services import consensus_svc
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


@router.post("/history/consensus-validator-power/sample")
async def sample_consensus_validator_power_now():
    result = await consensus_svc.sample_consensus_epoch_voting_power(force=True)
    return {"success": bool(result.get("captured")), **result}


@router.get("/history/consensus-validator-power")
async def consensus_validator_power_history(
    limit: int = Query(50),
    offset: int = Query(0),
    start_epoch: int | None = Query(None),
    end_epoch: int | None = Query(None),
    include_validators: bool = Query(False),
):
    if start_epoch is not None and end_epoch is not None:
        rows = await history.get_consensus_validator_power_epochs_between(
            start_epoch,
            end_epoch,
            include_validators=include_validators,
        )
        total = await history.count_consensus_validator_power_epochs()
        return {
            "total": total,
            "limit": len(rows),
            "offset": 0,
            "start_epoch": min(start_epoch, end_epoch),
            "end_epoch": max(start_epoch, end_epoch),
            "history": rows,
        }

    normalized_limit = _limit(limit)
    normalized_offset = _offset(offset)
    rows = await history.get_consensus_validator_power_epochs(
        normalized_limit,
        normalized_offset,
        include_validators=include_validators,
    )
    total = await history.count_consensus_validator_power_epochs()
    return {"total": total, "limit": normalized_limit, "offset": normalized_offset, "history": rows}


@router.get("/history/consensus-validator-power/{epoch}")
async def consensus_validator_power_epoch(epoch: int):
    return await history.get_consensus_validator_power_epoch(epoch)


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


@router.get("/history/users/{address}/power-periods")
async def user_power_period_history(address: str, limit: int = Query(200), offset: int = Query(0)):
    normalized_limit = _limit(limit)
    normalized_offset = _offset(offset)
    rows = await history.get_user_power_period_history(address, normalized_limit, normalized_offset)
    total = await history.count_user_power_period_history(address)
    return {
        "address": address,
        "total": total,
        "limit": normalized_limit,
        "offset": normalized_offset,
        "history": rows,
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
