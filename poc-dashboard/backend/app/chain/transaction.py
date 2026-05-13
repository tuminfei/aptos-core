import asyncio
import time
from app.chain.client import ChainClient, ChainError
from app.chain.keys import Ed25519Key

_sender_locks: dict[tuple[int, str], asyncio.Lock] = {}


def _sender_lock(sender_address: str) -> asyncio.Lock:
    loop = asyncio.get_running_loop()
    key = (id(loop), sender_address.lower())
    lock = _sender_locks.get(key)
    if lock is None:
        lock = asyncio.Lock()
        _sender_locks[key] = lock
    return lock


async def submit_entry_function(
    client: ChainClient,
    sender_key: Ed25519Key,
    sender_address: str,
    function_id: str,
    type_args: list | None = None,
    args: list | None = None,
    max_gas: int = 200000,
    gas_unit_price: int = 100,
) -> str:
    async with _sender_lock(sender_address):
        return await _submit_entry_function_unlocked(
            client,
            sender_key,
            sender_address,
            function_id,
            type_args=type_args,
            args=args,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )


async def _submit_entry_function_unlocked(
    client: ChainClient,
    sender_key: Ed25519Key,
    sender_address: str,
    function_id: str,
    type_args: list | None = None,
    args: list | None = None,
    max_gas: int = 200000,
    gas_unit_price: int = 100,
) -> str:
    seq_num = await client.get_account_sequence_number(sender_address)

    payload = {
        "type": "entry_function_payload",
        "function": function_id,
        "type_arguments": type_args or [],
        "arguments": args or [],
    }

    raw_txn = {
        "sender": sender_address,
        "sequence_number": str(seq_num),
        "max_gas_amount": str(max_gas),
        "gas_unit_price": str(gas_unit_price),
        "expiration_timestamp_secs": str(int(time.time()) + 600),
        "payload": payload,
    }

    signing_message = await client.encode_submission(raw_txn)
    signature = sender_key.sign(signing_message)

    signed_txn = {
        **raw_txn,
        "signature": {
            "type": "ed25519_signature",
            "public_key": sender_key.public_key_hex,
            "signature": "0x" + signature.hex(),
        },
    }

    result = await client.submit_transaction(signed_txn)
    tx_hash = result.get("hash", "")

    confirmed = await client.wait_for_transaction(tx_hash)
    if not confirmed.get("success", False):
        vm_status = confirmed.get("vm_status", "unknown")
        raise ChainError(f"Transaction failed: {vm_status}")

    return tx_hash
