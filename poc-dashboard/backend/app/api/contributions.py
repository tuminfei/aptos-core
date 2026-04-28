from fastapi import APIRouter, Query

from app.models import contribution_event
from app.services.cache_svc import get_or_set

router = APIRouter(tags=["contributions"])


def _limit(value: int) -> int:
    return max(1, min(value, 200))


def _offset(value: int) -> int:
    return max(0, value)


@router.get("/contributions")
async def list_contributions(
    contributor: str | None = None,
    app_admin: str | None = None,
    limit: int = Query(50),
    offset: int = Query(0),
):
    normalized_limit = _limit(limit)
    normalized_offset = _offset(offset)
    if app_admin:
        cache_key = (
            f"contribution:app:{app_admin.lower()}:user:{(contributor or '').lower()}:"
            f"limit:{normalized_limit}:offset:{normalized_offset}"
        )
    elif contributor:
        cache_key = f"contribution:user:{contributor.lower()}:limit:{normalized_limit}:offset:{normalized_offset}"
    else:
        cache_key = f"contribution:all:limit:{normalized_limit}:offset:{normalized_offset}"
    return await get_or_set(
        cache_key,
        lambda: _list_contributions_uncached(
            contributor=contributor,
            app_admin=app_admin,
            limit=normalized_limit,
            offset=normalized_offset,
        ),
        ttl_secs=5.0,
    )


async def _list_contributions_uncached(
    *,
    contributor: str | None,
    app_admin: str | None,
    limit: int,
    offset: int,
):
    total = await contribution_event.count_events(contributor=contributor, app_admin=app_admin)
    events = await contribution_event.get_events(
        contributor=contributor,
        app_admin=app_admin,
        limit=limit,
        offset=offset,
    )
    total_equity = await contribution_event.sum_equity_amount(contributor=contributor, app_admin=app_admin)
    return {
        "total": total,
        "limit": limit,
        "offset": offset,
        "total_equity_amount": total_equity,
        "events": events,
    }
