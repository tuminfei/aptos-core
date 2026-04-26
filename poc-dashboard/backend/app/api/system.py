from fastapi import APIRouter
from app.chain.client import get_chain_client, ChainError
from app.api.errors import ChainUnreachable

router = APIRouter(tags=["system"])


@router.get("/system/health")
async def health():
    client = get_chain_client()
    try:
        info = await client.get_ledger_info()
        return {
            "status": "ok",
            "chain_connected": True,
            "chain_url": client.base_url,
            "epoch": int(info.get("epoch", 0)),
        }
    except Exception:
        return {"status": "degraded", "chain_connected": False, "chain_url": client.base_url}


@router.get("/system/chain-info")
async def chain_info():
    client = get_chain_client()
    try:
        info = await client.get_ledger_info()
        return {
            "chain_id": int(info.get("chain_id", 0)),
            "epoch": int(info.get("epoch", 0)),
            "ledger_version": int(info.get("ledger_version", 0)),
            "ledger_timestamp": info.get("ledger_timestamp", ""),
            "block_height": int(info.get("block_height", 0)),
        }
    except Exception as e:
        raise ChainUnreachable(str(e))
