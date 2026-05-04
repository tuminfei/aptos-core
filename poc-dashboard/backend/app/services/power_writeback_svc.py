import asyncio
import contextlib
import time
from dataclasses import dataclass
from typing import Any

from app.api.ws import broadcast
from app.chain import view
from app.chain.client import ChainClient, get_chain_client
from app.chain.keys import get_key_manager
from app.chain.transaction import submit_entry_function
from app.config import get_settings
from app.models import contribution_event, operation_log
from app.services import dapp_svc
from app.services.cache_svc import invalidate_many
from app.utils.address import address_key


@dataclass
class PowerWritebackSettings:
    enabled: bool
    interval_secs: int
    max_users_per_run: int
    max_gas: int
    gas_unit_price: int


_task: asyncio.Task | None = None
_stop_event: asyncio.Event | None = None
_lock = asyncio.Lock()
_uploaded_periods: dict[int, dict[str, Any]] = {}
_settings_override: PowerWritebackSettings | None = None
_last_status: dict[str, Any] = {
    "running": False,
    "busy": False,
    "last_run_at": None,
    "last_result": None,
    "last_error": "",
    "uploaded_periods": {},
}


def _configured_settings() -> PowerWritebackSettings:
    cfg = get_settings().power_writeback
    return PowerWritebackSettings(
        enabled=bool(cfg.enabled),
        interval_secs=max(5, int(cfg.interval_secs or 60)),
        max_users_per_run=max(1, int(cfg.max_users_per_run or 1000)),
        max_gas=max(1, int(cfg.max_gas or dapp_svc.DEFAULT_MAX_GAS)),
        gas_unit_price=max(1, int(cfg.gas_unit_price or dapp_svc.DEFAULT_GAS_UNIT_PRICE)),
    )


def get_settings_snapshot() -> dict:
    settings = _settings_override or _configured_settings()
    return {
        "enabled": settings.enabled,
        "interval_secs": settings.interval_secs,
        "max_users_per_run": settings.max_users_per_run,
        "max_gas": settings.max_gas,
        "gas_unit_price": settings.gas_unit_price,
    }


async def configure_task(
    *,
    enabled: bool,
    interval_secs: int,
    max_users_per_run: int,
    max_gas: int,
    gas_unit_price: int,
) -> dict:
    global _settings_override
    _settings_override = PowerWritebackSettings(
        enabled=enabled,
        interval_secs=max(5, int(interval_secs or 60)),
        max_users_per_run=max(1, int(max_users_per_run or 1000)),
        max_gas=max(1, int(max_gas or dapp_svc.DEFAULT_MAX_GAS)),
        gas_unit_price=max(1, int(gas_unit_price or dapp_svc.DEFAULT_GAS_UNIT_PRICE)),
    )
    if enabled:
        await start_task()
    else:
        await stop_task()
    await broadcast("power_writeback_task", await get_status())
    return await get_status()


async def start_task() -> None:
    global _task, _stop_event
    if _task and not _task.done():
        _last_status["running"] = True
        return
    _stop_event = asyncio.Event()
    _last_status["running"] = True
    _task = asyncio.create_task(_loop(_stop_event))


async def stop_task() -> None:
    global _task, _stop_event
    if _stop_event:
        _stop_event.set()
    if _task:
        _task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _task
    _task = None
    _stop_event = None
    _last_status["running"] = False
    _last_status["busy"] = False


async def start_configured_task() -> None:
    settings = _settings_override or _configured_settings()
    if settings.enabled:
        await start_task()


async def get_status() -> dict:
    task_alive = bool(_task and not _task.done())
    return {
        **_last_status,
        "running": task_alive,
        "settings": get_settings_snapshot(),
        "uploaded_periods": {str(k): v for k, v in _uploaded_periods.items()},
    }


