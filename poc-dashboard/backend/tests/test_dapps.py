import asyncio
import errno
from pathlib import Path

import pytest

from app.chain.keys import get_key_manager
from app.models import contribution_event, dapp_demo, dapp_trade_task, watchlist
from app.services import dapp_svc


@pytest.mark.asyncio
async def test_list_dapps_includes_registry_and_demo_config(client):
    await watchlist.add_address("dapp", "0xddd", "demo")
    await dapp_demo.upsert_config(
        app_admin="0xddd",
        module_address="0xabc",
        label="demo",
        metadata_uri="https://demo",
        initial_supply=100,
        price_per_equity=2,
        auto_whitelist=True,
    )

    resp = await client.get("/api/v1/dapps")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    app = data["apps"][0]
    assert app["app_admin"] == "0xddd"
    assert app["demo"]["module_address"] == "0xabc"
    assert app["poc_listing_status_code"] == 2


def test_demo_package_dir_falls_back_when_dashboard_generated_is_read_only(tmp_path, monkeypatch):
    repo_root = tmp_path / "topo-chain"
    dashboard_generated = repo_root / "poc-dashboard" / ".generated"

    real_mkdir = Path.mkdir

    def fake_mkdir(self, *args, **kwargs):
        if self == dashboard_generated:
            raise OSError(errno.EROFS, "Read-only file system", str(self))
        return real_mkdir(self, *args, **kwargs)

    monkeypatch.delenv(dapp_svc.DEMO_GENERATED_ENV, raising=False)
    monkeypatch.setattr(Path, "mkdir", fake_mkdir)
    monkeypatch.setattr(dapp_svc.tempfile, "gettempdir", lambda: str(tmp_path / "tmp"))

    assert dapp_svc._demo_package_dir(repo_root) == tmp_path / "tmp" / "poc-dashboard-generated" / "poc_demo_formal"


@pytest.mark.asyncio
async def test_dapp_admin_actions_use_managed_admin_key(client, mock_client):
    km = get_key_manager()
    key, address = km.generate_account("dapp-admin")
    await km.persist_key(key, address, "dapp-admin")

    resp = await client.post("/api/v1/dapps/pause", json={"app_admin": address})
    assert resp.status_code == 200
    tx = mock_client.submitted_txns[-1]
    assert tx["sender"] == address
    assert tx["payload"]["function"] == "0x1::poc_registry::pause_app"


@pytest.mark.asyncio
async def test_set_poc_status_uses_core_resources_script(client, monkeypatch):
    calls = []

    async def fake_set_poc_listing_status(**kwargs):
        calls.append(kwargs)
        return "cli:set-poc-status"

    monkeypatch.setattr(
        "app.api.dapps.dapp_svc.set_poc_listing_status_with_core_resources",
        fake_set_poc_listing_status,
    )

    resp = await client.post("/api/v1/dapps/set-poc-status", json={"app_admin": "0xddd", "status": 2})
    assert resp.status_code == 200
    assert resp.json()["tx_hash"] == "cli:set-poc-status"
    assert calls
    assert calls[0]["core_address"] == "0xa550c18"
    assert calls[0]["app_admin"] == "0xddd"
    assert calls[0]["status"] == 2


@pytest.mark.asyncio
async def test_set_weight_uses_core_resources_script(client, monkeypatch):
    calls = []

    async def fake_set_effective_weight(**kwargs):
        calls.append(kwargs)
        return "cli:set-weight"

    monkeypatch.setattr(
        "app.api.dapps.dapp_svc.set_effective_weight_with_core_resources",
        fake_set_effective_weight,
    )

    resp = await client.post("/api/v1/dapps/set-weight", json={"app_admin": "0xddd", "weight_pbs": 7500})
    assert resp.status_code == 200
    assert resp.json()["tx_hash"] == "cli:set-weight"
    assert calls
    assert calls[0]["core_address"] == "0xa550c18"
    assert calls[0]["app_admin"] == "0xddd"
    assert calls[0]["weight_pbs"] == 7500


@pytest.mark.asyncio
async def test_demo_buy_equity_uses_configured_module(client, mock_client):
    km = get_key_manager()
    key, buyer = km.generate_account("buyer")
    await km.persist_key(key, buyer, "buyer")
    await dapp_demo.upsert_config(
        app_admin="0xddd",
        module_address="0xabc",
        initial_supply=100,
        price_per_equity=2,
    )

    resp = await client.post(
        "/api/v1/dapps/demo/buy-equity",
        json={
            "app_admin": "0xddd",
            "buyer_address": buyer,
            "equity_amount": 7,
            "mint_octas": 0,
        },
    )
    assert resp.status_code == 200
    tx = mock_client.submitted_txns[-1]
    assert tx["sender"] == buyer
    assert tx["payload"]["function"] == "0xabc::poc_demo::buy_equity"
    assert tx["payload"]["arguments"] == ["0xddd", "7"]

    events_resp = await client.get("/api/v1/contributions", params={"contributor": buyer})
    assert events_resp.status_code == 200
    events = events_resp.json()["events"]
    assert len(events) == 1
    assert events[0]["contributor"] == buyer
    assert events[0]["app_admin"] == "0xddd"
    assert events[0]["app_address"] == "0xabc"
    assert events[0]["equity_amount"] == 7
    assert events[0]["period"] == 23


