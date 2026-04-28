from fastapi import APIRouter
from pydantic import BaseModel
from app.chain.client import get_chain_client
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import get_key_manager
from app.models import operation_log
from app.services.cache_svc import invalidate_many
from app.api.errors import AmountError, ChainTxError

router = APIRouter(tags=["topo"])
MAX_U64 = 18446744073709551615


class MintReq(BaseModel):
    recipient: str
    amount: int


@router.get("/topo/balance/{address}")
async def balance(address: str):
    client = get_chain_client()
    octas = await view.get_topo_balance(client, address)
    return {"address": address, "balance_octas": octas, "balance_topo": octas / 1e8}


@router.post("/topo/mint")
async def mint(req: MintReq):
    client = get_chain_client()
    km = get_key_manager()
    if req.amount <= 0:
        raise AmountError("铸造金额必须大于 0 octas")

    balance_octas = await view.get_topo_balance(client, req.recipient)
    if req.amount > MAX_U64 - balance_octas:
        remaining = MAX_U64 - balance_octas
        raise AmountError(
            f"铸造后余额会超过 u64 最大值。当前余额 {balance_octas} octas，最多还能铸造 {remaining} octas"
        )

    try:
        tx = await submit_entry_function(
            client, km.core_resources_key, km.core_resources_address,
            "0x1::topo_coin::mint",
            args=[req.recipient, str(req.amount)],
        )
        await operation_log.create_log("mint_topo", req.recipient, {"amount": req.amount}, tx, "success")
        await invalidate_many(f"user:detail:{req.recipient.lower()}")
        return {"tx_hash": tx, "success": True}
    except Exception as e:
        await operation_log.create_log("mint_topo", req.recipient, {"amount": req.amount}, None, "failed", str(e))
        raise ChainTxError(str(e))
