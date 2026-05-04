from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import load_settings
from app.models.db import init_db, close_db
from app.chain.client import close_chain_client
from app.chain.keys import get_key_manager
from app.api.errors import AppError, app_error_handler
from app.services.history_svc import start_sampler, stop_sampler
from app.services.monitor_svc import start_monitor, stop_monitor
from app.services.power_writeback_svc import start_configured_task, stop_task as stop_power_writeback_task
from app.services.dapp_svc import restore_trade_tasks, stop_all_trade_tasks
from app.services.cache_svc import start_cache_maintainer, stop_cache_maintainer


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    await init_db(settings.database.path)
    km = get_key_manager()
    km.load_from_config(settings.keys)
    await km.load_managed_keys()
    await start_cache_maintainer()
    await restore_trade_tasks()
    await start_monitor()
    await start_configured_task()
    if settings.server.history_sampler_enabled:
        await start_sampler(settings.server.history_sampler_interval_secs)
    yield
    await stop_all_trade_tasks()
    await stop_power_writeback_task()
    await stop_sampler()
    await stop_monitor()
    await stop_cache_maintainer()
    await close_db()
    await close_chain_client()


def create_app() -> FastAPI:
    app = FastAPI(title="POC Dashboard API", version="0.1.0", lifespan=lifespan)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.add_exception_handler(AppError, app_error_handler)

    from app.api import system, dashboard, validators, users, staking, power, topo, governance, dapps, events, logs, ws, watchlist, history, contributions
    prefix = "/api/v1"
    app.include_router(system.router, prefix=prefix)
    app.include_router(dashboard.router, prefix=prefix)
    app.include_router(validators.router, prefix=prefix)
    app.include_router(users.router, prefix=prefix)
    app.include_router(staking.router, prefix=prefix)
    app.include_router(power.router, prefix=prefix)
    app.include_router(topo.router, prefix=prefix)
    app.include_router(governance.router, prefix=prefix)
    app.include_router(dapps.router, prefix=prefix)
    app.include_router(events.router, prefix=prefix)
    app.include_router(logs.router, prefix=prefix)
    app.include_router(ws.router)
    app.include_router(watchlist.router, prefix=prefix)
    app.include_router(history.router, prefix=prefix)
    app.include_router(contributions.router, prefix=prefix)

    return app


app = create_app()
