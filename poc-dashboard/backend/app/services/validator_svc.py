import asyncio
import os
import subprocess
from pathlib import Path
import yaml

from app.chain.client import ChainClient
from app.chain import view
from app.chain.transaction import submit_entry_function
from app.chain.keys import Ed25519Key
from app.models import operation_log
from app.services import rewards_svc


VALIDATOR_STATUS_MAP = {1: "pending_active", 2: "active", 3: "pending_inactive", 4: "inactive"}
DEFAULT_MAX_GAS = 200_000
DEFAULT_GAS_UNIT_PRICE = 100


async def get_validators(client: ChainClient, status: str = "all") -> list[dict]:
    results = []
    reward_context = await rewards_svc.get_reward_context(client)

    if status in ("all", "active"):
        addrs = await view.get_active_validators(client, 0, 200)
        for addr in addrs:
            v = await _build_validator_summary(client, addr, reward_context)
            results.append(v)

    if status in ("all", "pending_active"):
        addrs = await view.get_pending_active_validators(client, 0, 200)
        for addr in addrs:
            v = await _build_validator_summary(client, addr, reward_context)
            results.append(v)

    if status in ("all", "pending_inactive"):
        addrs = await view.get_pending_inactive_validators(client, 0, 200)
        for addr in addrs:
            v = await _build_validator_summary(client, addr, reward_context)
            results.append(v)

    return results


async def _build_validator_summary(client: ChainClient, addr: str, reward_context: dict | None = None) -> dict:
    state = await view.get_validator_state(client, addr)
    vp = await view.get_current_epoch_voting_power(client, addr)
    stake_info = await view.get_stake(client, addr)
    operator = await view.get_operator(client, addr)

    try:
        sr_view = await view.get_validator_view(client, addr)
        commission_bps = sr_view["commission_bps"]
        delegator_count = sr_view["delegator_count"]
        total_pool_power = sr_view["total_power"]
    except Exception:
        commission_bps = delegator_count = total_pool_power = 0

    idx = -1
    proposals_successful = proposals_failed = 0
    proposals = {"successful": 0, "failed": 0}
    try:
        idx = await view.get_validator_index(client, addr)
        proposals = await view.get_proposal_counts(client, idx)
        proposals_successful = proposals["successful"]
        proposals_failed = proposals["failed"]
    except Exception:
        pass

    total = proposals_successful + proposals_failed
    success_rate = proposals_successful / total if total > 0 else 0
    rewards = await rewards_svc.estimate_validator_rewards(
        client,
        addr,
        idx,
        total_pool_power,
        commission_bps,
        proposals=proposals,
        context=reward_context,
    )

    return {
        "address": addr,
        "operator": operator,
        "status": VALIDATOR_STATUS_MAP.get(state, "unknown"),
        "status_code": state,
        "voting_power": vp,
        "commission_bps": commission_bps,
        "delegator_count": delegator_count,
        "total_pool_power": total_pool_power,
        "stake": stake_info,
        "proposals_successful": proposals_successful,
        "proposals_failed": proposals_failed,
        "success_rate": round(success_rate, 3),
        "rewards": {
            "auto_compound": rewards["auto_compound"],
            "reward_rate": rewards["reward_rate"],
            "pending_fee_octas": rewards["pending_fee_octas"],
            "estimated_epoch_reward_octas": rewards["estimated_epoch_reward_octas"],
            "estimated_epoch_fee_octas": rewards["estimated_epoch_fee_octas"],
            "estimated_epoch_total_octas": rewards["estimated_epoch_total_octas"],
            "estimated_commission_octas": rewards["estimated_commission_octas"],
            "estimated_delegator_octas": rewards["estimated_delegator_octas"],
        },
    }


