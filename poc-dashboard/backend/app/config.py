import os
import glob
import json
import urllib.request
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit
from typing import Optional
from pydantic import BaseModel
import yaml


class ChainConfig(BaseModel):
    rest_url: str = "http://127.0.0.1:36183/v1"
    chain_id: int = 4


class KeyEntry(BaseModel):
    private_key: str
    address: str
    name: str = ""


class KeysConfig(BaseModel):
    core_resources: KeyEntry
    operators: list[KeyEntry] = []


class ServerConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = 38000
    poll_interval_secs: int = 5
    history_sampler_enabled: bool = True
    history_sampler_interval_secs: int = 60


class PowerWritebackConfig(BaseModel):
    enabled: bool = False
    interval_secs: int = 60
    max_users_per_run: int = 1000
    max_gas: int = 400_000
    gas_unit_price: int = 100


class FrontendConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = 35173
    backend_url: str = ""


class TestClusterConfig(BaseModel):
    port_start: int = 36180
    base_node_count: int = 4
    target_validator_count: int = 7
    users_per_new_validator: int = 5
    power_period_in_epochs: int = 5
    epoch_duration_secs: int = 60
    validator_lockup_periods: int = 2
    governance_voting_periods: int = 1
    min_validator_stake: int = 1000000000
    validator_stake_multiplier: int = 10
    user_stake_multiplier: int = 5
    validator_commission_bps: int = 0
    validator_force_epochs_after_join: int = 1
    user_force_epoch: bool = True
    wait_timeout_secs: int = 180
    poll_interval_secs: int = 2


class DatabaseConfig(BaseModel):
    path: str = "./poc_dashboard.db"


class Settings(BaseModel):
    chain: ChainConfig = ChainConfig()
    keys: KeysConfig = KeysConfig(core_resources=KeyEntry(private_key="0x0", address="0x0"))
    server: ServerConfig = ServerConfig()
    power_writeback: PowerWritebackConfig = PowerWritebackConfig()
    frontend: FrontendConfig = FrontendConfig()
    test_cluster: TestClusterConfig = TestClusterConfig()
    database: DatabaseConfig = DatabaseConfig()
    cluster_dir: str = ""


_settings: Optional[Settings] = None


# The cluster script uses this hardcoded default private key for core_resources.
# layout.yaml only stores the public key, so we need the private key separately.
DEFAULT_ROOT_PRIVATE_KEY = "0xD04470F43AB6AEAA4EB616B72128881EEF77346F2075FFE68E14BA7DEBD8095E"
CORE_RESOURCES_ADDRESS = "0xa550c18"


class ClusterInfo:
    def __init__(self):
        self.keys: KeysConfig | None = None
        self.chain_id: int | None = None


@dataclass
class ApiInfo:
    url: str
    chain_id: int | None = None


def _load_cluster(cluster_dir: str) -> ClusterInfo | None:
    info = _load_layout_cluster(cluster_dir)
    if info:
        return info
    return _load_node_dir_cluster(cluster_dir)


def _load_layout_cluster(cluster_dir: str) -> ClusterInfo | None:
    layout_path = os.path.join(cluster_dir, "genesis-workspace", "layout.yaml")
    if not os.path.exists(layout_path):
        return None

    with open(layout_path) as f:
        layout = yaml.safe_load(f)

    info = ClusterInfo()
    info.chain_id = layout.get("chain_id")

    # layout.yaml stores the PUBLIC key as root_key.
    # The actual private key is either in config.yaml or the hardcoded default.
    core_resources = KeyEntry(
        private_key=DEFAULT_ROOT_PRIVATE_KEY,
        address=CORE_RESOURCES_ADDRESS,
        name="core_resources",
    )

    operators = []
    users_dir = os.path.join(cluster_dir, "users")
    if os.path.isdir(users_dir):
        for vdir in sorted(glob.glob(os.path.join(users_dir, "validator-*"))):
            name = os.path.basename(vdir)
            pk_path = os.path.join(vdir, "private-keys.yaml")
            if not os.path.exists(pk_path):
                continue
            with open(pk_path) as f:
                pk_data = yaml.safe_load(f)
            operators.append(KeyEntry(
                private_key=pk_data.get("account_private_key", "0x0"),
                address="0x" + pk_data.get("account_address", "0"),
                name=name,
            ))

    info.keys = KeysConfig(core_resources=core_resources, operators=operators)
    return info


