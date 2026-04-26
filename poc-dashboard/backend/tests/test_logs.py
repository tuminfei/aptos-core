import pytest
from app.models.operation_log import create_log, get_logs


@pytest.mark.asyncio
async def test_create_and_query_logs(client):
    await create_log("stage_power", "0xaaa", {"power": 5000}, "0xtx1", "success")
    await create_log("mint_topo", "0xbbb", {"amount": 1000}, None, "failed", "VM error")

    total, logs = await get_logs()
    assert total == 2
    assert logs[0]["action"] == "mint_topo"
    assert logs[0]["status"] == "failed"
    assert logs[1]["action"] == "stage_power"


@pytest.mark.asyncio
async def test_logs_api(client):
    await create_log("test_action", "0xccc", None, "0xtx2", "success")
    resp = await client.get("/api/v1/logs")
    assert resp.status_code == 200
    data = resp.json()
    assert "total" in data
    assert "logs" in data


@pytest.mark.asyncio
async def test_logs_filter(client):
    await create_log("deposit", "0xddd", None, "0xtx3", "success")
    await create_log("withdraw", "0xeee", None, None, "failed", "err")

    resp = await client.get("/api/v1/logs", params={"action": "deposit"})
    assert resp.status_code == 200
    data = resp.json()
    for log in data["logs"]:
        assert log["action"] == "deposit"
