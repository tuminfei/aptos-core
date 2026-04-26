import pytest


@pytest.mark.asyncio
async def test_governance_config(client):
    resp = await client.get("/api/v1/governance/config")
    assert resp.status_code == 200
    data = resp.json()
    assert "governance" in data
    assert "staking" in data
    assert "power" in data
    assert data["governance"]["voting_duration_secs"] == 86400
    assert data["staking"]["cooldown_secs"] == 3600
    assert data["power"]["power_period_in_epochs"] == 5
