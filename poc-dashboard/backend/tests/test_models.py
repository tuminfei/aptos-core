import pytest
from app.models.db import get_db
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


@pytest.mark.asyncio
async def test_generate_account_persists_key_and_watchlist(client):
    resp = await client.post("/api/v1/watchlist/generate-account", json={"kind": "user", "label": "alice"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["success"] is True
    assert data["address"].startswith("0x")
    assert data["private_key"].startswith("0x")
    assert data["public_key"].startswith("0x")

    items = await get_addresses("user")
    assert any(i["address"] == data["address"] and i["label"] == "alice" for i in items)

    db = await get_db()
    rows = await db.execute_fetchall(
        "SELECT private_key, label FROM managed_keys WHERE address = ?",
        (data["address"],),
    )
    assert len(rows) == 1
    assert rows[0][0] == data["private_key"]
    assert rows[0][1] == "alice"


@pytest.mark.asyncio
async def test_watched_users_include_validator_addresses(client):
    await add_address("validator", "0x1a2b", "validator-a")

    resp = await client.get("/api/v1/watchlist/users")

    assert resp.status_code == 200
    users = resp.json()["users"]
    validator_user = next(item for item in users if item["address"] == "0x1a2b")
    assert validator_user["is_validator_user"] is True
    assert validator_user["in_validator_watchlist"] is True
    assert validator_user["label"] == "validator-a"
    assert validator_user["display_name"] == "validator-a"


@pytest.mark.asyncio
async def test_update_watchlist_label_updates_user_display_name(client):
    await add_address("user", "0xaaa", "alice")

    resp = await client.put("/api/v1/watchlist/user/0xaaa/label", json={"label": "alice-new"})

    assert resp.status_code == 200
    assert resp.json()["label"] == "alice-new"

    users_resp = await client.get("/api/v1/watchlist/users")
    user = next(item for item in users_resp.json()["users"] if item["address"] == "0xaaa")
    assert user["label"] == "alice-new"
    assert user["display_name"] == "alice-new"


@pytest.mark.asyncio
async def test_address_book_matches_padded_and_unpadded_addresses(client):
    padded = "0x0abc"
    unpadded = "0xabc"
    await add_address("user", padded, "alice")

    resp = await client.get("/api/v1/address-book")

    assert resp.status_code == 200
    entries = resp.json()["entries"]
    assert entries[padded]["display_name"] == "alice"
    assert entries[unpadded]["display_name"] == "alice"


@pytest.mark.asyncio
async def test_chain_validator_gets_default_display_name(client):
    resp = await client.get("/api/v1/watchlist/validators")

    assert resp.status_code == 200
    validator = next(item for item in resp.json()["validators"] if item["address"] == "0x1a2b")
    assert validator["display_name"] == "验证者0"
