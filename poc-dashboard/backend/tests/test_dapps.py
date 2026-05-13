import asyncio
import errno
import subprocess
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


def test_ensure_demo_package_uses_topo_framework_package(tmp_path, monkeypatch):
    repo_root = tmp_path / "topo-chain"
    source_dir = repo_root / "aptos-move" / "move-examples" / "poc_demo" / "sources"
    framework_dir = repo_root / "aptos-move" / "framework" / "topo-framework"
    generated_dir = tmp_path / "generated"
    source_dir.mkdir(parents=True)
    framework_dir.mkdir(parents=True)
    (source_dir / "poc_demo.move").write_text(
        "\n".join([
            "module poc_demo::poc_demo {",
            "    use poc_framework::poc_contribution;",
            "    use poc_framework::poc_registry;",
            "}",
        ]),
        encoding="utf-8",
    )

    monkeypatch.setenv(dapp_svc.DEMO_GENERATED_ENV, str(generated_dir))

    package_dir = dapp_svc._ensure_demo_package(repo_root)
    move_toml = (package_dir / "Move.toml").read_text(encoding="utf-8")
    source = (package_dir / "sources" / "poc_demo.move").read_text(encoding="utf-8")

    assert f'TopoFramework = {{ local = "{framework_dir}" }}' in move_toml
    assert "use topo_framework::poc_contribution;" in source
    assert "use topo_framework::poc_registry;" in source


@pytest.mark.asyncio
async def test_deploy_demo_package_publishes_under_admin_address(tmp_path, monkeypatch):
    repo_root = tmp_path / "topo-chain"
    source_dir = repo_root / "aptos-move" / "move-examples" / "poc_demo" / "sources"
    framework_dir = repo_root / "aptos-move" / "framework" / "topo-framework"
    generated_dir = tmp_path / "generated"
    source_dir.mkdir(parents=True)
    framework_dir.mkdir(parents=True)
    (source_dir / "poc_demo.move").write_text("module poc_demo::poc_demo {}", encoding="utf-8")
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(
            cmd,
            0,
            stdout='{"Result":"Success","hash":"0x' + "2" * 64 + '"}',
            stderr="",
        )

    class FakeKey:
        private_key_hex = "0xabc"

    monkeypatch.setenv(dapp_svc.DEMO_GENERATED_ENV, str(generated_dir))
    monkeypatch.setattr(dapp_svc, "_repo_root", lambda: repo_root)
    monkeypatch.setattr(dapp_svc, "_aptos_cli", lambda _repo_root: ["aptos"])
    monkeypatch.setattr(dapp_svc.subprocess, "run", fake_run)

    module_address, tx_hash = await dapp_svc.deploy_demo_package(
        admin_key=FakeKey(),
        admin_address="0xabc",
        rest_url="http://127.0.0.1:8080/v1",
    )

    assert module_address == "0xabc"
    assert tx_hash == "0x" + "2" * 64
    assert calls[0][:3] == ["aptos", "move", "publish"]
    assert "create-object-and-publish-package" not in calls[0]
    assert calls[0][calls[0].index("--named-addresses") + 1] == "poc_demo=0xabc"
    assert calls[0][calls[0].index("--sender-account") + 1] == "0xabc"


