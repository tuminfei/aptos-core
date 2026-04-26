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