def _load_node_dir_cluster(cluster_dir: str) -> ClusterInfo | None:
    node_paths = _node_yaml_paths(cluster_dir)
    root_key = _read_root_private_key(cluster_dir)
    operators: list[KeyEntry] = []

    for node_yaml in node_paths:
        try:
            with open(node_yaml) as f:
                node_cfg = yaml.safe_load(f) or {}
        except Exception:
            continue

        if _node_role(node_cfg) == "full_node":
            continue

        node_dir = os.path.dirname(node_yaml)
        identity_path = _validator_identity_path(node_cfg, node_dir)
        if not identity_path or not os.path.exists(identity_path):
            continue

        try:
            with open(identity_path) as f:
                identity = yaml.safe_load(f) or {}
        except Exception:
            continue

        private_key = _normalize_hex(identity.get("account_private_key", ""))
        address = _normalize_address(identity.get("account_address", ""))
        if not private_key or not address:
            continue

        node_name = os.path.basename(node_dir)
        name = f"validator-{node_name}" if node_name.isdigit() else node_name
        operators.append(KeyEntry(private_key=private_key, address=address, name=name))

    if not root_key and not operators:
        return None

    info = ClusterInfo()
    info.keys = KeysConfig(
        core_resources=KeyEntry(
            private_key=root_key or DEFAULT_ROOT_PRIVATE_KEY,
            address=CORE_RESOURCES_ADDRESS,
            name="core_resources",
        ),
        operators=operators,
    )
    return info


def _read_root_private_key(cluster_dir: str) -> str | None:
    text_path = os.path.join(cluster_dir, "root_key")
    if os.path.exists(text_path):
        try:
            with open(text_path) as f:
                key = _normalize_hex(f.read())
            if key:
                return key
        except Exception:
            pass

    bin_path = os.path.join(cluster_dir, "root_key.bin")
    if os.path.exists(bin_path):
        try:
            with open(bin_path, "rb") as f:
                data = f.read()
            if data.endswith(b"\n"):
                data = data[:-1]
            if data:
                return "0x" + data.hex()
        except Exception:
            pass

    return None


def _normalize_hex(value: object) -> str:
    text = str(value or "").strip().strip('"').strip("'")
    if text.startswith(("0x", "0X")):
        text = text[2:]
    if not text:
        return ""
    return "0x" + text.lower()


def _normalize_address(value: object) -> str:
    return _normalize_hex(value)


def _node_yaml_paths(cluster_dir: str) -> list[str]:
    patterns = [
        os.path.join(cluster_dir, "node.yaml"),
        os.path.join(cluster_dir, "nodes", "*", "node.yaml"),
        os.path.join(cluster_dir, "*", "node.yaml"),
    ]
    seen: set[str] = set()
    paths: list[str] = []
    for pattern in patterns:
        for path in glob.glob(pattern):
            if path not in seen:
                seen.add(path)
                paths.append(path)
    return sorted(paths, key=_node_path_sort_key)


def _node_path_sort_key(path: str) -> tuple[str, int, str]:
    name = os.path.basename(os.path.dirname(path))
    return ("", int(name), path) if name.isdigit() else (name, -1, path)


def _node_role(node_cfg: dict) -> str:
    role = str((node_cfg.get("base") or {}).get("role") or "").lower()
    if role:
        return role
    return "validator" if node_cfg.get("validator_network") or node_cfg.get("consensus") else ""


def _validator_identity_path(node_cfg: dict, node_dir: str) -> str:
    safety_rules = ((node_cfg.get("consensus") or {}).get("safety_rules") or {})
    initial_config = safety_rules.get("initial_safety_rules_config") or {}
    from_file = initial_config.get("from_file") or {}
    identity_path = from_file.get("identity_blob_path")
    if identity_path:
        return identity_path
    return os.path.join(node_dir, "validator-identity.yaml")


def _detect_api_info(cluster_dir: str) -> ApiInfo | None:
    candidates: list[tuple[str, str]] = []
    for node_yaml in _node_yaml_paths(cluster_dir):
        try:
            with open(node_yaml) as f:
                node_cfg = yaml.safe_load(f) or {}
        except Exception:
            continue
        api_cfg = node_cfg.get("api", {})
        if not api_cfg.get("enabled", True):
            continue
        addr = api_cfg.get("address", "")
        if addr:
            candidates.append((_client_url_from_bind_address(addr), _node_role(node_cfg)))

    if not candidates:
        return None

    validator_best: tuple[int, ApiInfo] | None = None
    fallback_best: tuple[int, ApiInfo] | None = None
    for url, configured_role in candidates:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                ledger = json.loads(resp.read().decode("utf-8"))
            version = int(ledger.get("ledger_version", 0))
            role = str(ledger.get("node_role") or configured_role or "").lower()
            chain_id = int(ledger["chain_id"]) if ledger.get("chain_id") is not None else None
        except Exception:
            continue
        api_info = ApiInfo(url=url, chain_id=chain_id)
        if role == "full_node":
            if fallback_best is None or version > fallback_best[0]:
                fallback_best = (version, api_info)
            continue
        # The dashboard uses this singleton client for transaction submission.
        # Prefer a validator API when available; fullnodes can lag or keep txs pending.
        if validator_best is None or version > validator_best[0]:
            validator_best = (version, api_info)

    if validator_best:
        return validator_best[1]
    if fallback_best:
        return fallback_best[1]

    for url, configured_role in candidates:
        if configured_role != "full_node":
            return ApiInfo(url=url)
    return ApiInfo(url=candidates[0][0])