async def get_validator_detail(client: ChainClient, address: str) -> dict:
    state = await view.get_validator_state(client, address)
    vp = await _optional_view(view.get_current_epoch_voting_power(client, address), 0)
    stake_info = await _optional_view(
        view.get_stake(client, address),
        {"active": 0, "inactive": 0, "pending_active": 0, "pending_inactive": 0},
    )
    operator = await _optional_view(view.get_operator(client, address), address)
    idx = await _optional_view(view.get_validator_index(client, address), -1)
    config = await _optional_view(
        view.get_validator_config(client, address),
        {"consensus_pubkey": "", "network_addresses": "", "fullnode_addresses": ""},
    )
    is_current = state == 2
    proposals = {"successful": 0, "failed": 0}
    if idx >= 0:
        proposals = await _optional_view(view.get_proposal_counts(client, idx), proposals)

    try:
        sr_view = await view.get_validator_view(client, address)
        commission_bps = sr_view["commission_bps"]
        total_pool_power = sr_view["total_power"]
        owner_address = sr_view["owner"]
    except Exception:
        commission_bps = total_pool_power = 0
        owner_address = address

    delegators = []
    try:
        dc = await view.get_validator_delegator_count(client, address)
        if dc > 0:
            dv = await view.get_validator_delegator_views(client, address, 0, min(dc, 100))
            for d in dv:
                delegators.append({
                    "address": d["delegator"],
                    "deposit": d["deposit_octas"],
                    "deposit_topo": d["deposit_octas"] / 1e8,
                    "poc_power": d["committed_power"],
                    "effective_power": d["effective_power"],
                })
    except Exception:
        dc = 0
    rewards = await rewards_svc.estimate_validator_rewards(
        client,
        address,
        idx,
        total_pool_power,
        commission_bps,
        proposals=proposals,
        members=delegators,
        owner_address=owner_address,
    )
    for delegator in delegators:
        estimate = rewards["member_estimates"].get(delegator["address"].lower(), {})
        delegator["estimated_epoch_reward_octas"] = estimate.get("estimated_epoch_reward_octas", 0)
        delegator["estimated_epoch_fee_octas"] = estimate.get("estimated_epoch_fee_octas", 0)
        delegator["estimated_epoch_total_octas"] = estimate.get("estimated_epoch_total_octas", 0)

    return {
        "address": address,
        "operator": operator,
        "status": VALIDATOR_STATUS_MAP.get(state, "unknown"),
        "voting_power": vp,
        "commission_bps": commission_bps,
        "validator_index": idx,
        "consensus_pubkey": config["consensus_pubkey"],
        "is_current_epoch_validator": is_current,
        "pool": {
            "total_power": total_pool_power,
            "delegators": delegators,
        },
        "stake": stake_info,
        "proposals_successful": proposals["successful"],
        "proposals_failed": proposals["failed"],
        "rewards": rewards,
    }


async def _optional_view(awaitable, default):
    try:
        return await awaitable
    except Exception:
        return default


