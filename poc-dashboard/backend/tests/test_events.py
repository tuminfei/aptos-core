import pytest


@pytest.mark.asyncio
async def test_events(client):
    resp = await client.get("/api/v1/events")
    assert resp.status_code == 200
    data = resp.json()
    assert "events" in data


@pytest.mark.asyncio
async def test_events_by_module(client):
    resp = await client.get("/api/v1/events", params={"module": "stake"})
    assert resp.status_code == 200
    data = resp.json()
    assert "events" in data