@pytest.mark.asyncio
async def test_contributions_filter_matches_padded_address(client):
    await contribution_event.insert_events([
        {
            "tx_hash": "0x" + "1" * 64,
            "event_index": 0,
            "version": 1,
            "app_admin": "0xddd",
            "app_address": "0xabc",
            "contributor": "0xabc",
            "equity_token": "0xdef",
            "equity_amount": 7,
            "period": 23,
            "event_type": "0x1::poc_contribution::ContributionEvent",
            "raw_event": {},
        },
    ])

    resp = await client.get("/api/v1/contributions", params={"contributor": "0x0abc"})

    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    assert data["events"][0]["contributor"] == "0xabc"


@pytest.mark.asyncio
async def test_auto_trade_without_fixed_buyers_uses_watchlist_users(client, mock_client):
    km = get_key_manager()
    _, buyer1 = km.generate_account("trade-buyer-1")
    _, buyer2 = km.generate_account("trade-buyer-2")
    await watchlist.add_address("user", buyer1, "trade-buyer-1")
    await watchlist.add_address("user", buyer2, "trade-buyer-2")
    await dapp_demo.upsert_config(
        app_admin="0xddd",
        module_address="0xabc",
        initial_supply=100,
        price_per_equity=2,
    )

    resp = await client.post(
        "/api/v1/dapps/demo/auto-trade/start",
        json={
            "app_admin": "0xddd",
            "interval_secs": 1,
            "tx_per_tick": 1,
            "amount_min": 3,
            "amount_max": 5,
            "max_runs": 1,
            "buyer_addresses": [],
            "auto_create_buyers": 0,
            "mint_octas": 0,
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["buyer_selection_mode"] == "watchlist_random"
    assert set(data["buyer_addresses"]) == {buyer1, buyer2}

    await asyncio.sleep(0.1)
    await dapp_svc.stop_all_trade_tasks()
    tx = next(t for t in reversed(mock_client.submitted_txns) if t["payload"]["function"] == "0xabc::poc_demo::buy_equity")
    assert tx["sender"] in {buyer1, buyer2}
    amount = int(tx["payload"]["arguments"][1])
    assert 3 <= amount <= 5


@pytest.mark.asyncio
async def test_auto_trade_tops_up_custody_inventory_before_buy(client, mock_client):
    km = get_key_manager()
    admin_key, app_admin = km.generate_account("trade-app")
    buyer_key, buyer = km.generate_account("trade-buyer")
    await km.persist_key(admin_key, app_admin, "trade-app")
    await km.persist_key(buyer_key, buyer, "trade-buyer")
    await watchlist.add_address("user", buyer, "trade-buyer")
    await dapp_demo.upsert_config(
        app_admin=app_admin,
        module_address="0xabc",
        initial_supply=1,
        price_per_equity=2,
    )
    mock_client.set_view_response("0xabc::poc_demo::custody_inventory", [0])

    resp = await client.post(
        "/api/v1/dapps/demo/auto-trade/start",
        json={
            "app_admin": app_admin,
            "interval_secs": 1,
            "tx_per_tick": 1,
            "amount_min": 7,
            "amount_max": 7,
            "max_runs": 1,
            "buyer_addresses": [buyer],
            "auto_create_buyers": 0,
            "mint_octas": 0,
        },
    )
    assert resp.status_code == 200

    await asyncio.sleep(0.1)
    await dapp_svc.stop_all_trade_tasks()

    txns = mock_client.submitted_txns
    mint_tx = next(t for t in txns if t["payload"]["function"] == "0xabc::poc_demo::mint_equity_to_custody")
    buy_tx = next(t for t in txns if t["payload"]["function"] == "0xabc::poc_demo::buy_equity")
    assert mint_tx["sender"] == app_admin
    assert int(mint_tx["payload"]["arguments"][0]) >= 7
    assert txns.index(mint_tx) < txns.index(buy_tx)
    assert buy_tx["sender"] == buyer


@pytest.mark.asyncio
async def test_auto_trade_task_persists_and_survives_shutdown(client, monkeypatch):
    km = get_key_manager()
    _, buyer = km.generate_account("persisted-trade-buyer")
    await watchlist.add_address("user", buyer, "persisted-trade-buyer")
    await dapp_demo.upsert_config(
        app_admin="0xddd",
        module_address="0xabc",
        initial_supply=100,
        price_per_equity=2,
    )

    async def idle_trade_loop(task):
        task.status = "running"
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            raise

    monkeypatch.setattr(dapp_svc, "_trade_loop", idle_trade_loop)

    resp = await client.post(
        "/api/v1/dapps/demo/auto-trade/start",
        json={
            "app_admin": "0xddd",
            "interval_secs": 1,
            "tx_per_tick": 1,
            "amount_min": 3,
            "amount_max": 5,
            "max_runs": 0,
            "buyer_addresses": [buyer],
            "auto_create_buyers": 0,
            "mint_octas": 0,
        },
    )

    assert resp.status_code == 200
    row = await dapp_trade_task.get_task("0xddd")
    assert row["status"] == "running"
    assert row["module_address"] == "0xabc"
    assert row["buyer_addresses"] == [buyer]

    await dapp_svc.stop_all_trade_tasks()

    row = await dapp_trade_task.get_task("0xddd")
    assert row["status"] == "running"
    assert await dapp_svc.get_trade_task_status("0xddd") == row

    restored = await dapp_svc.restore_trade_tasks()

    assert len(restored) == 1
    assert restored[0]["app_admin"] == "0xddd"
    status = await dapp_svc.get_trade_task_status("0xddd")
    assert status["status"] == "running"
    assert status["module_address"] == "0xabc"

    await dapp_svc.stop_trade_task("0xddd")
    row = await dapp_trade_task.get_task("0xddd")
    assert row["status"] == "stopped"
