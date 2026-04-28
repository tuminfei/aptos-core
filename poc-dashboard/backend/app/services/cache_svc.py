import asyncio
import contextlib
import time
from collections.abc import Awaitable, Callable
from copy import deepcopy
from typing import Any


DEFAULT_TTL_SECS = 8.0
_store: dict[str, tuple[float, Any]] = {}
_lock = asyncio.Lock()
_task: asyncio.Task | None = None
_running = False


def _now() -> float:
    return time.monotonic()


async def get_or_set(key: str, loader: Callable[[], Awaitable[Any]], ttl_secs: float = DEFAULT_TTL_SECS) -> Any:
    now = _now()
    async with _lock:
        cached = _store.get(key)
        if cached and cached[0] > now:
            return deepcopy(cached[1])

    value = await loader()
    async with _lock:
        _store[key] = (now + ttl_secs, deepcopy(value))
    return value


async def invalidate(prefix: str | None = None) -> None:
    async with _lock:
        if not prefix:
            _store.clear()
            return
        for key in list(_store.keys()):
            if key.startswith(prefix):
                _store.pop(key, None)


async def invalidate_many(*prefixes: str) -> None:
    for prefix in prefixes:
        await invalidate(prefix)


async def start_cache_maintainer(interval_secs: float = 30.0) -> None:
    global _running, _task
    if _task and not _task.done():
        return
    _running = True
    _task = asyncio.create_task(_maintenance_loop(interval_secs))


async def stop_cache_maintainer() -> None:
    global _running, _task
    _running = False
    if _task:
        _task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await _task
        _task = None


async def _maintenance_loop(interval_secs: float) -> None:
    while _running:
        await asyncio.sleep(interval_secs)
        now = _now()
        async with _lock:
            for key, (expires_at, _) in list(_store.items()):
                if expires_at <= now:
                    _store.pop(key, None)
