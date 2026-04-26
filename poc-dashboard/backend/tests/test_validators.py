import pytest


@pytest.mark.asyncio
async def test_list_validators(client):
    resp = await client.get("/api/v1/validators")
    assert resp.status_code == 200
    data = resp.json()
    assert "total" in data
    assert "validators" in data
    assert data["total"] > 0
    v = data["validators"][0]
    assert "address" in v
    assert "status" in v
    assert "voting_power" in v
    assert "rewards" in v
    assert v["rewards"]["auto_compound"] is True
    assert v["rewards"]["estimated_epoch_total_octas"] > 0


@pytest.mark.asyncio
async def test_list_validators_by_status(client):
    resp = await client.get("/api/v1/validators", params={"status": "active"})
    assert resp.status_code == 200
    data = resp.json()
    for v in data["validators"]:
        assert v["status"] == "active"


@pytest.mark.asyncio
async def test_validator_detail(client):
    resp = await client.get("/api/v1/validators/0x1a2b")
    assert resp.status_code == 200
    data = resp.json()
    assert data["address"] == "0x1a2b"
    assert "pool" in data
    assert "stake" in data
    assert "proposals_successful" in data
    assert "rewards" in data
    assert data["rewards"]["reward_rate"]["bps"] == 100
    assert data["rewards"]["pending_fee_octas"] == 110000000
    assert data["pool"]["delegators"][0]["estimated_epoch_total_octas"] > 0
