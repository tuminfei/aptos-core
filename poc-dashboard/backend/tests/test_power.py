import pytest
from app.models.watchlist import add_address


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
