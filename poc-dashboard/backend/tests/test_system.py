import pytest


@pytest.mark.asyncio
async def test_health(client):
    resp = await client.get("/api/v1/system/health")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["chain_connected"] is True


@pytest.mark.asyncio
async def test_chain_info(client):
    resp = await client.get("/api/v1/system/chain-info")
    assert resp.status_code == 200
    data = resp.json()
    assert data["chain_id"] == 4
    assert data["epoch"] == 142