@pytest.mark.asyncio
async def test_run_poc_framework_script_compiles_explicit_topo_framework_package(tmp_path, monkeypatch):
    repo_root = tmp_path / "topo-chain"
    dashboard_scripts = repo_root / "poc-dashboard" / "scripts"
    framework_dir = repo_root / "aptos-move" / "framework" / "topo-framework"
    dashboard_scripts.mkdir(parents=True)
    framework_dir.mkdir(parents=True)
    (dashboard_scripts / "initialize_poc_registry.move").write_text(
        "script { fun main(_core_resources: &signer) {} }",
        encoding="utf-8",
    )
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        if "compile-script" in cmd:
            output_file = Path(cmd[cmd.index("--output-file") + 1])
            output_file.write_bytes(b"script")
            return subprocess.CompletedProcess(cmd, 0, stdout="compiled", stderr="")
        return subprocess.CompletedProcess(
            cmd,
            0,
            stdout='{"Result":"Success","hash":"0x' + "1" * 64 + '"}',
            stderr="",
        )

    class FakeKey:
        private_key_hex = "0xabc"

    key = FakeKey()
    monkeypatch.setattr(dapp_svc, "_repo_root", lambda: repo_root)
    monkeypatch.setattr(dapp_svc, "_aptos_cli", lambda _repo_root: ["aptos"])
    monkeypatch.setattr(dapp_svc.subprocess, "run", fake_run)

    tx_hash = await dapp_svc.run_poc_framework_script(
        "initialize_poc_registry.move",
        core_key=key,
        core_address="0xa550c18",
        rest_url="http://127.0.0.1:39090/v1",
        args=["u64:5"],
    )

    assert tx_hash == "0x" + "1" * 64
    assert calls[0][:3] == ["aptos", "move", "compile-script"]
    assert "--script-path" not in calls[1]
    assert "--framework-local-dir" not in calls[1]
    assert "--compiled-script-path" in calls[1]
    assert calls[1][-2:] == ["--args", "u64:5"]


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
            "equity_amount": 10,
            "mint_octas": 0,
        },
    )
    assert resp.status_code == 200
    tx = mock_client.submitted_txns[-1]
    assert tx["sender"] == buyer
    assert tx["payload"]["function"] == "0xabc::poc_demo::buy_equity"
    assert tx["payload"]["arguments"] == ["0xddd", "10"]

    events_resp = await client.get("/api/v1/contributions", params={"contributor": buyer})
    assert events_resp.status_code == 200
    events = events_resp.json()["events"]
    assert len(events) == 1
    assert events[0]["contributor"] == buyer
    assert events[0]["app_admin"] == "0xddd"
    assert events[0]["app_address"] == "0xabc"
    assert events[0]["equity_amount"] == 10
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
            "amount_min": 10,
            "amount_max": 12,
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
    assert 10 <= amount <= 12


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
            "amount_min": 10,
            "amount_max": 10,
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
    assert int(mint_tx["payload"]["arguments"][0]) >= 10
    assert txns.index(mint_tx) < txns.index(buy_tx)
    assert buy_tx["sender"] == buyer


@pytest.mark.asyncio
async def test_auto_trade_tick_submits_distinct_buyers_in_parallel(client, mock_client):
    km = get_key_manager()
    admin_key, app_admin = km.generate_account("parallel-trade-app")
    buyers = []
    for idx in range(3):
        buyer_key, buyer = km.generate_account(f"parallel-trade-buyer-{idx}")
        await km.persist_key(buyer_key, buyer, f"parallel-trade-buyer-{idx}")
        await watchlist.add_address("user", buyer, f"parallel-trade-buyer-{idx}")
        buyers.append(buyer)
    await km.persist_key(admin_key, app_admin, "parallel-trade-app")
    await dapp_demo.upsert_config(
        app_admin=app_admin,
        module_address="0xabc",
        initial_supply=100,
        price_per_equity=2,
    )
    mock_client.set_view_response("0xabc::poc_demo::custody_inventory", [100])

    resp = await client.post(
        "/api/v1/dapps/demo/auto-trade/start",
        json={
            "app_admin": app_admin,
            "interval_secs": 1,
            "tx_per_tick": 3,
            "amount_min": 10,
            "amount_max": 10,
            "max_runs": 3,
            "buyer_addresses": buyers,
            "auto_create_buyers": 0,
            "mint_octas": 0,
        },
    )
    assert resp.status_code == 200

    await asyncio.sleep(0.2)
    await dapp_svc.stop_all_trade_tasks()

    buy_txns = [t for t in mock_client.submitted_txns if t["payload"]["function"] == "0xabc::poc_demo::buy_equity"]
    assert len(buy_txns) == 3
    assert {tx["sender"] for tx in buy_txns} == set(buyers)
    status = await dapp_svc.get_trade_task_status(app_admin)
    assert status["success_count"] == 3
    assert status["run_count"] == 3


def test_next_buyer_batch_uses_distinct_addresses():
    task = dapp_svc.DemoTradeTask(
        task_id="task",
        app_admin="0xapp",
        module_address="0xabc",
        interval_secs=1,
        tx_per_tick=3,
        amount_min=10,
        amount_max=10,
        max_runs=0,
        buyer_addresses=["0x1", "0x1", "0x2", "0x3"],
        buyer_selection_mode="fixed",
        auto_create_buyers=0,
        mint_octas=0,
        max_gas=1,
        gas_unit_price=1,
    )

    assert dapp_svc._next_buyer_batch(task, 3) == ["0x1", "0x2", "0x3"]


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
            "amount_min": 10,
            "amount_max": 12,
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
