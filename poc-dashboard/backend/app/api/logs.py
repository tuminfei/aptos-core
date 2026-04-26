from fastapi import APIRouter, Query
from app.models import operation_log

router = APIRouter(tags=["logs"])


@router.get("/logs")
async def list_logs(
    action: str = Query(None),
    status: str = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
):
    total, logs = await operation_log.get_logs(action, status, page, page_size)
    return {"total": total, "logs": logs}
