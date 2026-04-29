import pytest


@pytest.mark.asyncio
async def test_history_sample_and_query(client):
    await client.post("/api/v1/watchlist", json={"kind": "user", "address": "0xaaa", "label": "alice"})
    await client.post("/api/v1/watchlist", json={"kind": "validator", "address": "0x1a2b", "label": "validator-a"})

    sample_resp = await client.post("/api/v1/history/sample")
    assert sample_resp.status_code == 200
    sample = sample_resp.json()
    assert sample["success"] is True
    assert sample["epoch"] == 142
    assert sample["users"] >= 4
    assert sample["validators"] >= 1

    chain_resp = await client.get("/api/v1/history/chain")
    assert chain_resp.status_code == 200
    chain_data = chain_resp.json()
    chain_history = chain_data["history"]
    assert chain_data["total"] == 1
    assert chain_data["limit"] == 200
    assert chain_data["offset"] == 0
    assert len(chain_history) == 1
    assert chain_history[0]["active_validator_count"] == 4
    assert chain_history[0]["total_staked_power"] == 40000

    user_resp = await client.get("/api/v1/history/users/0xaaa")
    assert user_resp.status_code == 200
    user_data = user_resp.json()
    assert user_data["total"] == 1
    assert user_data["history"][0]["committed_power"] == 5000
    assert user_data["history"][0]["deposit_octas"] == 50000000000
    assert user_data["cumulative_rewards"]["epochs"] == 1
    assert user_data["cumulative_rewards"]["total_estimated_reward_octas"] > 0
    assert sample["user_power_periods"] >= 2

    power_period_resp = await client.get("/api/v1/history/users/0xaaa/power-periods")
    assert power_period_resp.status_code == 200
    power_period_data = power_period_resp.json()
    assert power_period_data["total"] == 2
    raw_by_period = {row["period"]: row["raw_power"] for row in power_period_data["history"]}
    assert raw_by_period[20] == 4000
    assert raw_by_period[23] == 5000

    validator_resp = await client.get("/api/v1/history/validators/0x1a2b")
    assert validator_resp.status_code == 200
    validator_data = validator_resp.json()
    assert validator_data["total"] == 1
    assert validator_data["history"][0]["voting_power"] == 10000
    assert validator_data["history"][0]["delegator_count"] == 5
    assert validator_data["cumulative_rewards"]["epochs"] == 1


@pytest.mark.asyncio
async def test_history_window_pagination(client):
    await client.post("/api/v1/watchlist", json={"kind": "user", "address": "0xaaa", "label": "alice"})

    for _ in range(3):
        resp = await client.post("/api/v1/history/sample")
        assert resp.status_code == 200

    first_page_resp = await client.get("/api/v1/history/chain", params={"limit": 2})
    assert first_page_resp.status_code == 200
    first_page = first_page_resp.json()
    assert first_page["total"] == 3
    assert first_page["limit"] == 2
    assert first_page["offset"] == 0
    assert len(first_page["history"]) == 2
    assert first_page["history"][0]["id"] < first_page["history"][1]["id"]

    older_page_resp = await client.get("/api/v1/history/chain", params={"limit": 2, "offset": 2})
    assert older_page_resp.status_code == 200
    older_page = older_page_resp.json()
    assert older_page["total"] == 3
    assert older_page["offset"] == 2
    assert len(older_page["history"]) == 1
    assert older_page["history"][0]["id"] < first_page["history"][0]["id"]

    user_page_resp = await client.get("/api/v1/history/users/0xaaa", params={"limit": 2, "offset": 1})
    assert user_page_resp.status_code == 200
    user_page = user_page_resp.json()
    assert user_page["total"] == 3
    assert user_page["limit"] == 2
    assert user_page["offset"] == 1
    assert len(user_page["history"]) == 2
