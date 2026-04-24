#!/usr/bin/env python3
"""
Create and run a local N-validator cluster that mimics the production-style
validator bootstrap flow more closely than forge local-swarm.

Flow:
1. Prepare a local genesis ceremony workspace.
2. Generate validator identities with `aptos genesis generate-keys`.
3. Write validator entries with `aptos genesis set-validator-configuration`.
4. Copy the current framework release bundle to `framework.mrb`.
5. Generate `genesis.blob` and `waypoint.txt` with `aptos genesis generate-genesis`.
6. Materialize a local `node.yaml` for each validator.
7. Start one `aptos-node` process per validator.
8. Optionally scale out later by adding more validators post-genesis.

This is still a local single-machine cluster, but the bootstrap path follows
the same ceremony concepts used by formal deployments:
- layout
- per-validator identities
- validator host / fullnode host entries
- framework.mrb
- genesis.blob / waypoint.txt
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_NODE_COUNT = 4
DEFAULT_BASE_STAKE = 100000000000000
DEFAULT_CHAIN_ID = 4
DEFAULT_STARTUP_TIMEOUT_SECS = 240
DEFAULT_POLL_INTERVAL_SECS = 1.0
DEFAULT_WORKDIR_NAME = "prod-like-validator-cluster"
STATE_FILE_NAME = ".prod_like_validator_cluster_state.json"
FORGE_LOG_NAME = "cluster.log"
APTOS_NODE_LOG_NAME = "aptos-node.log"
DEFAULT_PORT_START = 6180
PORTS_PER_NODE = 10
LOCALHOST_IPV4 = "127.0.0.1"


@dataclass(frozen=True)
class PortLayout:
    validator_port: int
    vfn_port: int
    private_vfn_port: int
    api_port: int
    metrics_port: int
    inspection_port: int
    admin_port: int
    backup_port: int
    indexer_grpc_port: int


@dataclass(frozen=True)
class NodeRuntime:
    index: int
    username: str
    node_dir: Path
    user_dir: Path
    config_path: Path
    validator_identity_path: Path
    vfn_identity_path: Path
    ports: PortLayout

    @property
    def rest_url(self) -> str:
        return f"http://127.0.0.1:{self.ports.api_port}/v1"

    @property
    def health_url(self) -> str:
        return f"{self.rest_url}/-/healthy?duration_secs=2"

    @property
    def pid_file(self) -> Path:
        return self.node_dir / "aptos-node.pid"

    @property
    def log_file(self) -> Path:
        return self.node_dir / APTOS_NODE_LOG_NAME


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parent.parent


def default_workdir(repo_root: Path) -> Path:
    return repo_root / DEFAULT_WORKDIR_NAME


def state_file(workdir: Path) -> Path:
    return workdir / STATE_FILE_NAME


def run_command(
    cmd: Sequence[str],
    cwd: Path,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(cmd),
        cwd=cwd,
        check=check,
        text=True,
        capture_output=capture_output,
    )


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def write_yaml_like(path: Path, payload: Dict) -> None:
    def _dump(value, indent: int = 0) -> List[str]:
        prefix = " " * indent
        if isinstance(value, dict):
            if not value:
                return [f"{prefix}{{}}"]
            lines: List[str] = []
            for key, inner in value.items():
                if isinstance(inner, (dict, list)):
                    if not inner:
                        empty_literal = "{}" if isinstance(inner, dict) else "[]"
                        lines.append(f"{prefix}{key}: {empty_literal}")
                    else:
                        lines.append(f"{prefix}{key}:")
                        lines.extend(_dump(inner, indent + 2))
                else:
                    lines.append(f"{prefix}{key}: {format_yaml_scalar(inner)}")
            return lines
        if isinstance(value, list):
            if not value:
                return [f"{prefix}[]"]
            lines = []
            for item in value:
                if isinstance(item, (dict, list)):
                    lines.append(f"{prefix}-")
                    lines.extend(_dump(item, indent + 2))
                else:
                    lines.append(f"{prefix}- {format_yaml_scalar(item)}")
            return lines
        return [f"{prefix}{format_yaml_scalar(value)}"]

    write_text(path, "\n".join(_dump(payload)) + "\n")


def format_yaml_scalar(value) -> str:
    if value is None:
        return "~"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text == "" or any(ch in text for ch in [":", "#", "{", "}", "[", "]", ",", "*", "&", "!", "|", ">", "%", "@", "`"]) or text.startswith((" ", "-", "?", "~")):
        return json.dumps(text)
    return text


def parse_simple_yaml_scalars(path: Path) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        if line.startswith(" ") or line.startswith("\t"):
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip().strip('"').strip("'")
    return result


def maybe_read_json(path: Path) -> Optional[dict]:
    if not path.exists():
        return None
    return json.loads(path.read_text())


def write_json(path: Path, payload: dict) -> None:
    write_text(path, json.dumps(payload, indent=2, sort_keys=True) + "\n")


def split_host_port(text: str) -> Tuple[str, int]:
    value = text.strip()
    if value.startswith("["):
        host, _, port = value[1:].partition("]:")
        return host, int(port)
    host, _, port = value.rpartition(":")
    if not host or not port:
        raise SystemExit(f"invalid host:port: {text}")
    return host, int(port)


def parse_api_port_from_node_yaml(path: Path) -> int:
    lines = path.read_text().splitlines()
    in_api = False
    api_indent = 0
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if not in_api:
            if stripped == "api:":
                in_api = True
                api_indent = indent
            continue
        if indent <= api_indent:
            in_api = False
            if stripped == "api:":
                in_api = True
                api_indent = indent
            continue
        if stripped.startswith("address:"):
            _, raw = stripped.split(":", 1)
            _, port = split_host_port(raw.strip().strip('"').strip("'"))
            return port
    raise SystemExit(f"could not find api.address in {path}")


def ports_to_dict(ports: PortLayout) -> Dict[str, int]:
    return {
        "validator_port": ports.validator_port,
        "vfn_port": ports.vfn_port,
        "private_vfn_port": ports.private_vfn_port,
        "api_port": ports.api_port,
        "metrics_port": ports.metrics_port,
        "inspection_port": ports.inspection_port,
        "admin_port": ports.admin_port,
        "backup_port": ports.backup_port,
        "indexer_grpc_port": ports.indexer_grpc_port,
    }


def pid_files_under_workdir(workdir: Path) -> List[Path]:
    nodes_dir = workdir / "nodes"
    if not nodes_dir.exists():
        return []
    return sorted(nodes_dir.glob("*/aptos-node.pid"))


def read_log_tail(path: Path, max_lines: int = 40) -> str:
    if not path.exists():
        return f"<missing log: {path}>"
    lines = path.read_text(errors="replace").splitlines()
    if not lines:
        return "<empty log>"
    return "\n".join(lines[-max_lines:])


def read_pid_file(path: Path) -> Optional[int]:
    if not path.exists():
        return None
    try:
        return int(path.read_text().strip())
    except ValueError:
        return None


def is_pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def current_process_group_id(pid: int) -> Optional[int]:
    if not is_pid_alive(pid):
        return None
    try:
        return os.getpgid(pid)
    except ProcessLookupError:
        return None


def wait_for_pid_exit(pid: int, timeout_secs: float) -> bool:
    deadline = time.time() + timeout_secs
    while time.time() < deadline:
        if not is_pid_alive(pid):
            return True
        time.sleep(0.2)
    return not is_pid_alive(pid)


def kill_pid(pid: int, timeout_secs: float = 10.0) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    if wait_for_pid_exit(pid, timeout_secs):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return


def choose_aptos_cli(repo_root: Path, requested: Optional[str]) -> List[str]:
    if requested:
        candidate = Path(requested)
        if candidate.exists():
            return [str(candidate.resolve())]
        return [requested]

    release_bin = repo_root / "target" / "release" / "aptos"
    if release_bin.exists():
        return [str(release_bin)]

    debug_bin = repo_root / "target" / "debug" / "aptos"
    if debug_bin.exists():
        return [str(debug_bin)]

    return ["cargo", "run", "-p", "aptos", "--"]


def choose_aptos_node(repo_root: Path, requested: Optional[str]) -> Path:
    if requested:
        candidate = Path(requested)
        if candidate.exists():
            return candidate.resolve()
        raise SystemExit(f"aptos-node binary does not exist: {candidate}")

    for candidate in (
        repo_root / "target" / "debug" / "aptos-node",
        repo_root / "target" / "release" / "aptos-node",
    ):
        if candidate.exists():
            return candidate

    raise SystemExit(
        "could not find aptos-node binary; build it first, for example: cargo build -p aptos-node"
    )


def detect_framework_code_changes(repo_root: Path) -> bool:
    cmd = [
        "git",
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--",
        "aptos-move/framework/aptos-framework",
    ]
    try:
        result = run_command(cmd, cwd=repo_root, capture_output=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False

    for line in result.stdout.splitlines():
        if len(line) < 4:
            continue
        rel_path = line[3:].strip()
        if not rel_path:
            continue
        if rel_path.endswith(".md") or "/doc/" in rel_path:
            continue
        return True
    return False


def refresh_cached_packages(repo_root: Path) -> None:
    print("refreshing cached framework packages ...")
    run_command(
        ["bash", str(repo_root / "scripts" / "cargo_build_aptos_cached_packages.sh")],
        cwd=repo_root,
    )


def framework_bundle_path(repo_root: Path, requested: Optional[str]) -> Path:
    if requested:
        path = Path(requested)
        if path.exists():
            return path.resolve()
        raise SystemExit(f"framework bundle does not exist: {path}")
    default = repo_root / "aptos-move" / "framework" / "cached-packages" / "src" / "head.mrb"
    if not default.exists():
        raise SystemExit(f"default framework bundle not found: {default}")
    return default


def allocate_local_ports(node_count: int, port_start: int) -> List[PortLayout]:
    ports: List[PortLayout] = []
    for index in range(node_count):
        base = port_start + index * PORTS_PER_NODE
        values = [base + offset for offset in range(9)]
        ports.append(
            PortLayout(
                validator_port=values[0],
                vfn_port=values[1],
                private_vfn_port=values[2],
                api_port=values[3],
                metrics_port=values[4],
                inspection_port=values[5],
                admin_port=values[6],
                backup_port=values[7],
                indexer_grpc_port=values[8],
            )
        )
    return ports


def build_node(workdir: Path, index: int, ports: PortLayout) -> NodeRuntime:
    nodes_dir = workdir / "nodes"
    users_dir = workdir / "users"
    username = f"validator-{index}"
    user_dir = users_dir / username
    node_dir = nodes_dir / str(index)
    node_dir.mkdir(parents=True, exist_ok=True)
    user_dir.mkdir(parents=True, exist_ok=True)
    return NodeRuntime(
        index=index,
        username=username,
        node_dir=node_dir,
        user_dir=user_dir,
        config_path=node_dir / "node.yaml",
        validator_identity_path=user_dir / "validator-identity.yaml",
        vfn_identity_path=user_dir / "validator-full-node-identity.yaml",
        ports=ports,
    )


def prepare_layout(args: argparse.Namespace, workspace: Path) -> Path:
    layout = {
        "root_key": args.root_key,
        "users": [],
        "chain_id": args.chain_id,
        "allow_new_validators": args.allow_new_validators,
        "epoch_duration_secs": args.epoch_duration_secs,
        "is_test": True,
        "min_price_per_gas_unit": 1,
        "min_stake": args.min_stake,
        "min_voting_threshold": args.min_voting_threshold,
        "max_stake": args.max_stake,
        "recurring_lockup_duration_secs": args.recurring_lockup_duration_secs,
        "required_proposer_stake": args.required_proposer_stake,
        "rewards_apy_percentage": args.rewards_apy_percentage,
        "voting_duration_secs": args.voting_duration_secs,
        "voting_power_increase_limit": args.voting_power_increase_limit,
    }
    layout_path = workspace / "layout.yaml"
    write_yaml_like(layout_path, layout)
    return layout_path


def setup_genesis_repository(
    aptos_cli: Sequence[str],
    repo_root: Path,
    workspace: Path,
    layout_path: Path,
) -> None:
    run_command(
        list(aptos_cli)
        + [
            "genesis",
            "setup-git",
            "--local-repository-dir",
            str(workspace),
            "--layout-file",
            str(layout_path),
        ],
        cwd=repo_root,
    )


def copy_framework_bundle(framework_path: Path, workspace: Path) -> None:
    shutil.copy2(framework_path, workspace / "framework.mrb")


def build_nodes(workdir: Path, node_count: int, ports: List[PortLayout]) -> List[NodeRuntime]:
    nodes: List[NodeRuntime] = []
    for index in range(node_count):
        nodes.append(build_node(workdir, index, ports[index]))
    return nodes


def build_nodes_for_indexes(workdir: Path, indexes: Sequence[int], port_start: int) -> List[NodeRuntime]:
    if not indexes:
        return []
    ports = allocate_local_ports(max(indexes) + 1, port_start)
    return [build_node(workdir, index, ports[index]) for index in indexes]


def generate_keys(
    aptos_cli: Sequence[str],
    repo_root: Path,
    nodes: Sequence[NodeRuntime],
) -> None:
    for node in nodes:
        run_command(
            list(aptos_cli)
            + ["genesis", "generate-keys", "--output-dir", str(node.user_dir)],
            cwd=repo_root,
        )


def write_validator_configurations(
    aptos_cli: Sequence[str],
    repo_root: Path,
    workspace: Path,
    nodes: Sequence[NodeRuntime],
    base_stake: int,
    join_during_genesis: bool = True,
) -> None:
    for node in nodes:
        validator_host = f"127.0.0.1:{node.ports.validator_port}"
        fullnode_host = f"127.0.0.1:{node.ports.vfn_port}"
        cmd = list(aptos_cli) + [
            "genesis",
            "set-validator-configuration",
            "--owner-public-identity-file",
            str(node.user_dir / "public-keys.yaml"),
            "--local-repository-dir",
            str(workspace),
            "--username",
            node.username,
            "--validator-host",
            validator_host,
            "--full-node-host",
            fullnode_host,
            "--stake-amount",
            str(base_stake),
        ]
        if join_during_genesis:
            cmd.append("--join-during-genesis")
        run_command(cmd, cwd=repo_root)


def generate_genesis(
    aptos_cli: Sequence[str],
    repo_root: Path,
    workspace: Path,
) -> None:
    run_command(
        list(aptos_cli)
        + [
            "genesis",
            "generate-genesis",
            "--local-repository-dir",
            str(workspace),
            "--output-dir",
            str(workspace),
        ],
        cwd=repo_root,
    )


def materialize_node_configs(workspace: Path, nodes: Sequence[NodeRuntime]) -> None:
    genesis_blob = workspace / "genesis.blob"
    waypoint_file = workspace / "waypoint.txt"
    waypoint_text = waypoint_file.read_text().strip()

    for node in nodes:
        shutil.copy2(genesis_blob, node.node_dir / "genesis.blob")
        shutil.copy2(waypoint_file, node.node_dir / "waypoint.txt")
        shutil.copy2(node.validator_identity_path, node.node_dir / "validator-identity.yaml")
        shutil.copy2(node.vfn_identity_path, node.node_dir / "vfn-identity.yaml")
        config = build_node_config(node, waypoint_text)
        write_yaml_like(node.config_path, config)


def build_node_config(node: NodeRuntime, waypoint_text: str) -> Dict:
    return {
        "base": {
            "data_dir": str(node.node_dir),
            "role": "validator",
            "waypoint": {"from_config": waypoint_text},
        },
        "consensus": {
            "safety_rules": {
                "service": {"type": "thread"},
                "backend": {
                    "type": "on_disk_storage",
                    "path": "secure_storage.json",
                    "namespace": None,
                },
                "initial_safety_rules_config": {
                    "from_file": {
                        "waypoint": {"from_config": waypoint_text},
                        "identity_blob_path": str(node.node_dir / "validator-identity.yaml"),
                    }
                },
            }
        },
        "execution": {
            "genesis_file_location": str(node.node_dir / "genesis.blob"),
            "concurrency_level": 1,
            "num_proof_reading_threads": 1,
            "paranoid_type_verification": False,
            "paranoid_hot_potato_verification": False,
        },
        "validator_network": {
            "discovery_method": "onchain",
            "mutual_authentication": True,
            "identity": {
                "type": "from_file",
                "path": str(node.node_dir / "validator-identity.yaml"),
            },
            "listen_address": f"/ip4/{LOCALHOST_IPV4}/tcp/{node.ports.validator_port}",
            "network_id": "validator",
            "max_outbound_connections": 6,
            "max_inbound_connections": 100,
            "runtime_threads": 1,
        },
        "full_node_networks": [
            {
                "network_id": "public",
                "discovery_method": "onchain",
                "mutual_authentication": False,
                "identity": {
                    "type": "from_file",
                    "path": str(node.node_dir / "vfn-identity.yaml"),
                },
                "listen_address": f"/ip4/{LOCALHOST_IPV4}/tcp/{node.ports.vfn_port}",
                "max_outbound_connections": 0,
                "max_inbound_connections": 100,
            },
            {
                "network_id": {"private": "vfn"},
                "discovery_method": "none",
                "mutual_authentication": False,
                "identity": {
                    "type": "from_file",
                    "path": str(node.node_dir / "vfn-identity.yaml"),
                },
                "listen_address": f"/ip4/{LOCALHOST_IPV4}/tcp/{node.ports.private_vfn_port}",
                "max_outbound_connections": 0,
                "max_inbound_connections": 100,
            },
        ],
        "api": {
            "enabled": True,
            "address": f"{LOCALHOST_IPV4}:{node.ports.api_port}",
        },
        "inspection_service": {
            "address": LOCALHOST_IPV4,
            "port": node.ports.inspection_port,
        },
        "admin_service": {
            "enabled": True,
            "address": LOCALHOST_IPV4,
            "port": node.ports.admin_port,
        },
        "storage": {"backup_service_address": f"{LOCALHOST_IPV4}:{node.ports.backup_port}"},
        "indexer_grpc": {
            "enabled": False,
            "address": f"{LOCALHOST_IPV4}:{node.ports.indexer_grpc_port}",
        },
        "logger": {"level": "INFO"},
    }


def start_nodes(aptos_node_bin: Path, nodes: Sequence[NodeRuntime]) -> List[int]:
    pids: List[int] = []
    for node in nodes:
        log_handle = node.log_file.open("a", buffering=1)
        process = subprocess.Popen(
            [str(aptos_node_bin), "-f", str(node.config_path)],
            cwd=node.node_dir,
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
        )
        log_handle.close()
        node.pid_file.write_text(f"{process.pid}\n")
        pids.append(process.pid)
    return pids


def cleanup_node_processes(
    nodes: Optional[Sequence[NodeRuntime]] = None,
    workdir: Optional[Path] = None,
    pids: Optional[Iterable[int]] = None,
) -> int:
    pid_file_map: Dict[Path, int] = {}
    if nodes is not None:
        for node in nodes:
            if node.pid_file.exists():
                try:
                    pid_file_map[node.pid_file] = int(node.pid_file.read_text().strip())
                except ValueError:
                    pass
    if workdir is not None:
        for pid_file in pid_files_under_workdir(workdir):
            if pid_file in pid_file_map:
                continue
            try:
                pid_file_map[pid_file] = int(pid_file.read_text().strip())
            except ValueError:
                pass

    for pid in pids or []:
        if pid > 0:
            pid_file_map.setdefault(Path(), pid)

    killed = 0
    for pid_file, pid in pid_file_map.items():
        if is_pid_alive(pid):
            kill_pid(pid)
            killed += 1
        if pid_file != Path() and pid_file.exists():
            pid_file.unlink()
    return killed


def http_get_json(url: str, timeout_secs: float = 2.0) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout_secs) as response:
        return json.loads(response.read().decode("utf-8"))


def probe_node(node: NodeRuntime, timeout_secs: float = 2.0) -> Tuple[bool, str]:
    try:
        payload = http_get_json(node.rest_url, timeout_secs)
        chain_id = payload.get("chain_id", "?")
        epoch = payload.get("epoch", "?")
        version = payload.get("ledger_version", "?")
        return True, f"healthy chain_id={chain_id} epoch={epoch} ledger_version={version}"
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        return False, str(exc)


def wait_for_nodes_healthy(
    nodes: Sequence[NodeRuntime],
    timeout_secs: float,
    poll_interval_secs: float,
    pids: Optional[Sequence[int]] = None,
) -> None:
    pid_by_index = {
        node.index: pid for node, pid in zip(nodes, pids or [])
    }
    deadline = time.time() + timeout_secs
    failures: List[Tuple[int, str]] = []
    while time.time() < deadline:
        failures = []
        crashed = []
        for node in nodes:
            pid = pid_by_index.get(node.index)
            if pid is not None and not is_pid_alive(pid):
                crashed.append((node.index, pid, read_log_tail(node.log_file)))
                continue
            ok, detail = probe_node(node)
            if not ok:
                failures.append((node.index, detail))
        if crashed:
            raise SystemExit(
                "node processes exited before becoming healthy:\n"
                + "\n\n".join(
                    f"node {idx} pid={pid} log tail:\n{tail}" for idx, pid, tail in crashed
                )
            )
        if not failures:
            return
        time.sleep(poll_interval_secs)
    raise SystemExit(
        "timed out waiting for nodes to become healthy: "
        + ", ".join(f"node {idx}: {detail}" for idx, detail in failures)
    )


def load_state_or_exit(workdir: Path) -> dict:
    state = maybe_read_json(state_file(workdir))
    if state is None:
        raise SystemExit(f"state file does not exist: {state_file(workdir)}")
    return state


def restore_nodes_from_state(state: dict) -> List[NodeRuntime]:
    nodes: List[NodeRuntime] = []
    for item in state["nodes"]:
        ports = PortLayout(**item["ports"])
        nodes.append(
            NodeRuntime(
                index=item["index"],
                username=item["username"],
                node_dir=Path(item["node_dir"]),
                user_dir=Path(item["user_dir"]),
                config_path=Path(item["config_path"]),
                validator_identity_path=Path(item["validator_identity_path"]),
                vfn_identity_path=Path(item["vfn_identity_path"]),
                ports=ports,
            )
        )
    return nodes


def discover_nodes_from_workdir(workdir: Path) -> List[NodeRuntime]:
    nodes_dir = workdir / "nodes"
    if not nodes_dir.exists():
        return []

    discovered: List[Tuple[int, Path, int]] = []
    for node_dir in sorted(nodes_dir.iterdir(), key=lambda path: int(path.name) if path.name.isdigit() else path.name):
        if not node_dir.is_dir() or not node_dir.name.isdigit():
            continue
        index = int(node_dir.name)
        node_yaml = node_dir / "node.yaml"
        if not node_yaml.exists():
            continue
        api_port = parse_api_port_from_node_yaml(node_yaml)
        discovered.append((index, node_dir, api_port))

    if not discovered:
        return []

    inferred_port_starts = [
        api_port - 3 - index * PORTS_PER_NODE for index, _, api_port in discovered
    ]
    port_start = inferred_port_starts[0]
    for index, inferred in zip((item[0] for item in discovered), inferred_port_starts):
        if inferred != port_start:
            raise SystemExit(
                f"inconsistent port layout discovered under {nodes_dir}; "
                f"node {index} implies port_start={inferred}, expected {port_start}"
            )

    ports = allocate_local_ports(max(index for index, _, _ in discovered) + 1, port_start)
    nodes: List[NodeRuntime] = []
    for index, node_dir, _ in discovered:
        username = f"validator-{index}"
        user_dir = workdir / "users" / username
        nodes.append(
            NodeRuntime(
                index=index,
                username=username,
                node_dir=node_dir,
                user_dir=user_dir,
                config_path=node_dir / "node.yaml",
                validator_identity_path=user_dir / "validator-identity.yaml",
                vfn_identity_path=user_dir / "validator-full-node-identity.yaml",
                ports=ports[index],
            )
        )
    return nodes


def load_nodes_from_state_or_workdir(workdir: Path) -> Tuple[Optional[dict], List[NodeRuntime]]:
    state = maybe_read_json(state_file(workdir))
    if state is not None:
        return state, restore_nodes_from_state(state)
    return None, discover_nodes_from_workdir(workdir)


def resolve_port_start(state: Optional[dict], nodes: Sequence[NodeRuntime]) -> int:
    if state is not None and "port_start" in state:
        return int(state["port_start"])
    if nodes:
        node = min(nodes, key=lambda item: item.index)
        return node.ports.validator_port - node.index * PORTS_PER_NODE
    return DEFAULT_PORT_START


def resolve_base_stake(workdir: Path, explicit: Optional[int]) -> int:
    if explicit is not None:
        return explicit

    workspace = workdir / "genesis-workspace"
    for owner_path in sorted(workspace.glob("validator-*/owner.yaml")):
        values = parse_simple_yaml_scalars(owner_path)
        if values.get("stake_amount"):
            return int(values["stake_amount"], 10)

    layout_path = workspace / "layout.yaml"
    if layout_path.exists():
        values = parse_simple_yaml_scalars(layout_path)
        if values.get("min_stake"):
            return int(values["min_stake"], 10)

    return DEFAULT_BASE_STAKE


def ensure_indexes_absent(workdir: Path, indexes: Sequence[int]) -> None:
    for index in indexes:
        username = f"validator-{index}"
        conflicts = [
            workdir / "users" / username,
            workdir / "nodes" / str(index),
            workdir / "genesis-workspace" / username,
        ]
        for path in conflicts:
            if path.exists():
                raise SystemExit(f"refusing to create validator-{index}; path already exists: {path}")


def node_state_entry(node: NodeRuntime, pid: int) -> Dict[str, object]:
    return {
        "index": node.index,
        "username": node.username,
        "node_dir": str(node.node_dir),
        "user_dir": str(node.user_dir),
        "config_path": str(node.config_path),
        "validator_identity_path": str(node.validator_identity_path),
        "vfn_identity_path": str(node.vfn_identity_path),
        "ports": ports_to_dict(node.ports),
        "pid": pid,
    }


def build_state_payload(
    *,
    repo_root: Path,
    workdir: Path,
    workspace: Path,
    aptos_node_bin: Path,
    framework_bundle: Path,
    started_at: str,
    port_start: int,
    nodes: Sequence[NodeRuntime],
    pid_by_index: Dict[int, int],
) -> Dict[str, object]:
    return {
        "repo_root": str(repo_root),
        "workdir": str(workdir),
        "workspace": str(workspace),
        "started_at": started_at,
        "aptos_node_bin": str(aptos_node_bin),
        "framework_bundle": str(framework_bundle),
        "port_start": port_start,
        "nodes": [
            node_state_entry(node, pid_by_index.get(node.index, 0))
            for node in sorted(nodes, key=lambda item: item.index)
        ],
    }


def start_command(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    workspace = workdir / "genesis-workspace"
    log_path = workdir / FORGE_LOG_NAME
    workdir.mkdir(parents=True, exist_ok=True)

    if maybe_read_json(state_file(workdir)):
        raise SystemExit(f"state file already exists: {state_file(workdir)}; stop first")

    cache_mode = args.cached_packages
    if cache_mode == "always" or (cache_mode == "auto" and detect_framework_code_changes(repo_root)):
        refresh_cached_packages(repo_root)
    elif cache_mode == "never":
        print("skipping cached package refresh (--cached-packages=never)")
    else:
        print("no framework code change detected; skipping cached package refresh")

    if workspace.exists():
        shutil.rmtree(workspace)
    for path in (workdir / "nodes", workdir / "users"):
        if path.exists():
            shutil.rmtree(path)
    workspace.mkdir(parents=True)

    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    aptos_node_bin = choose_aptos_node(repo_root, args.aptos_node_bin)
    framework_path = framework_bundle_path(repo_root, args.framework_bundle)

    layout_path = prepare_layout(args, workspace)
    setup_genesis_repository(aptos_cli, repo_root, workspace, layout_path)
    copy_framework_bundle(framework_path, workspace)

    ports = allocate_local_ports(args.nodes, args.port_start)
    nodes = build_nodes(workdir, args.nodes, ports)

    print("generating validator keys ...")
    generate_keys(aptos_cli, repo_root, nodes)

    print("writing validator configurations ...")
    write_validator_configurations(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        workspace=workspace,
        nodes=nodes,
        base_stake=args.base_stake,
        join_during_genesis=True,
    )

    print("generating genesis artifacts ...")
    generate_genesis(aptos_cli, repo_root, workspace)

    print("materializing local node configs ...")
    materialize_node_configs(workspace, nodes)

    print("starting aptos-node processes ...")
    pids = start_nodes(aptos_node_bin, nodes)

    try:
        wait_for_nodes_healthy(
            nodes,
            timeout_secs=args.startup_timeout_secs,
            poll_interval_secs=args.poll_interval_secs,
            pids=pids,
        )
    except BaseException:
        cleanup_node_processes(nodes=nodes, pids=pids)
        raise

    payload = build_state_payload(
        repo_root=repo_root,
        workdir=workdir,
        workspace=workspace,
        aptos_node_bin=aptos_node_bin,
        framework_bundle=framework_path,
        started_at=time.strftime("%Y-%m-%d %H:%M:%S %z"),
        port_start=args.port_start,
        nodes=nodes,
        pid_by_index={node.index: pid for node, pid in zip(nodes, pids)},
    )
    write_json(state_file(workdir), payload)
    write_text(log_path, "prod-like validator cluster started\n")

    print("cluster is healthy")
    for node in nodes:
        ok, detail = probe_node(node)
        status = "UP" if ok else "DOWN"
        print(
            f"node {node.index}: {status} rest={node.rest_url} "
            f"validator_port={node.ports.validator_port} detail={detail}"
        )
    print(f"state file: {state_file(workdir)}")
    print(f"workspace:  {workspace}")
    return 0


def add_validators_command(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    workspace = workdir / "genesis-workspace"

    if args.count <= 0:
        raise SystemExit("--count must be positive")

    required_paths = [
        workspace,
        workspace / "genesis.blob",
        workspace / "waypoint.txt",
        workspace / "layout.yaml",
    ]
    for path in required_paths:
        if not path.exists():
            raise SystemExit(f"cluster artifact missing: {path}")

    state, existing_nodes = load_nodes_from_state_or_workdir(workdir)
    if not existing_nodes:
        raise SystemExit(
            f"no existing validators found under {workdir}; start the base cluster first"
        )

    port_start = resolve_port_start(state, existing_nodes)
    next_index = max(node.index for node in existing_nodes) + 1
    new_indexes = list(range(next_index, next_index + args.count))
    ensure_indexes_absent(workdir, new_indexes)

    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    aptos_node_bin = choose_aptos_node(repo_root, args.aptos_node_bin)
    base_stake = resolve_base_stake(workdir, args.base_stake)
    new_nodes = build_nodes_for_indexes(workdir, new_indexes, port_start)

    print(f"generating validator keys for indexes: {', '.join(str(index) for index in new_indexes)}")
    generate_keys(aptos_cli, repo_root, new_nodes)

    print("writing post-genesis validator configurations ...")
    write_validator_configurations(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        workspace=workspace,
        nodes=new_nodes,
        base_stake=base_stake,
        join_during_genesis=False,
    )

    print("materializing local node configs ...")
    materialize_node_configs(workspace, new_nodes)

    print("starting aptos-node processes ...")
    pids = start_nodes(aptos_node_bin, new_nodes)

    try:
        wait_for_nodes_healthy(
            new_nodes,
            timeout_secs=args.startup_timeout_secs,
            poll_interval_secs=args.poll_interval_secs,
            pids=pids,
        )
    except BaseException:
        cleanup_node_processes(nodes=new_nodes, pids=pids)
        raise

    pid_by_index: Dict[int, int] = {}
    if state is not None:
        for item in state.get("nodes", []):
            pid_by_index[int(item["index"])] = int(item.get("pid", 0))
    else:
        for node in existing_nodes:
            pid = read_pid_file(node.pid_file)
            if pid is not None:
                pid_by_index[node.index] = pid
    for node, pid in zip(new_nodes, pids):
        pid_by_index[node.index] = pid

    framework_bundle = Path(
        (state or {}).get("framework_bundle", workspace / "framework.mrb")
    ).resolve()
    started_at = (state or {}).get("started_at", time.strftime("%Y-%m-%d %H:%M:%S %z"))
    all_nodes = sorted([*existing_nodes, *new_nodes], key=lambda node: node.index)
    write_json(
        state_file(workdir),
        build_state_payload(
            repo_root=repo_root,
            workdir=workdir,
            workspace=workspace,
            aptos_node_bin=aptos_node_bin,
            framework_bundle=framework_bundle,
            started_at=started_at,
            port_start=port_start,
            nodes=all_nodes,
            pid_by_index=pid_by_index,
        ),
    )

    print("new validators are healthy")
    for node in new_nodes:
        ok, detail = probe_node(node)
        status = "UP" if ok else "DOWN"
        print(
            f"node {node.index}: {status} rest={node.rest_url} "
            f"validator_port={node.ports.validator_port} detail={detail}"
        )
    print(
        "next step: "
        "python3 scripts/poc_validator_membership.py prepare-join "
        f"--validator-indexes {','.join(str(index) for index in new_indexes)} "
        "--initialize-validator --register-validator "
        f"--mint-topo {base_stake} --deposit-amount {base_stake}"
    )
    return 0


def status_command(args: argparse.Namespace) -> int:
    workdir = Path(args.workdir).resolve()
    state, nodes = load_nodes_from_state_or_workdir(workdir)
    if not nodes:
        raise SystemExit(f"no nodes found under {workdir}")
    print(f"workdir: {workdir}")
    print(f"workspace: {(state or {}).get('workspace', str(workdir / 'genesis-workspace'))}")
    pid_by_index: Dict[int, int] = {}
    if state is not None:
        for entry in state.get("nodes", []):
            pid_by_index[int(entry["index"])] = int(entry.get("pid", 0))
    else:
        for node in nodes:
            pid = read_pid_file(node.pid_file)
            if pid is not None:
                pid_by_index[node.index] = pid
    for node in nodes:
        pid = pid_by_index.get(node.index, 0)
        pid_status = "unknown" if pid <= 0 else ("alive" if is_pid_alive(pid) else "dead")
        ok, detail = probe_node(node)
        status = "UP" if ok else "DOWN"
        print(
            f"node {node.index}: pid={pid}({pid_status}) {status} "
            f"rest={node.rest_url} detail={detail}"
        )
    return 0


def stop_command(args: argparse.Namespace) -> int:
    workdir = Path(args.workdir).resolve()
    state = maybe_read_json(state_file(workdir))
    if state is not None:
        nodes = restore_nodes_from_state(state)
        cleanup_node_processes(nodes=nodes)
    else:
        killed = cleanup_node_processes(workdir=workdir)
        if killed == 0:
            raise SystemExit(f"state file does not exist: {state_file(workdir)}")
    state_file(workdir).unlink(missing_ok=True)
    print("cluster stopped")
    return 0


def add_common_path_args(parser: argparse.ArgumentParser, repo_root: Path) -> None:
    parser.add_argument(
        "--repo-root",
        default=str(repo_root),
        help="repo root; defaults to the parent of this script",
    )
    parser.add_argument(
        "--workdir",
        default=str(default_workdir(repo_root)),
        help=f"cluster workspace root; default: {default_workdir(repo_root)}",
    )


def build_parser() -> argparse.ArgumentParser:
    repo_root = repo_root_from_script()
    parser = argparse.ArgumentParser(
        description="Create and scale a local validator cluster using a production-like genesis ceremony."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    start_parser = subparsers.add_parser("start", help="build genesis artifacts and start nodes")
    add_common_path_args(start_parser, repo_root)
    start_parser.add_argument("--nodes", type=int, default=DEFAULT_NODE_COUNT)
    start_parser.add_argument("--aptos-cli", help="path to aptos CLI binary")
    start_parser.add_argument("--aptos-node-bin", help="path to aptos-node binary")
    start_parser.add_argument("--framework-bundle", help="path to framework.mrb / head.mrb")
    start_parser.add_argument(
        "--cached-packages",
        choices=("auto", "always", "never"),
        default="auto",
        help="refresh cached framework packages before generating genesis",
    )
    start_parser.add_argument("--base-stake", type=int, default=DEFAULT_BASE_STAKE)
    start_parser.add_argument("--chain-id", type=int, default=DEFAULT_CHAIN_ID)
    start_parser.add_argument(
        "--port-start",
        type=int,
        default=DEFAULT_PORT_START,
        help=f"base port used for node allocation; default: {DEFAULT_PORT_START}",
    )
    start_parser.add_argument(
        "--allow-new-validators",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="whether post-genesis validator join/leave is allowed; default: enabled",
    )
    start_parser.add_argument(
        "--root-key",
        default="D04470F43AB6AEAA4EB616B72128881EEF77346F2075FFE68E14BA7DEBD8095E",
        help="hex root key for layout.yaml",
    )
    start_parser.add_argument("--epoch-duration-secs", type=int, default=7200)
    start_parser.add_argument("--min-stake", type=int, default=100000000000000)
    start_parser.add_argument("--min-voting-threshold", type=int, default=100000000000000)
    start_parser.add_argument("--max-stake", type=int, default=100000000000000000)
    start_parser.add_argument("--recurring-lockup-duration-secs", type=int, default=86400)
    start_parser.add_argument("--required-proposer-stake", type=int, default=1000000)
    start_parser.add_argument("--rewards-apy-percentage", type=int, default=10)
    start_parser.add_argument("--voting-duration-secs", type=int, default=43200)
    start_parser.add_argument("--voting-power-increase-limit", type=int, default=20)
    start_parser.add_argument("--startup-timeout-secs", type=int, default=DEFAULT_STARTUP_TIMEOUT_SECS)
    start_parser.add_argument("--poll-interval-secs", type=float, default=DEFAULT_POLL_INTERVAL_SECS)
    start_parser.set_defaults(func=start_command)

    add_parser = subparsers.add_parser(
        "add-validators",
        help="generate and start additional post-genesis validator nodes",
    )
    add_common_path_args(add_parser, repo_root)
    add_parser.add_argument("--count", type=int, default=1, help="number of new validators to append")
    add_parser.add_argument("--aptos-cli", help="path to aptos CLI binary")
    add_parser.add_argument("--aptos-node-bin", help="path to aptos-node binary")
    add_parser.add_argument(
        "--base-stake",
        type=int,
        help="stake amount recorded for new validators; defaults to existing owner stake or layout.min_stake",
    )
    add_parser.add_argument("--startup-timeout-secs", type=int, default=DEFAULT_STARTUP_TIMEOUT_SECS)
    add_parser.add_argument("--poll-interval-secs", type=float, default=DEFAULT_POLL_INTERVAL_SECS)
    add_parser.set_defaults(func=add_validators_command)

    status_parser = subparsers.add_parser("status", help="show node status")
    add_common_path_args(status_parser, repo_root)
    status_parser.set_defaults(func=status_command)

    stop_parser = subparsers.add_parser("stop", help="stop all node processes")
    add_common_path_args(stop_parser, repo_root)
    stop_parser.set_defaults(func=stop_command)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "nodes", DEFAULT_NODE_COUNT) <= 0:
        raise SystemExit("--nodes must be positive")
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        eprint("interrupted")
        raise SystemExit(130)
