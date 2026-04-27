import os
import glob
import json
import urllib.request
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


class DatabaseConfig(BaseModel):
    path: str = "./poc_dashboard.db"


class Settings(BaseModel):
    chain: ChainConfig = ChainConfig()
    keys: KeysConfig = KeysConfig(core_resources=KeyEntry(private_key="0x0", address="0x0"))
    server: ServerConfig = ServerConfig()
    database: DatabaseConfig = DatabaseConfig()
    cluster_dir: str = ""


_settings: Optional[Settings] = None


# The cluster script uses this hardcoded default private key for core_resources.
# layout.yaml only stores the public key, so we need the private key separately.
DEFAULT_ROOT_PRIVATE_KEY = "0xD04470F43AB6AEAA4EB616B72128881EEF77346F2075FFE68E14BA7DEBD8095E"


class ClusterInfo:
    def __init__(self):
        self.keys: KeysConfig | None = None
        self.chain_id: int | None = None


def _load_cluster(cluster_dir: str) -> ClusterInfo | None:
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
        address="0xa550c18",
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


def _detect_api_url(cluster_dir: str) -> str | None:
    candidates: list[str] = []
    for node_yaml in sorted(glob.glob(os.path.join(cluster_dir, "nodes", "*", "node.yaml"))):
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
            candidates.append(f"http://{addr}/v1")

    if not candidates:
        return None

    latest_url = None
    latest_version = -1
    for url in candidates:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                ledger = json.loads(resp.read().decode("utf-8"))
            version = int(ledger.get("ledger_version", 0))
        except Exception:
            continue
        if version > latest_version:
            latest_url = url
            latest_version = version

    return latest_url or candidates[0]


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

        api_url = _detect_api_url(cluster_dir)
        if api_url:
            chain_config.rest_url = api_url
            print(f"[config] 从集群 node.yaml 读取 API 地址: {api_url}")

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
        database=DatabaseConfig(**raw.get("database", {})),
        cluster_dir=cluster_dir,
    )
    return _settings


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        load_settings()
    return _settings