async def run_once(force: bool = False) -> dict:
    settings = _settings_override or _configured_settings()
    async with _lock:
        _last_status["busy"] = True
        _last_status["last_run_at"] = time.time()
        should_raise: Exception | None = None
        result: dict[str, Any] | None = None
        try:
            result = await _run_once(settings, force=force)
            _last_status["last_result"] = result
            _last_status["last_error"] = ""
        except Exception as exc:
            _last_status["last_error"] = str(exc)
            should_raise = exc
        finally:
            _last_status["busy"] = False
            await broadcast("power_writeback_task", await get_status())
        if should_raise:
            raise should_raise
        return result or {}


async def _loop(stop_event: asyncio.Event) -> None:
    while not stop_event.is_set():
        settings = _settings_override or _configured_settings()
        if not settings.enabled:
            await _wait(stop_event, settings.interval_secs)
            continue
        with contextlib.suppress(Exception):
            await run_once(force=False)
        await _wait(stop_event, settings.interval_secs)


async def _wait(stop_event: asyncio.Event, interval_secs: int) -> None:
    try:
        await asyncio.wait_for(stop_event.wait(), timeout=max(5, interval_secs))
    except asyncio.TimeoutError:
        pass


async def _run_once(settings: PowerWritebackSettings, *, force: bool) -> dict:
    client = get_chain_client()
    current_period = await view.get_current_period(client)
    source_period = current_period - 1
    target_period = current_period + 1
    if source_period < 0:
        return _skipped("no_previous_period", current_period, source_period, target_period)

    cached = _uploaded_periods.get(source_period)
    if cached and cached.get("target_period") == target_period and not force:
        return {
            "status": "skipped",
            "reason": "already_uploaded",
            "current_period": current_period,
            "source_period": source_period,
            "target_period": target_period,
            "cached": cached,
        }

    aggregates = await build_power_updates(
        client,
        source_period=source_period,
        target_period=target_period,
        limit=settings.max_users_per_run,
    )
    updates = aggregates["updates"]
    if not updates:
        return {
            "status": "skipped",
            "reason": "no_contributions",
            "current_period": current_period,
            "source_period": source_period,
            "target_period": target_period,
            "source_event_groups": aggregates["source_event_groups"],
            "updated_users": 0,
            "total_delta_power": 0,
        }

    if aggregates.get("truncated"):
        return {
            "status": "skipped",
            "reason": "too_many_users",
            "current_period": current_period,
            "source_period": source_period,
            "target_period": target_period,
            "updated_users": len(updates),
            "total_users": aggregates.get("total_users", len(updates)),
            "max_users_per_run": settings.max_users_per_run,
            "source_event_groups": aggregates["source_event_groups"],
        }

    tx_hash = await stage_power_updates(
        client,
        target_period=target_period,
        updates=updates,
        max_gas=settings.max_gas,
        gas_unit_price=settings.gas_unit_price,
    )
    result = {
        "status": "success",
        "tx_hash": tx_hash,
        "current_period": current_period,
        "source_period": source_period,
        "target_period": target_period,
        "updated_users": len(updates),
        "source_event_groups": aggregates["source_event_groups"],
        "total_delta_power": aggregates["total_delta_power"],
    }
    _uploaded_periods[source_period] = {**result, "updated_at": time.time()}
    await operation_log.create_log("power_writeback_stage_batch", str(source_period), result, tx_hash, "success")
    await invalidate_many("user:", "validators:", "validator:")
    await broadcast("power_writeback_submitted", result)
    return result


def _skipped(reason: str, current_period: int, source_period: int, target_period: int) -> dict:
    return {
        "status": "skipped",
        "reason": reason,
        "current_period": current_period,
        "source_period": source_period,
        "target_period": target_period,
    }


