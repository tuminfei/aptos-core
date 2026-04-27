from app.chain.client import ChainClient
from app.chain.transaction import submit_entry_function
from app.chain.keys import Ed25519Key
from app.models import operation_log


USER_MAX_GAS = 200_000


async def proxy_stake(
    client: ChainClient,
    core_key: Ed25519Key,
    core_address: str,
    user_key: Ed25519Key,
    user_address: str,
    mint_amount: int,
    power: int,
    deposit_amount: int,
    delegate_to: str,
    force_epoch: bool = False,
    force_epochs: int = 0,
) -> dict:
    steps = []

    async def run_step(name, fn):
        try:
            tx = await fn()
            steps.append({"step": name, "status": "success", "tx_hash": tx})
            await operation_log.create_log(name, user_address, None, tx, "success")
            return True
        except Exception as e:
            steps.append({"step": name, "status": "failed", "error": str(e)})
            await operation_log.create_log(name, user_address, None, None, "failed", str(e))
            return False

    # Step 1: create account on chain
    if not await client.account_exists(user_address):
        ok = await run_step("create_account", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_account::create_account",
            args=[user_address],
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}
    else:
        steps.append({"step": "create_account", "status": "skipped", "reason": "account_exists"})

    # Step 2: mint TOPO
    ok = await run_step("mint_topo", lambda: submit_entry_function(
        client, core_key, core_address,
        "0x1::topo_coin::mint",
        args=[user_address, str(mint_amount)],
    ))
    if not ok:
        return {"steps": steps, "final_status": "failed"}

    # Step 3: stage power
    ok = await run_step("stage_power", lambda: submit_entry_function(
        client, core_key, core_address,
        "0x1::topo_governance::stage_power_update_test_only",
        args=[user_address, str(power)],
    ))
    if not ok:
        return {"steps": steps, "final_status": "failed"}

    # Step 4: force epochs if needed
    force_epoch_count = max(force_epochs, 1 if force_epoch else 0)
    for i in range(force_epoch_count):
        ok = await run_step(f"force_end_epoch_{i+1}", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_governance::force_end_epoch_test_only",
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    # Step 5: deposit
    ok = await run_step("deposit", lambda: submit_entry_function(
        client, user_key, user_address,
        "0x1::staking_registry::deposit",
        args=[str(deposit_amount)],
        max_gas=USER_MAX_GAS,
    ))
    if not ok:
        return {"steps": steps, "final_status": "failed"}

    # Step 6: delegate
    ok = await run_step("delegate", lambda: submit_entry_function(
        client, user_key, user_address,
        "0x1::staking_registry::delegate",
        args=[delegate_to],
        max_gas=USER_MAX_GAS,
    ))

    return {"steps": steps, "final_status": "success" if ok else "failed"}
