import pytest


@pytest.mark.asyncio
async def test_dashboard_overview(client):
    resp = await client.get("/api/v1/dashboard/overview")
    assert resp.status_code == 200
    data = resp.json()
    assert "chain" in data
    assert "validators" in data
    assert "power" in data
    assert "staking" in data
    assert data["chain"]["epoch"] == 142
    assert data["chain"]["chain_id"] == 4
    assert data["validators"]["active"] == 4
    assert data["power"]["current_period"] == 23
    assert data["staking"]["total_staked_power"] == 40000
