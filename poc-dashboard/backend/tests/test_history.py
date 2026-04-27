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
    assert sample["users"] == 1
    assert sample["validators"] >= 1

    chain_resp = await client.get("/api/v1/history/chain")
    assert chain_resp.status_code == 200
    chain_history = chain_resp.json()["history"]
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

    validator_resp = await client.get("/api/v1/history/validators/0x1a2b")
    assert validator_resp.status_code == 200
    validator_data = validator_resp.json()
    assert validator_data["total"] == 1
    assert validator_data["history"][0]["voting_power"] == 10000
    assert validator_data["history"][0]["delegator_count"] == 5
    assert validator_data["cumulative_rewards"]["epochs"] == 1
