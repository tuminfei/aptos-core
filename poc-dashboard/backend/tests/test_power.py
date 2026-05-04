import pytest
from app.models import contribution_event
from app.models.watchlist import add_address
from app.services import power_writeback_svc


@pytest.mark.asyncio
async def test_power_overview(client):
    resp = await client.get("/api/v1/power/overview")
    assert resp.status_code == 200
    data = resp.json()
    assert data["current_period"] == 23
    assert data["power_period_in_epochs"] == 5
    assert data["retention_bps"] == 9950
    assert data["power_period_clock_initialized"] is True
    assert data["power_period_clock_countdown"] == 2
    assert data["epochs_until_next_period"] == 3


@pytest.mark.asyncio
async def test_power_store_includes_validator_users(client):
    await add_address("validator", "0x1a2b", "validator-a")

    resp = await client.get("/api/v1/power/store")

    assert resp.status_code == 200
    data = resp.json()
    validator_user = next(item for item in data["watched_users"] if item["address"] == "0x1a2b")
    assert validator_user["is_validator_user"] is True
    assert validator_user["in_validator_watchlist"] is True
    assert validator_user["label"] == "validator-a"
    assert data["validator_user_count"] >= 1
    assert data["next_epoch_period"] == 23


@pytest.mark.asyncio
async def test_power_store_next_epoch_period_uses_clock(client, mock_client):
    mock_client.set_resource(
        "0x1",
        "0x1::poc_power_store::PowerPeriodClock",
        {
            "type": "0x1::poc_power_store::PowerPeriodClock",
            "data": {"epochs_until_next_power_period": "0"},
        },
    )

    resp = await client.get("/api/v1/power/store")

    assert resp.status_code == 200
    data = resp.json()
    assert data["current_period"] == 23
    assert data["next_epoch_period"] == 24
    assert data["epochs_until_next_period"] == 1


@pytest.mark.asyncio
async def test_topo_balance(client):
    resp = await client.get("/api/v1/topo/balance/0xaaa")
    assert resp.status_code == 200
    data = resp.json()
    assert data["address"] == "0xaaa"
    assert data["balance_octas"] == 100000000000
    assert data["balance_topo"] == 1000.0


@pytest.mark.asyncio
async def test_mint_topo_rejects_balance_overflow(client, mock_client):
    mock_client.set_view_response("0x1::coin::balance", [18446744073709551610])

    resp = await client.post(
        "/api/v1/topo/mint",
        json={"recipient": "0xaaa", "amount": 10},
    )

    assert resp.status_code == 400
    assert resp.json()["code"] == 40003
    assert "最多还能铸造 5 octas" in resp.json()["message"]
    assert mock_client.submitted_txns == []


@pytest.mark.asyncio
async def test_mint_topo_success(client, mock_client):
    mock_client.set_view_response("0x1::coin::balance", [1000])

    resp = await client.post(
        "/api/v1/topo/mint",
        json={"recipient": "0xaaa", "amount": 100},
    )

    assert resp.status_code == 200
    assert resp.json()["success"] is True
    assert mock_client.submitted_txns[-1]["payload"]["function"] == "0x1::topo_coin::mint"


@pytest.mark.asyncio
async def test_power_writeback_builds_previous_period_updates(client, mock_client):
    await contribution_event.insert_events([
        {
            "tx_hash": "0x" + "1" * 64,
            "event_index": 0,
            "version": 1,
            "app_admin": "0xddd",
            "app_address": "0xabc",
            "contributor": "0xaaa",
            "equity_token": "0xdef",
            "equity_amount": 100,
            "period": 22,
            "event_type": "0x1::poc_contribution::ContributionEvent",
            "raw_event": {},
        },
    ])
    mock_client.set_view_response("0x1::poc_power_store::get_user_powers_for_period", [[4500]])
    mock_client.set_view_response("0x1::poc_registry::get_effective_weight_pbs", [5000])

    result = await power_writeback_svc.build_power_updates(
        mock_client,
        source_period=22,
        target_period=24,
        limit=100,
    )

    assert result["source_event_groups"] == 1
    assert result["total_delta_power"] == 50
    assert result["updates"] == [{"address": "0xaaa", "power": 4550, "base_power": 4500, "delta_power": 50}]


@pytest.mark.asyncio
async def test_power_writeback_run_once_skips_duplicate_period(client, monkeypatch):
    await contribution_event.insert_events([
        {
            "tx_hash": "0x" + "2" * 64,
            "event_index": 0,
            "version": 1,
            "app_admin": "0xddd",
            "app_address": "0xabc",
            "contributor": "0xaaa",
            "equity_token": "0xdef",
            "equity_amount": 100,
            "period": 22,
            "event_type": "0x1::poc_contribution::ContributionEvent",
            "raw_event": {},
        },
    ])

    calls = []

    async def fake_stage_updates(client, *, target_period, updates, max_gas, gas_unit_price):
        calls.append({"target_period": target_period, "updates": updates})
        return "cli:stage-batch"

    monkeypatch.setattr(power_writeback_svc, "stage_power_updates", fake_stage_updates)

    first = await power_writeback_svc.run_once(force=True)
    second = await power_writeback_svc.run_once(force=False)

    assert first["status"] == "success"
    assert first["source_period"] == 22
    assert first["target_period"] == 24
    assert len(calls) == 1
    assert second["status"] == "skipped"
    assert second["reason"] == "already_uploaded"


@pytest.mark.asyncio
async def test_power_writeback_task_config_api(client):
    resp = await client.post(
        "/api/v1/power/writeback-task/config",
        json={
            "enabled": False,
            "interval_secs": 15,
            "max_users_per_run": 10,
            "max_gas": 500000,
            "gas_unit_price": 101,
        },
    )

    assert resp.status_code == 200
    data = resp.json()
    assert data["settings"]["enabled"] is False
    assert data["settings"]["interval_secs"] == 15
    assert data["settings"]["max_users_per_run"] == 10
