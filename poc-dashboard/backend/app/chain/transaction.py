import time
from app.chain.client import ChainClient, ChainError
from app.chain.keys import Ed25519Key


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
