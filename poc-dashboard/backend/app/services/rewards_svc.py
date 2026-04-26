from app.chain import view
from app.chain.client import ChainClient


BPS_DENOMINATOR = 10_000
ZERO_ADDRESS = "0x0"


def estimate_epoch_reward(
    pool_power: int,
    successful_proposals: int,
    failed_proposals: int,
    reward_rate: dict,
) -> int:
    total_proposals = successful_proposals + failed_proposals
    numerator = int(reward_rate.get("numerator", 0))
    denominator = int(reward_rate.get("denominator", 0))
    if pool_power <= 0 or successful_proposals <= 0 or total_proposals <= 0 or numerator <= 0 or denominator <= 0:
        return 0
    return (pool_power * numerator * successful_proposals) // (denominator * total_proposals)


def split_pool_amount(
    amount_octas: int,
    commission_bps: int,
    total_power: int,
    members: list[dict] | None = None,
    owner_address: str = "",
) -> dict:
    commission_octas = (amount_octas * commission_bps) // BPS_DENOMINATOR if amount_octas > 0 else 0
    distributable_octas = amount_octas - commission_octas
    result = {
        "commission_octas": commission_octas,
        "delegator_octas": distributable_octas,
        "owner_extra_octas": commission_octas,
        "member_octas": {},
    }
    if not members or total_power <= 0 or amount_octas <= 0:
        return result

    distributed = 0
    member_octas: dict[str, int] = {}
    for member in members:
        member_power = int(member.get("effective_power", 0) or 0)
        if member_power <= 0:
            continue
        member_address = str(member.get("address") or member.get("delegator") or "")
        member_share = (distributable_octas * member_power) // total_power
        if member_share > 0:
            member_octas[member_address.lower()] = member_share
        distributed += member_share

    dust_octas = distributable_octas - distributed
    owner_extra_octas = commission_octas + dust_octas
    if owner_address and owner_extra_octas > 0:
        owner_key = owner_address.lower()
        member_octas[owner_key] = member_octas.get(owner_key, 0) + owner_extra_octas

    result["owner_extra_octas"] = owner_extra_octas
    result["member_octas"] = member_octas
    return result


async def get_reward_context(client: ChainClient) -> dict:
    try:
        reward_rate = await view.get_reward_rate(client)
    except Exception:
        reward_rate = {"numerator": 0, "denominator": 0, "bps": 0}
    try:
        pending_fees = await view.get_pending_transaction_fees(client)
    except Exception:
        pending_fees = []
    return {"reward_rate": reward_rate, "pending_fees": pending_fees}


def pending_fee_for_validator(context: dict, validator_index: int) -> int:
    pending_fees = context.get("pending_fees") or []
    if validator_index < 0 or validator_index >= len(pending_fees):
        return 0
    return int(pending_fees[validator_index])


async def estimate_validator_rewards(
    client: ChainClient,
    validator_address: str,
    validator_index: int,
    total_power: int,
    commission_bps: int,
    proposals: dict | None = None,
    members: list[dict] | None = None,
    owner_address: str = "",
    context: dict | None = None,
) -> dict:
    context = context or await get_reward_context(client)
    reward_rate = context["reward_rate"]
    if proposals is None:
        try:
            proposals = await view.get_proposal_counts(client, validator_index)
        except Exception:
            proposals = {"successful": 0, "failed": 0}

    successful = int(proposals.get("successful", 0) or 0)
    failed = int(proposals.get("failed", 0) or 0)
    reward_octas = estimate_epoch_reward(total_power, successful, failed, reward_rate)
    fee_octas = pending_fee_for_validator(context, validator_index)

    reward_split = split_pool_amount(reward_octas, commission_bps, total_power, members, owner_address)
    fee_split = split_pool_amount(fee_octas, commission_bps, total_power, members, owner_address)

    member_estimates: dict[str, dict] = {}
    for member in members or []:
        member_address = str(member.get("address") or member.get("delegator") or "").lower()
        member_reward = reward_split["member_octas"].get(member_address, 0)
        member_fee = fee_split["member_octas"].get(member_address, 0)
        member_estimates[member_address] = {
            "estimated_epoch_reward_octas": member_reward,
            "estimated_epoch_fee_octas": member_fee,
            "estimated_epoch_total_octas": member_reward + member_fee,
        }

    return {
        "validator": validator_address,
        "auto_compound": True,
        "reward_rate": reward_rate,
        "proposal_successful": successful,
        "proposal_failed": failed,
        "proposal_total": successful + failed,
        "pending_fee_octas": fee_octas,
        "estimated_epoch_reward_octas": reward_octas,
        "estimated_epoch_fee_octas": fee_octas,
        "estimated_epoch_total_octas": reward_octas + fee_octas,
        "estimated_commission_octas": reward_split["owner_extra_octas"] + fee_split["owner_extra_octas"],
        "estimated_delegator_octas": (reward_octas + fee_octas)
        - reward_split["owner_extra_octas"]
        - fee_split["owner_extra_octas"],
        "member_estimates": member_estimates,
    }


async def estimate_user_rewards(
    client: ChainClient,
    user_address: str,
    stake_info: dict | None = None,
    effective_power: int = 0,
    context: dict | None = None,
) -> dict:
    delegated_to = (stake_info or {}).get("delegated_to", ZERO_ADDRESS)
    base = {
        "auto_compound": True,
        "delegated_to": delegated_to,
        "is_delegated": delegated_to != ZERO_ADDRESS,
        "is_validator_owner": False,
        "basis_effective_power": effective_power,
        "pool_total_power": 0,
        "reward_rate": {"numerator": 0, "denominator": 0, "bps": 0},
        "pending_fee_octas": 0,
        "estimated_epoch_reward_octas": 0,
        "estimated_epoch_fee_octas": 0,
        "estimated_epoch_total_octas": 0,
        "estimated_owner_commission_octas": 0,
    }
    if delegated_to == ZERO_ADDRESS:
        return base

    try:
        validator_view = await view.get_validator_view(client, delegated_to)
        validator_index = await view.get_validator_index(client, delegated_to)
        proposals = await view.get_proposal_counts(client, validator_index)
        delegator_count = await view.get_validator_delegator_count(client, delegated_to)
        delegators = await view.get_validator_delegator_views(client, delegated_to, 0, min(delegator_count, 500))
        members = [
            {
                "address": d["delegator"],
                "effective_power": d["effective_power"],
            }
            for d in delegators
        ]
        estimate = await estimate_validator_rewards(
            client,
            delegated_to,
            validator_index,
            validator_view["total_power"],
            validator_view["commission_bps"],
            proposals=proposals,
            members=members,
            owner_address=validator_view["owner"],
            context=context,
        )
        user_key = user_address.lower()
        user_estimate = estimate["member_estimates"].get(user_key, {})
        is_owner = validator_view["owner"].lower() == user_key
        base.update({
            "validator_owner": validator_view["owner"],
            "is_validator_owner": is_owner,
            "basis_effective_power": effective_power,
            "pool_total_power": validator_view["total_power"],
            "reward_rate": estimate["reward_rate"],
            "pending_fee_octas": estimate["pending_fee_octas"],
            "estimated_epoch_reward_octas": user_estimate.get("estimated_epoch_reward_octas", 0),
            "estimated_epoch_fee_octas": user_estimate.get("estimated_epoch_fee_octas", 0),
            "estimated_epoch_total_octas": user_estimate.get("estimated_epoch_total_octas", 0),
            "estimated_owner_commission_octas": estimate["estimated_commission_octas"] if is_owner else 0,
        })
    except Exception:
        pass
    return base
