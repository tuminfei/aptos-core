import pytest


@pytest.mark.asyncio
async def test_user_detail(client):
    resp = await client.get("/api/v1/users/0xaaa")
    assert resp.status_code == 200
    data = resp.json()
    assert data["address"] == "0xaaa"
    assert "balance" in data
    assert "power" in data
    assert "staking" in data
    assert data["balance"]["topo_octas"] == 100000000000
    assert data["power"]["committed_power"] == 5000
    assert data["power_store"]["retention_bps"] == 9950
    assert data["power_store"]["versions"]["older"]["effective_period"] == 20
    assert data["power_store"]["versions"]["older"]["raw_power"] == 4000
    assert data["power_store"]["versions"]["newer"]["effective_period"] == 23
    assert data["power_store"]["versions"]["newer"]["raw_power"] == 5000
    assert data["power_store"]["current_calculation"]["selected_slot"] == "newer"
    assert data["power_store"]["current_calculation"]["calculated_power"] == 5000
    assert len(data["power_store"]["version_rows"]) == 2
    assert data["power_store"]["version_rows"][1]["slot"] == "newer"
    assert data["power_store"]["version_rows"][1]["selected_for_current_period"] is True
    assert "staking_effective_minus_power_store" in data["power_store"]["power_gap"]
    assert "rewards" in data
    assert data["rewards"]["auto_compound"] is True
    assert data["rewards"]["estimated_epoch_total_octas"] > 0


@pytest.mark.asyncio
async def test_power_history(client):
    resp = await client.get("/api/v1/users/0xaaa/power-history", params={"periods": 5})
    assert resp.status_code == 200
    data = resp.json()
    assert data["address"] == "0xaaa"
    assert "history" in data
    assert len(data["history"]) > 0
    assert "period" in data["history"][0]
    assert "power" in data["history"][0]
