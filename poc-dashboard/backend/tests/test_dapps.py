import pytest

from app.chain.keys import get_key_manager
from app.models import dapp_demo, watchlist


@pytest.mark.asyncio
async def test_list_dapps_includes_registry_and_demo_config(client):
    await watchlist.add_address("dapp", "0xddd", "demo")
    await dapp_demo.upsert_config(
        app_admin="0xddd",
        module_address="0xabc",
        label="demo",
        metadata_uri="https://demo",
        initial_supply=100,
        price_per_equity=2,
        auto_whitelist=True,
    )

    resp = await client.get("/api/v1/dapps")
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    app = data["apps"][0]
    assert app["app_admin"] == "0xddd"
    assert app["demo"]["module_address"] == "0xabc"
    assert app["poc_listing_status_code"] == 2


@pytest.mark.asyncio
async def test_dapp_admin_actions_use_managed_admin_key(client, mock_client):
    km = get_key_manager()
    key, address = km.generate_account("dapp-admin")
    await km.persist_key(key, address, "dapp-admin")

    resp = await client.post("/api/v1/dapps/pause", json={"app_admin": address})
    assert resp.status_code == 200
    tx = mock_client.submitted_txns[-1]
    assert tx["sender"] == address
    assert tx["payload"]["function"] == "0x1::poc_registry::pause_app"


@pytest.mark.asyncio
async def test_set_poc_status_uses_core_resources(client, mock_client):
    resp = await client.post("/api/v1/dapps/set-poc-status", json={"app_admin": "0xddd", "status": 2})
    assert resp.status_code == 200
    tx = mock_client.submitted_txns[-1]
    assert tx["sender"] == "0xa550c18"
    assert tx["payload"]["function"] == "0x1::poc_registry::set_poc_listing_status"
    assert tx["payload"]["arguments"] == ["0xddd", "2"]


@pytest.mark.asyncio
async def test_demo_buy_equity_uses_configured_module(client, mock_client):
    km = get_key_manager()
    key, buyer = km.generate_account("buyer")
    await km.persist_key(key, buyer, "buyer")
    await dapp_demo.upsert_config(
        app_admin="0xddd",
        module_address="0xabc",
        initial_supply=100,
        price_per_equity=2,
    )

    resp = await client.post(
        "/api/v1/dapps/demo/buy-equity",
        json={
            "app_admin": "0xddd",
            "buyer_address": buyer,
            "equity_amount": 7,
            "mint_octas": 0,
        },
    )
    assert resp.status_code == 200
    tx = mock_client.submitted_txns[-1]
    assert tx["sender"] == buyer
    assert tx["payload"]["function"] == "0xabc::poc_demo::buy_equity"
    assert tx["payload"]["arguments"] == ["0xddd", "7"]
