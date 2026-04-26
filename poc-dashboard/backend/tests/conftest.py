import pytest
import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from httpx import AsyncClient, ASGITransport
from tests.mock_chain import MockChainClient
from app.models.db import init_db, close_db, _db
from app.chain import client as chain_client_module
from app.chain import keys as keys_module


@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest.fixture(autouse=True)
async def setup_db(tmp_path_factory):
    db_path = str(tmp_path_factory.mktemp("data") / "test.db")
    await init_db(db_path)
    yield
    await close_db()


@pytest.fixture
def mock_client():
    return MockChainClient()


@pytest.fixture(autouse=True)
def patch_chain_client(mock_client, monkeypatch):
    monkeypatch.setattr(chain_client_module, "_chain_client", mock_client)
    monkeypatch.setattr(chain_client_module, "get_chain_client", lambda: mock_client)
    for module_name in (
        "app.api.dashboard",
        "app.api.users",
        "app.api.validators",
        "app.api.watchlist",
        "app.api.topo",
        "app.api.power",
        "app.api.governance",
        "app.api.staking",
    ):
        module = __import__(module_name, fromlist=["get_chain_client"])
        monkeypatch.setattr(module, "get_chain_client", lambda: mock_client)

    km = keys_module.KeyManager()
    km.core_resources_address = "0xa550c18"
    from app.chain.keys import Ed25519Key
    import nacl.signing
    sk = nacl.signing.SigningKey.generate()
    key = Ed25519Key.__new__(Ed25519Key)
    key._signing_key = sk
    km.core_resources_key = key
    km.operator_keys = {"validator-0": key}
    km.operator_addresses = {"validator-0": "0x1a2b"}
    monkeypatch.setattr(keys_module, "_key_manager", km)
    monkeypatch.setattr(keys_module, "get_key_manager", lambda: km)


@pytest.fixture
async def client():
    from main import app
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac
