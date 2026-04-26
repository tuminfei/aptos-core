import pytest
from app.models.watchlist import add_address, get_addresses, get_all_addresses, remove_address


@pytest.mark.asyncio
async def test_watchlist_crud():
    wid = await add_address("user", "0xaaa", "test user")
    assert wid > 0

    items = await get_addresses("user")
    assert len(items) >= 1
    assert any(i["address"] == "0xaaa" for i in items)

    await remove_address("user", "0xaaa")
    items = await get_addresses("user")
    assert not any(i["address"] == "0xaaa" for i in items)


@pytest.mark.asyncio
async def test_watchlist_api(client):
    resp = await client.post("/api/v1/watchlist", json={"kind": "validator", "address": "0x1234", "label": "test"})
    assert resp.status_code == 200
    assert resp.json()["success"] is True

    resp = await client.get("/api/v1/watchlist", params={"kind": "validator"})
    assert resp.status_code == 200
    assert resp.json()["total"] >= 1

    resp = await client.delete("/api/v1/watchlist/validator/0x1234")
    assert resp.status_code == 200