async def prepare_join(
    client: ChainClient,
    core_key: Ed25519Key,
    core_address: str,
    validator_key: Ed25519Key,
    validator_address: str,
    operator_key: Ed25519Key,
    operator_address: str,
    power: int,
    set_power_period: int,
    force_epochs: int,
    mint_amount: int,
    deposit_amount: int,
    commission_bps: int,
    cluster_dir: str = "",
    force_epochs_after_join: int = 1,
) -> dict:
    steps = []
    operator_config_file = _find_operator_config(cluster_dir, validator_address)

    async def run_step(name, fn):
        try:
            tx = await fn()
            steps.append({"step": name, "status": "success", "tx_hash": tx})
            await operation_log.create_log(name, validator_address, None, tx, "success")
            return True
        except Exception as e:
            steps.append({"step": name, "status": "failed", "error": str(e)})
            await operation_log.create_log(name, validator_address, None, None, "failed", str(e))
            return False

    if not await client.account_exists(validator_address):
        ok = await run_step("create_account", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_account::create_account",
            args=[validator_address],
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}
    else:
        steps.append({"step": "create_account", "status": "skipped", "reason": "account_exists"})

    if mint_amount > 0:
        ok = await run_step("mint_topo", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_coin::mint",
            args=[validator_address, str(mint_amount)],
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    if set_power_period > 0:
        ok = await run_step("set_power_period", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_governance::set_power_period_in_epochs_test_only",
            args=[str(set_power_period)],
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}
        ok = await run_step("force_end_epoch_after_set_power_period", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_governance::force_end_epoch_test_only",
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    ok = await run_step("stage_power", lambda: submit_entry_function(
        client, core_key, core_address,
        "0x1::topo_governance::stage_power_update_test_only",
        args=[validator_address, str(power)],
    ))
    if not ok:
        return {"steps": steps, "final_status": "failed"}

    for i in range(force_epochs):
        ok = await run_step(f"force_end_epoch_{i+1}", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_governance::force_end_epoch_test_only",
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    if operator_config_file:
        ok = await run_step(
            "initialize_validator",
            lambda: initialize_validator_with_cli(
                operator_config_file=operator_config_file,
                validator_key=validator_key,
                rest_url=client.base_url,
            ),
        )
        if not ok:
            return {"steps": steps, "final_status": "failed"}
    else:
        ok = await run_step("initialize_stake_owner", lambda: submit_entry_function(
            client, validator_key, validator_address,
            "0x1::stake::initialize_stake_owner",
            args=["0", validator_address],
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    if commission_bps:
        steps.append({"step": "register_validator", "status": "skipped", "reason": "registered_by_stake_initialize"})

    if deposit_amount > 0:
        ok = await run_step("deposit", lambda: submit_entry_function(
            client, validator_key, validator_address,
            "0x1::staking_registry::deposit",
            args=[str(deposit_amount)],
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    ok = await run_step("delegate_self", lambda: submit_entry_function(
        client, validator_key, validator_address,
        "0x1::staking_registry::delegate",
        args=[validator_address],
    ))
    if not ok:
        return {"steps": steps, "final_status": "failed"}

    ok = await run_step("join_validator_set", lambda: submit_entry_function(
        client, validator_key, validator_address,
        "0x1::stake::join_validator_set",
        args=[validator_address],
    ))
    if not ok:
        return {"steps": steps, "final_status": "failed"}

    for i in range(force_epochs_after_join):
        ok = await run_step(f"force_end_epoch_after_join_{i+1}", lambda: submit_entry_function(
            client, core_key, core_address,
            "0x1::topo_governance::force_end_epoch_test_only",
        ))
        if not ok:
            return {"steps": steps, "final_status": "failed"}

    return {"steps": steps, "final_status": "success"}


def _find_operator_config(cluster_dir: str, validator_address: str) -> Path | None:
    if not cluster_dir:
        return None
    workspace = Path(cluster_dir) / "genesis-workspace"
    if not workspace.is_dir():
        return None
    target = validator_address.lower().removeprefix("0x")
    for owner_path in sorted(workspace.glob("validator-*/owner.yaml")):
        try:
            with owner_path.open() as f:
                owner = yaml.safe_load(f) or {}
        except Exception:
            continue
        owner_addr = str(owner.get("owner_account_address", "")).lower().removeprefix("0x")
        if owner_addr == target:
            operator_path = owner_path.with_name("operator.yaml")
            return operator_path if operator_path.exists() else None
    return None


async def initialize_validator_with_cli(
    *,
    operator_config_file: Path,
    validator_key: Ed25519Key,
    rest_url: str,
) -> str:
    repo_root = _repo_root()
    aptos_cli = _aptos_cli(repo_root)
    cmd = [
        *aptos_cli,
        "node",
        "initialize-validator",
        "--operator-config-file",
        str(operator_config_file),
        "--url",
        rest_url,
        "--private-key",
        validator_key.private_key_hex,
        "--assume-yes",
        "--max-gas",
        str(DEFAULT_MAX_GAS),
        "--gas-unit-price",
        str(DEFAULT_GAS_UNIT_PRICE),
    ]
    proc = await asyncio.to_thread(
        subprocess.run,
        cmd,
        cwd=repo_root,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip())
    return _extract_tx_hash(proc.stdout) or "cli:initialize-validator"


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _aptos_cli(repo_root: Path) -> list[str]:
    for candidate in (
        repo_root / "target" / "release" / "aptos",
        repo_root / "target" / "debug" / "aptos",
    ):
        if candidate.exists():
            return [str(candidate)]
    return ["cargo", "run", "-p", "aptos", "--"]


def _extract_tx_hash(output: str) -> str:
    for token in output.replace('"', " ").replace("'", " ").split():
        if token.startswith("0x") and len(token) == 66:
            return token
    return ""
