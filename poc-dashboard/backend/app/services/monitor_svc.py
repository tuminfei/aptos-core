import asyncio
from app.chain.client import get_chain_client
from app.chain import view
from app.api.ws import broadcast
from app.config import get_settings

_running = False
_last_epoch = 0
_last_active_count = 0
_last_period = 0


async def start_monitor():
    global _running
    _running = True
    settings = get_settings()
    interval = settings.server.poll_interval_secs

    while _running:
        try:
            await _poll_once()
        except Exception:
            pass
        await asyncio.sleep(interval)


async def stop_monitor():
    global _running
    _running = False


async def _poll_once():
    global _last_epoch, _last_active_count, _last_period
    client = get_chain_client()

    ledger = await client.get_ledger_info()
    epoch = int(ledger.get("epoch", 0))

    if _last_epoch > 0 and epoch != _last_epoch:
        await broadcast("epoch_changed", {
            "old_epoch": _last_epoch,
            "new_epoch": epoch,
            "timestamp": ledger.get("ledger_timestamp", ""),
        })
    _last_epoch = epoch

    try:
        active_count = await view.get_active_validator_count(client)
        if _last_active_count > 0 and active_count != _last_active_count:
            await broadcast("validator_set_changed", {
                "old_count": _last_active_count,
                "new_count": active_count,
            })
        _last_active_count = active_count
    except Exception:
        pass

    try:
        period = await view.get_current_period(client)
        if _last_period > 0 and period != _last_period:
            await broadcast("power_period_advanced", {
                "old_period": _last_period,
                "new_period": period,
            })
        _last_period = period
    except Exception:
        pass
