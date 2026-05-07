import pytest
from app.services import dapp_svc


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
    assert data["staking"]["min_active_power"] == 1
    assert data["staking"]["force_exit_power_bps"] == 8000
    assert data["staking_config"]["minimum_stake"] == "1000"
    assert data["staking_config"]["maximum_stake"] == "1000000"
    assert data["staking_config"]["recurring_lockup_duration_secs"] == 604800
    assert data["staking_config"]["voting_power_increase_limit"] == 20
    assert data["staking_rewards_config"]["rewards_rate_period_in_secs"] == 31536000
    assert data["periodical_reward_rate_decrease_enabled"] is True
    assert data["reward_rate"]["numerator"] == 1
    assert data["reward_rate"]["denominator"] == 100
    assert data["power"]["power_period_in_epochs"] == 5


@pytest.mark.asyncio
async def test_set_staking_config_script_args(client, monkeypatch):
    calls = []

    async def fake_run(script_name, **kwargs):
        calls.append({"script_name": script_name, **kwargs})
        return "cli:set-staking-config"

    monkeypatch.setattr(dapp_svc, "run_poc_framework_script", fake_run)

    resp = await client.post(
        "/api/v1/governance/set-staking-config",
        json={
            "minimum_stake": 100,
            "maximum_stake": 1000,
            "recurring_lockup_duration_secs": 3600,
            "voting_power_increase_limit": 10,
        },
    )

    assert resp.status_code == 200
    assert calls[0]["script_name"] == "set_staking_config.move"
    assert calls[0]["args"] == ["u64:100", "u64:1000", "u64:3600", "u64:10"]


@pytest.mark.asyncio
async def test_set_staking_config_rejects_invalid_range(client):
    resp = await client.post(
        "/api/v1/governance/set-staking-config",
        json={
            "minimum_stake": 1001,
            "maximum_stake": 1000,
            "recurring_lockup_duration_secs": 3600,
            "voting_power_increase_limit": 10,
        },
    )

    assert resp.status_code == 400
    assert "minimum_stake" in resp.json()["message"]


@pytest.mark.asyncio
async def test_set_staking_config_rejects_u64_overflow(client):
    resp = await client.post(
        "/api/v1/governance/set-staking-config",
        json={
            "minimum_stake": 1,
            "maximum_stake": 18446744073709551616,
            "recurring_lockup_duration_secs": 3600,
            "voting_power_increase_limit": 10,
        },
    )

    assert resp.status_code == 400
    assert "u64" in resp.json()["message"]


@pytest.mark.asyncio
async def test_set_staking_rewards_config_uses_current_period(client, monkeypatch):
    calls = []

    async def fake_run(script_name, **kwargs):
        calls.append({"script_name": script_name, **kwargs})
        return "cli:set-staking-rewards-config"

    monkeypatch.setattr(dapp_svc, "run_poc_framework_script", fake_run)

    resp = await client.post(
        "/api/v1/governance/set-staking-rewards-config",
        json={
            "rewards_rate_numerator": 10000,
            "rewards_rate_denominator": 1000000000,
            "min_rewards_rate_numerator": 0,
            "min_rewards_rate_denominator": 1000000000,
            "rewards_rate_decrease_rate_numerator": 0,
            "rewards_rate_decrease_rate_denominator": 1000000000,
        },
    )

    assert resp.status_code == 200
    assert calls[0]["script_name"] == "set_staking_rewards_config.move"
    assert calls[0]["args"] == [
        "u128:10000",
        "u128:1000000000",
        "u128:0",
        "u128:1000000000",
        "u128:0",
        "u128:1000000000",
        "u64:31536000",
    ]


@pytest.mark.asyncio
async def test_set_staking_rewards_config_rejects_min_above_reward(client):
    resp = await client.post(
        "/api/v1/governance/set-staking-rewards-config",
        json={
            "rewards_rate_numerator": 1,
            "rewards_rate_denominator": 1000,
            "min_rewards_rate_numerator": 2,
            "min_rewards_rate_denominator": 1000,
            "rewards_rate_decrease_rate_numerator": 0,
            "rewards_rate_decrease_rate_denominator": 1000,
        },
    )

    assert resp.status_code == 400
    assert "min_rewards_rate" in resp.json()["message"]


@pytest.mark.asyncio
async def test_set_staking_reward_rate_script_args(client, monkeypatch):
    calls = []

    async def fake_run(script_name, **kwargs):
        calls.append({"script_name": script_name, **kwargs})
        return "cli:set-staking-reward-rate"

    monkeypatch.setattr(dapp_svc, "run_poc_framework_script", fake_run)

    resp = await client.post(
        "/api/v1/governance/set-staking-reward-rate",
        json={"new_rewards_rate": 10000, "new_rewards_rate_denominator": 1000000000},
    )

    assert resp.status_code == 200
    assert calls[0]["script_name"] == "set_staking_reward_rate.move"
    assert calls[0]["args"] == ["u64:10000", "u64:1000000000"]
