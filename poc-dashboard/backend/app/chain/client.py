import httpx
from typing import Any


class ChainError(Exception):
    def __init__(self, message: str, status_code: int = 500):
        self.message = message
        self.status_code = status_code
        super().__init__(message)


class ChainClient:
    def __init__(self, base_url: str, timeout: float = 30.0):
        self.base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(base_url=self.base_url, timeout=timeout)

    async def close(self):
        await self._client.aclose()

    async def get_ledger_info(self) -> dict:
        resp = await self._client.get("/")
        resp.raise_for_status()
        return resp.json()

    async def get_account(self, address: str) -> dict:
        resp = await self._client.get(f"/accounts/{address}")
        resp.raise_for_status()
        return resp.json()

    async def account_exists(self, address: str) -> bool:
        resp = await self._client.get(f"/accounts/{address}")
        if resp.status_code == 404:
            return False
        resp.raise_for_status()
        return True

    async def get_account_resource(self, address: str, resource_type: str) -> dict | None:
        resp = await self._client.get(f"/accounts/{address}/resource/{resource_type}")
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json()

    async def call_view(self, function_id: str, type_args: list | None = None, args: list | None = None) -> list:
        payload = {
            "function": function_id,
            "type_arguments": type_args or [],
            "arguments": args or [],
        }
        resp = await self._client.post("/view", json=payload)
        if resp.status_code != 200:
            raise ChainError(f"View call failed: {function_id} - {resp.text}", resp.status_code)
        return resp.json()

    async def get_account_sequence_number(self, address: str) -> int:
        account = await self.get_account(address)
        return int(account["sequence_number"])

    async def encode_submission(self, raw_txn: dict) -> bytes:
        resp = await self._client.post("/transactions/encode_submission", json=raw_txn)
        resp.raise_for_status()
        return bytes.fromhex(resp.json().removeprefix("0x"))

    async def submit_transaction(self, signed_txn: dict) -> dict:
        resp = await self._client.post("/transactions", json=signed_txn)
        if resp.status_code not in (200, 202):
            raise ChainError(f"Transaction submit failed: {resp.text}", resp.status_code)
        return resp.json()

    async def wait_for_transaction(self, tx_hash: str, timeout_secs: int = 180) -> dict:
        import asyncio
        for _ in range(timeout_secs * 2):
            resp = await self._client.get(f"/transactions/by_hash/{tx_hash}")
            if resp.status_code == 200:
                data = resp.json()
                if data.get("type") != "pending_transaction":
                    return data
            await asyncio.sleep(0.5)
        raise ChainError(f"Transaction {tx_hash} not confirmed within {timeout_secs}s")

    async def get_events(self, address: str, event_handle: str, field_name: str,
                         start: int = 0, limit: int = 25) -> list:
        resp = await self._client.get(
            f"/accounts/{address}/events/{event_handle}/{field_name}",
            params={"start": start, "limit": limit},
        )
        if resp.status_code == 404:
            return []
        resp.raise_for_status()
        return resp.json()


_chain_client: ChainClient | None = None


def get_chain_client() -> ChainClient:
    global _chain_client
    if _chain_client is None:
        from app.config import get_settings
        settings = get_settings()
        _chain_client = ChainClient(settings.chain.rest_url)
    return _chain_client


async def close_chain_client():
    global _chain_client
    if _chain_client:
        await _chain_client.close()
        _chain_client = None