def _client_url_from_bind_address(address: str) -> str:
    host, sep, port = address.rpartition(":")
    if not sep:
        return f"http://{address}/v1"
    if host in {"0.0.0.0", "::", ""}:
        host = "127.0.0.1"
    return f"http://{host}:{port}/v1"


def _local_health_url(url: str) -> str:
    parts = urlsplit(url)
    host = parts.hostname or "127.0.0.1"
    if host in {"0.0.0.0", "::", ""}:
        host = "127.0.0.1"
    port = f":{parts.port}" if parts.port else ""
    netloc = f"{host}{port}"
    return urlunsplit((parts.scheme or "http", netloc, parts.path, parts.query, parts.fragment))


def load_settings(config_path: Optional[str] = None) -> Settings:
    global _settings
    default_paths = ["./config.yaml", "../config.yaml"]
    path = config_path or os.environ.get("CONFIG_PATH", "")
    if not path:
        for p in default_paths:
            if os.path.exists(p):
                path = p
                break
        else:
            path = default_paths[0]

    raw = {}
    if os.path.exists(path):
        with open(path) as f:
            raw = yaml.safe_load(f) or {}

    chain_raw = raw.get("chain", {})
    chain_config = ChainConfig(**chain_raw)
    explicit_rest_url = bool(str(chain_raw.get("rest_url", "")).strip())
    test_cluster_config = TestClusterConfig(**raw.get("test_cluster", {}))

    cluster_dir = raw.get("cluster_dir", "")
    if cluster_dir and not os.path.isabs(cluster_dir):
        config_base = os.path.dirname(os.path.abspath(path)) if os.path.exists(path) else os.getcwd()
        cluster_dir = os.path.normpath(os.path.join(config_base, cluster_dir))

    keys_config = None
    if cluster_dir and os.path.isdir(cluster_dir):
        cluster_info = _load_cluster(cluster_dir)
        if cluster_info:
            keys_config = cluster_info.keys
            n = len(keys_config.operators) if keys_config else 0
            print(f"[config] 从集群目录加载密钥: {cluster_dir} (core_resources + {n} operators)")

            if cluster_info.chain_id is not None:
                chain_config.chain_id = cluster_info.chain_id
                print(f"[config] 从集群 layout.yaml 读取 chain_id: {cluster_info.chain_id}")

        if explicit_rest_url:
            print(f"[config] 从配置文件读取 API 地址: {chain_config.rest_url}")
        else:
            api_info = _detect_api_info(cluster_dir)
            if api_info:
                chain_config.rest_url = api_info.url
                print(f"[config] 从集群 node.yaml 读取 API 地址: {api_info.url}")
                if api_info.chain_id is not None:
                    chain_config.chain_id = api_info.chain_id
                    print(f"[config] 从链上 ledger info 读取 chain_id: {api_info.chain_id}")

    if not explicit_rest_url and not str(chain_config.rest_url).strip():
        chain_config.rest_url = f"http://127.0.0.1:{test_cluster_config.port_start + 3}/v1"
        print(f"[config] 从 test_cluster.port_start 派生 API 地址: {chain_config.rest_url}")

    if keys_config is None:
        keys_raw = raw.get("keys", {})
        cr = keys_raw.get("core_resources", {})
        core_resources = KeyEntry(
            private_key=cr.get("private_key", "0x0"),
            address=cr.get("address", "0x0"),
            name="core_resources",
        )
        operators = []
        for op in keys_raw.get("operators", []):
            operators.append(KeyEntry(
                private_key=op.get("private_key", "0x0"),
                address=op.get("address", "0x0"),
                name=op.get("name", ""),
            ))
        keys_config = KeysConfig(core_resources=core_resources, operators=operators)

    _settings = Settings(
        chain=chain_config,
        keys=keys_config,
        server=ServerConfig(**raw.get("server", {})),
        power_writeback=PowerWritebackConfig(**raw.get("power_writeback", {})),
        frontend=FrontendConfig(**raw.get("frontend", {})),
        test_cluster=test_cluster_config,
        database=DatabaseConfig(**raw.get("database", {})),
        cluster_dir=cluster_dir,
    )
    return _settings


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        load_settings()
    return _settings
