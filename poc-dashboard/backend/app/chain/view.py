from app.chain.client import ChainClient
from typing import Any


# --- block ---

async def get_epoch_interval_secs(client: ChainClient) -> int:
    r = await client.call_view("0x1::block::get_epoch_interval_secs")
    return int(r[0])


# --- poc_power_store ---

async def get_current_period(client: ChainClient) -> int:
    r = await client.call_view("0x1::poc_power_store::get_current_period")
    return int(r[0])


async def get_power_period_in_epochs(client: ChainClient) -> int:
    r = await client.call_view("0x1::poc_power_store::get_power_period_in_epochs")
    return int(r[0])


async def get_retention_bps(client: ChainClient) -> int:
    r = await client.call_view("0x1::poc_power_store::get_retention_bps_per_period")
    return int(r[0])


async def get_power_operator(client: ChainClient) -> str:
    r = await client.call_view("0x1::poc_power_store::get_operator")
    return r[0]


async def get_user_committed_power(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::poc_power_store::get_user_committed_power", args=[address])
    return int(r[0])


async def get_user_committed_powers(client: ChainClient, addresses: list[str]) -> list[int]:
    r = await client.call_view("0x1::poc_power_store::get_user_committed_powers", args=[addresses])
    return [int(x) for x in r[0]]


async def get_user_power_for_period(client: ChainClient, address: str, period: int) -> int:
    r = await client.call_view("0x1::poc_power_store::get_user_power_for_period", args=[address, str(period)])
    return int(r[0])


async def get_user_powers_for_period(client: ChainClient, addresses: list[str], period: int) -> list[int]:
    if not addresses:
        return []
    r = await client.call_view("0x1::poc_power_store::get_user_powers_for_period", args=[addresses, str(period)])
    return [int(x) for x in r[0]]


async def get_user_power_for_next_epoch(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::poc_power_store::get_user_committed_power_for_next_epoch", args=[address])
    return int(r[0])


async def get_user_power_version(client: ChainClient, address: str) -> dict:
    r = await client.call_view("0x1::poc_power_store::get_user_power_version", args=[address])
    return {
        "older_period": int(r[0]), "older_power": int(r[1]),
        "newer_period": int(r[2]), "newer_power": int(r[3]),
        "committed_power": int(r[4]),
    }


async def get_user_power_versions(client: ChainClient, addresses: list[str]) -> list[dict]:
    r = await client.call_view("0x1::poc_power_store::get_user_power_versions_by_addresses", args=[addresses])
    results = []
    users = r[0]
    for i in range(len(users)):
        results.append({
            "user": users[i],
            "older_period": int(r[1][i]), "older_power": int(r[2][i]),
            "newer_period": int(r[3][i]), "newer_power": int(r[4][i]),
            "committed_power": int(r[5][i]),
        })
    return results


# --- staking_registry ---

async def get_user_stake_info(client: ChainClient, address: str) -> dict:
    r = await client.call_view("0x1::staking_registry::get_user_stake_info", args=[address])
    return {"deposit": int(r[0]), "delegated_to": r[1], "cooldown_until_secs": int(r[2])}


async def get_effective_power(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::staking_registry::get_effective_power", args=[address])
    return int(r[0])


async def get_validator_total_power(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::staking_registry::get_validator_total_power", args=[address])
    return int(r[0])


async def get_validator_joining_power(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::staking_registry::get_validator_joining_power", args=[address])
    return int(r[0])


async def get_total_staked_power(client: ChainClient) -> int:
    r = await client.call_view("0x1::staking_registry::get_total_staked_power")
    return int(r[0])


async def get_validator_commission_bps(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::staking_registry::get_validator_commission_bps", args=[address])
    return int(r[0])


async def get_pending_transaction_fees(client: ChainClient) -> list[int]:
    r = await client.call_view("0x1::stake::get_pending_transaction_fee")
    return [int(x) for x in r[0]]


async def get_reward_rate(client: ChainClient) -> dict:
    r = await client.call_view("0x1::staking_config::reward_rate")
    numerator = int(r[0])
    denominator = int(r[1])
    return {
        "numerator": numerator,
        "denominator": denominator,
        "bps": (numerator * 10000 // denominator) if denominator else 0,
    }


async def get_cooldown_secs(client: ChainClient) -> int:
    r = await client.call_view("0x1::staking_registry::get_cooldown_secs")
    return int(r[0])


async def get_octas_per_power(client: ChainClient) -> int:
    r = await client.call_view("0x1::staking_registry::get_octas_per_power")
    return int(r[0])


async def validator_exists(client: ChainClient, address: str) -> bool:
    r = await client.call_view("0x1::staking_registry::validator_exists", args=[address])
    return r[0]


async def get_validator_view(client: ChainClient, address: str) -> dict:
    r = await client.call_view("0x1::staking_registry::get_validator_view", args=[address])
    return {
        "validator": r[0], "owner": r[1], "commission_bps": int(r[2]),
        "status": int(r[3]), "delegator_count": int(r[4]),
        "joining_power": int(r[5]), "total_power": int(r[6]),
    }


async def get_validator_views(client: ChainClient, addresses: list[str]) -> list[dict]:
    if not addresses:
        return []
    r = await client.call_view("0x1::staking_registry::get_validator_views_by_addresses", args=[addresses])
    results = []
    for i in range(len(r[0])):
        results.append({
            "validator": r[0][i], "owner": r[1][i], "commission_bps": int(r[2][i]),
            "status": int(r[3][i]), "delegator_count": int(r[4][i]),
            "joining_power": int(r[5][i]), "total_power": int(r[6][i]),
        })
    return results


async def get_user_stake_view(client: ChainClient, address: str) -> dict:
    r = await client.call_view("0x1::staking_registry::get_user_stake_view", args=[address])
    return {
        "user": r[0], "deposit_octas": int(r[1]), "delegated_to": r[2],
        "cooldown_until_secs": int(r[3]), "committed_power": int(r[4]),
        "effective_power": int(r[5]),
    }


async def get_user_stake_views(client: ChainClient, addresses: list[str]) -> list[dict]:
    if not addresses:
        return []
    r = await client.call_view("0x1::staking_registry::get_user_stake_views_by_addresses", args=[addresses])
    results = []
    for i in range(len(r[0])):
        results.append({
            "user": r[0][i], "deposit_octas": int(r[1][i]), "delegated_to": r[2][i],
            "cooldown_until_secs": int(r[3][i]), "committed_power": int(r[4][i]),
            "effective_power": int(r[5][i]),
        })
    return results


async def get_validator_delegator_count(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::staking_registry::get_validator_delegator_count", args=[address])
    return int(r[0])


async def get_validator_delegators(client: ChainClient, address: str, offset: int, limit: int) -> list[str]:
    r = await client.call_view("0x1::staking_registry::get_validator_delegators",
                               args=[address, str(offset), str(limit)])
    return r[0]


async def get_validator_delegator_views(client: ChainClient, address: str, offset: int, limit: int) -> list[dict]:
    r = await client.call_view("0x1::staking_registry::get_validator_delegator_views",
                               args=[address, str(offset), str(limit)])
    results = []
    for i in range(len(r[0])):
        results.append({
            "delegator": r[0][i], "deposit_octas": int(r[1][i]),
            "committed_power": int(r[2][i]), "effective_power": int(r[3][i]),
        })
    return results


# --- stake ---

async def get_validator_state(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::stake::get_validator_state", args=[address])
    return int(r[0])


async def get_current_epoch_voting_power(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::stake::get_current_epoch_voting_power", args=[address])
    return int(r[0])


async def get_stake(client: ChainClient, address: str) -> dict:
    r = await client.call_view("0x1::stake::get_stake", args=[address])
    return {
        "active": int(r[0]), "inactive": int(r[1]),
        "pending_active": int(r[2]), "pending_inactive": int(r[3]),
    }


async def get_operator(client: ChainClient, address: str) -> str:
    r = await client.call_view("0x1::stake::get_operator", args=[address])
    return r[0]


async def get_validator_index(client: ChainClient, address: str) -> int:
    r = await client.call_view("0x1::stake::get_validator_index", args=[address])
    return int(r[0])


async def get_proposal_counts(client: ChainClient, index: int) -> dict:
    r = await client.call_view("0x1::stake::get_current_epoch_proposal_counts", args=[str(index)])
    return {"successful": int(r[0]), "failed": int(r[1])}


async def get_validator_config(client: ChainClient, address: str) -> dict:
    r = await client.call_view("0x1::stake::get_validator_config", args=[address])
    return {"consensus_pubkey": r[0], "network_addresses": r[1], "fullnode_addresses": r[2]}


async def is_current_epoch_validator(client: ChainClient, address: str) -> bool:
    r = await client.call_view("0x1::stake::is_current_epoch_validator", args=[address])
    return r[0]


async def stake_pool_exists(client: ChainClient, address: str) -> bool:
    r = await client.call_view("0x1::stake::stake_pool_exists", args=[address])
    return r[0]


async def get_active_validator_count(client: ChainClient) -> int:
    r = await client.call_view("0x1::stake::get_active_validator_count")
    return int(r[0])


async def get_pending_active_validator_count(client: ChainClient) -> int:
    r = await client.call_view("0x1::stake::get_pending_active_validator_count")
    return int(r[0])


async def get_pending_inactive_validator_count(client: ChainClient) -> int:
    r = await client.call_view("0x1::stake::get_pending_inactive_validator_count")
    return int(r[0])


async def get_active_validators(client: ChainClient, offset: int = 0, limit: int = 100) -> list[str]:
    r = await client.call_view("0x1::stake::get_active_validators", args=[str(offset), str(limit)])
    return r[0]


async def get_pending_active_validators(client: ChainClient, offset: int = 0, limit: int = 100) -> list[str]:
    r = await client.call_view("0x1::stake::get_pending_active_validators", args=[str(offset), str(limit)])
    return r[0]


async def get_pending_inactive_validators(client: ChainClient, offset: int = 0, limit: int = 100) -> list[str]:
    r = await client.call_view("0x1::stake::get_pending_inactive_validators", args=[str(offset), str(limit)])
    return r[0]


# --- topo_governance ---

async def get_voting_duration_secs(client: ChainClient) -> int:
    r = await client.call_view("0x1::topo_governance::get_voting_duration_secs")
    return int(r[0])


async def get_min_voting_threshold(client: ChainClient) -> int:
    r = await client.call_view("0x1::topo_governance::get_min_voting_threshold")
    return int(r[0])


async def get_required_proposer_stake(client: ChainClient) -> int:
    r = await client.call_view("0x1::topo_governance::get_required_proposer_stake")
    return int(r[0])


# --- poc_registry ---

async def get_app_info(client: ChainClient, admin: str) -> dict:
    r = await client.call_view("0x1::poc_registry::get_app_info", args=[admin])
    return r[0] if r else {}


async def get_app_infos_by_admins(client: ChainClient, admins: list[str]) -> list[dict]:
    if not admins:
        return []
    r = await client.call_view("0x1::poc_registry::get_app_infos_by_admins", args=[admins])
    return r[0] if r else []


async def exists_apps(client: ChainClient, admins: list[str]) -> list[bool]:
    if not admins:
        return []
    r = await client.call_view("0x1::poc_registry::exists_apps", args=[admins])
    return r[0]


async def get_app_state(client: ChainClient, admin: str) -> int:
    r = await client.call_view("0x1::poc_registry::get_app_state", args=[admin])
    return int(r[0])


async def get_poc_listing_status(client: ChainClient, admin: str) -> int:
    r = await client.call_view("0x1::poc_registry::get_poc_listing_status", args=[admin])
    return int(r[0])


async def get_effective_weight_pbs(client: ChainClient, admin: str) -> int:
    r = await client.call_view("0x1::poc_registry::get_effective_weight_pbs", args=[admin])
    return int(r[0])


async def is_app_eligible_for_poc(client: ChainClient, admin: str) -> bool:
    r = await client.call_view("0x1::poc_registry::is_app_eligible_for_poc", args=[admin])
    return bool(r[0])


# --- poc_demo test app ---

async def demo_exists_app(client: ChainClient, module_address: str, admin: str) -> bool:
    r = await client.call_view(f"{module_address}::poc_demo::exists_app", args=[admin])
    return bool(r[0])


async def demo_price_per_equity(client: ChainClient, module_address: str, admin: str) -> int:
    r = await client.call_view(f"{module_address}::poc_demo::price_per_equity", args=[admin])
    return int(r[0])


async def demo_trade_count(client: ChainClient, module_address: str, admin: str) -> int:
    r = await client.call_view(f"{module_address}::poc_demo::trade_count", args=[admin])
    return int(r[0])


async def demo_total_equity_sold(client: ChainClient, module_address: str, admin: str) -> int:
    r = await client.call_view(f"{module_address}::poc_demo::total_equity_sold", args=[admin])
    return int(r[0])


async def demo_custody_inventory(client: ChainClient, module_address: str, admin: str) -> int:
    r = await client.call_view(f"{module_address}::poc_demo::custody_inventory", args=[admin])
    return int(r[0])


async def demo_expected_payment(client: ChainClient, module_address: str, admin: str, equity_amount: int) -> int:
    r = await client.call_view(
        f"{module_address}::poc_demo::expected_payment",
        args=[admin, str(equity_amount)],
    )
    return int(r[0])


async def demo_user_equity_balance(client: ChainClient, module_address: str, admin: str, user: str) -> int:
    r = await client.call_view(
        f"{module_address}::poc_demo::user_equity_balance",
        args=[admin, user],
    )
    return int(r[0])


# --- balance ---

async def get_topo_balance(client: ChainClient, address: str) -> int:
    try:
        r = await client.call_view(
            "0x1::coin::balance",
            type_args=["0x1::topo_coin::TopoCoin"],
            args=[address],
        )
        return int(r[0])
    except Exception:
        resource = await client.get_account_resource(
            address, "0x1::coin::CoinStore<0x1::topo_coin::TopoCoin>"
        )
        if resource is None:
            return 0
        return int(resource["data"]["coin"]["value"])
