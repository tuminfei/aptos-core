import io
import json
import urllib.request

import yaml

from app.config import _detect_api_info, load_settings


class _FakeResponse:
    def __init__(self, payload: dict):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self) -> bytes:
        return json.dumps(self._payload).encode("utf-8")


def _write_node_yaml(path, *, address: str, full_node: bool = False) -> None:
    path.mkdir(parents=True)
    data = {"api": {"address": address}}
    if full_node:
        data["base"] = {"role": "full_node"}
    else:
        data["consensus"] = {}
        data["validator_network"] = {}
    (path / "node.yaml").write_text(yaml.safe_dump(data), encoding="utf-8")


def test_detect_api_info_prefers_validator_for_transactions(tmp_path, monkeypatch):
    _write_node_yaml(tmp_path / "0", address="127.0.0.1:39417")
    _write_node_yaml(tmp_path / "4", address="0.0.0.0:39090", full_node=True)

    ledgers = {
        "http://127.0.0.1:39417/v1": {
            "chain_id": 164,
            "ledger_version": "100",
            "node_role": "validator",
        },
        "http://127.0.0.1:39090/v1": {
            "chain_id": 164,
            "ledger_version": "200",
            "node_role": "full_node",
        },
    }

    def fake_urlopen(url, timeout=1.0):
        return _FakeResponse(ledgers[url])

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    api_info = _detect_api_info(str(tmp_path))

    assert api_info is not None
    assert api_info.url == "http://127.0.0.1:39417/v1"
    assert api_info.chain_id == 164


def test_detect_api_info_falls_back_to_fullnode_when_no_validator_alive(tmp_path, monkeypatch):
    _write_node_yaml(tmp_path / "0", address="127.0.0.1:39417")
    _write_node_yaml(tmp_path / "4", address="0.0.0.0:39090", full_node=True)

    def fake_urlopen(url, timeout=1.0):
        if url == "http://127.0.0.1:39417/v1":
            raise urllib.error.URLError("connection refused")
        return _FakeResponse({
            "chain_id": 164,
            "ledger_version": "200",
            "node_role": "full_node",
        })

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    api_info = _detect_api_info(str(tmp_path))

    assert api_info is not None
    assert api_info.url == "http://127.0.0.1:39090/v1"
    assert api_info.chain_id == 164


def test_explicit_rest_url_is_not_overridden_by_cluster_detection(tmp_path, monkeypatch):
    _write_node_yaml(tmp_path / "0", address="127.0.0.1:39417")
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        yaml.safe_dump({
            "cluster_dir": str(tmp_path),
            "chain": {"rest_url": "http://127.0.0.1:39091/v1"},
        }),
        encoding="utf-8",
    )

    def fail_urlopen(url, timeout=1.0):
        raise AssertionError("cluster API detection should not run when rest_url is explicit")

    monkeypatch.setattr(urllib.request, "urlopen", fail_urlopen)

    settings = load_settings(str(config_path))

    assert settings.chain.rest_url == "http://127.0.0.1:39091/v1"


def test_load_settings_reads_dashboard_frontend_config(tmp_path):
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        yaml.safe_dump({
            "server": {"host": "127.0.0.1", "port": 48000},
            "power_writeback": {
                "enabled": True,
                "interval_secs": 30,
                "max_users_per_run": 25,
            },
            "frontend": {
                "host": "127.0.0.1",
                "port": 45173,
                "backend_url": "http://127.0.0.1:48000",
            },
            "test_cluster": {
                "port_start": 46180,
                "base_node_count": 5,
                "target_validator_count": 8,
                "power_period_in_epochs": 6,
            },
        }),
        encoding="utf-8",
    )

    settings = load_settings(str(config_path))

    assert settings.server.host == "127.0.0.1"
    assert settings.server.port == 48000
    assert settings.power_writeback.enabled is True
    assert settings.power_writeback.interval_secs == 30
    assert settings.power_writeback.max_users_per_run == 25
    assert settings.frontend.host == "127.0.0.1"
    assert settings.frontend.port == 45173
    assert settings.frontend.backend_url == "http://127.0.0.1:48000"
    assert settings.test_cluster.port_start == 46180
    assert settings.test_cluster.base_node_count == 5
    assert settings.test_cluster.target_validator_count == 8
    assert settings.test_cluster.power_period_in_epochs == 6


def test_empty_rest_url_derives_from_test_cluster_port_start(tmp_path):
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        yaml.safe_dump({
            "chain": {"rest_url": ""},
            "test_cluster": {"port_start": 47180},
        }),
        encoding="utf-8",
    )

    settings = load_settings(str(config_path))

    assert settings.chain.rest_url == "http://127.0.0.1:47183/v1"