async def build_power_updates(
    client: ChainClient | None = None,
    *,
    source_period: int,
    target_period: int,
    limit: int,
) -> dict:
    client = client or get_chain_client()
    event_rows = await contribution_event.aggregate_by_contributor_for_period(source_period)
    weights: dict[str, int] = {}
    deltas_by_user: dict[str, dict[str, Any]] = {}

    for row in event_rows:
        contributor = row["contributor"]
        app_admin = row.get("app_admin") or ""
        amount = int(row.get("equity_amount", 0) or 0)
        if not contributor or amount <= 0:
            continue
        weight = await _effective_weight(client, app_admin, weights)
        delta = amount * weight // 10000
        if delta <= 0:
            continue
        key = address_key(contributor)
        entry = deltas_by_user.setdefault(key, {"address": contributor, "delta_power": 0})
        entry["delta_power"] += delta

    users = [entry["address"] for entry in deltas_by_user.values()]
    users = users[:max(1, limit)]
    current_powers = await _current_powers(client, users, source_period + 1)
    updates = []
    total_delta = 0
    for index, user in enumerate(users):
        key = address_key(user)
        delta = int(deltas_by_user[key]["delta_power"])
        base_power = int(current_powers[index] if index < len(current_powers) else 0)
        updates.append({
            "address": user,
            "power": base_power + delta,
            "base_power": base_power,
            "delta_power": delta,
        })
        total_delta += delta

    return {
        "source_period": source_period,
        "target_period": target_period,
        "source_event_groups": len(event_rows),
        "updates": updates,
        "total_delta_power": total_delta,
        "total_users": len(deltas_by_user),
        "truncated": len(deltas_by_user) > len(users),
    }


async def _effective_weight(client: ChainClient, app_admin: str, cache: dict[str, int]) -> int:
    key = address_key(app_admin)
    if not key:
        return 10000
    if key not in cache:
        try:
            cache[key] = await view.get_effective_weight_pbs(client, app_admin)
        except Exception:
            cache[key] = 10000
    return max(0, min(10000, int(cache[key] or 0)))


async def _current_powers(client: ChainClient, users: list[str], current_period: int) -> list[int]:
    if not users:
        return []
    try:
        return await view.get_user_powers_for_period(client, users, current_period)
    except Exception:
        return [0] * len(users)


async def stage_power_updates(
    client: ChainClient,
    *,
    target_period: int,
    updates: list[dict],
    max_gas: int,
    gas_unit_price: int,
) -> str:
    km = get_key_manager()
    addresses = [item["address"] for item in updates]
    powers = [int(item["power"]) for item in updates]
    if not addresses:
        return "batch:0"

    operator_error: Exception | None = None
    try:
        operator = await view.get_power_operator(client)
        operator_key = km.get_operator_key_by_address(operator)
        if operator_key:
            return await submit_entry_function(
                client,
                operator_key,
                operator,
                "0x1::poc_power_store::stage_batch_update",
                args=[str(target_period), addresses, [str(power) for power in powers]],
                max_gas=max_gas,
                gas_unit_price=gas_unit_price,
            )
    except Exception as exc:
        operator_error = exc

    try:
        return await _stage_power_updates_one_by_one(
            client,
            target_period=target_period,
            addresses=addresses,
            powers=powers,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )
    except Exception as exc:
        if operator_error:
            raise RuntimeError(f"batch entry failed: {operator_error}; single-update fallback failed: {exc}") from exc
        raise


async def _stage_power_updates_one_by_one(
    client: ChainClient,
    *,
    target_period: int,
    addresses: list[str],
    powers: list[int],
    max_gas: int,
    gas_unit_price: int,
) -> str:
    current_period = await view.get_current_period(client)
    expected_target = current_period + 1
    if target_period != expected_target:
        raise RuntimeError(f"target_period {target_period} must equal current_period + 1 ({expected_target})")

    km = get_key_manager()
    tx_hashes = []
    for address, power in zip(addresses, powers):
        tx_hashes.append(await submit_entry_function(
            client,
            km.core_resources_key,
            km.core_resources_address,
            "0x1::topo_governance::stage_power_update_test_only",
            args=[address, str(power)],
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        ))
    return _summarize_batch_tx_hashes(tx_hashes)


def _summarize_batch_tx_hashes(tx_hashes: list[str]) -> str:
    if not tx_hashes:
        return "batch:0"
    if len(tx_hashes) == 1:
        return tx_hashes[0]
    return f"batch:{len(tx_hashes)}:{tx_hashes[-1]}"
