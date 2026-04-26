#!/usr/bin/env python3
"""
Operate validator power and validator-set membership for the local POC cluster.

This script is designed to work with the local cluster created by
`scripts/poc_prod_like_validator_cluster.py`, while still allowing explicit
REST/key/address overrides when needed.

Supported operations:
- stage a validator owner's POC power via `@core_resources`
- shorten the power period and force epoch ends in local testnet
- deposit and self-delegate into `staking_registry`
- initialize validator metadata from generated genesis operator config
- join / leave the validator set

Important constraints:
- Power update test-only entry functions must be submitted by `@core_resources`
  (default sender address `0xa550c18`).
- The local cluster must allow post-genesis validator-set changes. The updated
  `poc_prod_like_validator_cluster.py` now enables this by default.
- Joining a validator still requires the normal on-chain preconditions:
  initialized validator config, self delegation, positive self power, and total
  power above `minimum_stake`.
"""

import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence


DEFAULT_WORKDIR_NAME = "poc-validator-cluster"
STATE_FILE_NAME = ".prod_like_validator_cluster_state.json"
DEFAULT_CORE_RESOURCES_ADDRESS = "0xa550c18"
DEFAULT_FRAMEWORK_ADDRESS = "0x1"
DEFAULT_GAS_UNIT_PRICE = 100
DEFAULT_MAX_GAS = 20_000_000
DEFAULT_FORCE_EPOCH_SLEEP_SECS = 1.0
DEFAULT_COMMISSION_BPS = 0


@dataclass(frozen=True)
class NodeRecord:
    index: int
    username: str
    node_dir: Path
    user_dir: Path
    rest_url: str


@dataclass(frozen=True)
class ValidatorIdentity:
    owner_address: str
    operator_address: str
    owner_private_key: str
    rest_url: str
    user_dir: Path
    owner_config_file: Optional[Path]
    operator_config_file: Optional[Path]
    suggested_power: Optional[int]


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[2]


def default_workdir(repo_root: Path) -> Path:
    return Path(__file__).resolve().parent.parent / DEFAULT_WORKDIR_NAME


def state_file(workdir: Path) -> Path:
    return workdir / STATE_FILE_NAME


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise SystemExit(f"missing file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid json in {path}: {exc}") from exc


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError as exc:
        raise SystemExit(f"missing file: {path}") from exc


def normalize_hex(value: str) -> str:
    text = value.strip().strip('"').strip("'")
    if text.startswith("0x") or text.startswith("0X"):
        return "0x" + text[2:].lower()
    return "0x" + text.lower()


def parse_simple_yaml_scalars(path: Path) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for raw_line in read_text(path).splitlines():
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


def parse_owner_config(path: Path) -> Dict[str, str]:
    values = parse_simple_yaml_scalars(path)
    required = [
        "owner_account_address",
        "operator_account_address",
    ]
    missing = [key for key in required if key not in values]
    if missing:
        raise SystemExit(f"{path} missing required keys: {', '.join(missing)}")
    return values


def parse_private_identity(path: Path) -> Dict[str, str]:
    values = parse_simple_yaml_scalars(path)
    required = [
        "account_address",
        "account_private_key",
    ]
    missing = [key for key in required if key not in values]
    if missing:
        raise SystemExit(f"{path} missing required keys: {', '.join(missing)}")
    return values


def parse_public_identity(path: Path) -> Dict[str, str]:
    values = parse_simple_yaml_scalars(path)
    required = ["account_address"]
    missing = [key for key in required if key not in values]
    if missing:
        raise SystemExit(f"{path} missing required keys: {', '.join(missing)}")
    return values


def first_existing_path(candidates: Sequence[Path]) -> Optional[Path]:
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return None


def parse_rest_url_from_node_yaml(path: Path) -> str:
    lines = read_text(path).splitlines()
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
            address = raw.strip().strip('"').strip("'")
            host, port = split_host_port(address)
            if host in {"0.0.0.0", "::", ""}:
                host = "127.0.0.1"
            return f"http://{host}:{port}/v1"
    raise SystemExit(f"could not find api.address in {path}")


def split_host_port(text: str) -> tuple[str, int]:
    value = text.strip()
    if value.startswith("["):
        host, _, port = value[1:].partition("]:")
        return host, int(port)
    host, _, port = value.rpartition(":")
    if not host or not port:
        raise SystemExit(f"invalid host:port: {text}")
    return host, int(port)


def run_command(
    cmd: Sequence[str],
    *,
    cwd: Path,
    env: Optional[Dict[str, str]] = None,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(cmd),
        cwd=cwd,
        env=env,
        text=True,
        capture_output=capture_output,
        check=True,
    )


def format_command_for_log(cmd: Sequence[str], redactions: Sequence[str]) -> str:
    tokens: List[str] = []
    for token in cmd:
        rendered = token
        for secret in redactions:
            if secret:
                rendered = rendered.replace(secret, "***REDACTED***")
        tokens.append(shlex.quote(rendered))
    return " ".join(tokens)


def run_logged(
    cmd: Sequence[str],
    *,
    cwd: Path,
    redactions: Optional[Sequence[str]] = None,
) -> None:
    hidden = list(redactions or [])
    print(format_command_for_log(cmd, hidden))
    run_command(cmd, cwd=cwd)


def choose_aptos_cli(repo_root: Path, requested: Optional[str]) -> List[str]:
    if requested:
        candidate = Path(requested)
        if candidate.exists():
            return [str(candidate.resolve())]
        return [requested]

    for candidate in (
        repo_root / "target" / "release" / "aptos",
        repo_root / "target" / "debug" / "aptos",
    ):
        if candidate.exists():
            return [str(candidate)]

    return ["cargo", "run", "-p", "aptos", "--"]


def load_cluster_layout(workdir: Path) -> Dict[str, str]:
    layout_path = workdir / "genesis-workspace" / "layout.yaml"
    if not layout_path.exists():
        return {}
    return parse_simple_yaml_scalars(layout_path)


def load_cluster_nodes(workdir: Path) -> List[NodeRecord]:
    nodes: List[NodeRecord] = []
    state_path = state_file(workdir)
    if state_path.exists():
        state = load_json(state_path)
        for item in state.get("nodes", []):
            node_dir = Path(item["node_dir"])
            node_yaml = node_dir / "node.yaml"
            rest_url = parse_rest_url_from_node_yaml(node_yaml)
            nodes.append(
                NodeRecord(
                    index=int(item["index"]),
                    username=str(item["username"]),
                    node_dir=node_dir,
                    user_dir=Path(item["user_dir"]),
                    rest_url=rest_url,
                )
            )
        if nodes:
            return sorted(nodes, key=lambda node: node.index)

    nodes_dir = workdir / "nodes"
    users_dir = workdir / "users"
    if nodes_dir.exists():
        for node_dir in sorted(nodes_dir.iterdir(), key=lambda path: int(path.name) if path.name.isdigit() else path.name):
            if not node_dir.is_dir() or not node_dir.name.isdigit():
                continue
            index = int(node_dir.name)
            username = f"validator-{index}"
            node_yaml = node_dir / "node.yaml"
            if not node_yaml.exists():
                continue
            nodes.append(
                NodeRecord(
                    index=index,
                    username=username,
                    node_dir=node_dir,
                    user_dir=users_dir / username,
                    rest_url=parse_rest_url_from_node_yaml(node_yaml),
                )
            )
    if not nodes:
        raise SystemExit(
            f"no nodes found in {state_path}; expected either a state file or discovered nodes under {nodes_dir}"
        )
    return sorted(nodes, key=lambda node: node.index)


def discover_validator_identity(
    *,
    workdir: Path,
    validator_index: int,
    rest_url_override: Optional[str],
) -> ValidatorIdentity:
    nodes = load_cluster_nodes(workdir)
    try:
        node = next(item for item in nodes if item.index == validator_index)
    except StopIteration as exc:
        raise SystemExit(f"validator index {validator_index} not found in {state_file(workdir)}") from exc

    workspace_validator_dir = workdir / "genesis-workspace" / node.username
    owner_config_file = first_existing_path(
        [
            workspace_validator_dir / "owner.yaml",
            node.user_dir / "owner.yaml",
        ]
    )
    operator_config_file = first_existing_path(
        [
            workspace_validator_dir / "operator.yaml",
            node.user_dir / "operator.yaml",
        ]
    )
    owner_config = parse_owner_config(owner_config_file) if owner_config_file else {}
    private_identity = parse_private_identity(node.user_dir / "private-keys.yaml")
    public_identity = parse_public_identity(node.user_dir / "public-keys.yaml")

    owner_address = normalize_hex(
        owner_config.get("owner_account_address")
        or private_identity.get("account_address")
        or public_identity.get("account_address", "")
    )
    operator_address = normalize_hex(
        owner_config.get("operator_account_address")
        or owner_config.get("owner_account_address")
        or public_identity.get("account_address", "")
    )

    suggested_power: Optional[int] = None
    if owner_config.get("stake_amount"):
        suggested_power = int(owner_config["stake_amount"], 10)
    else:
        layout = load_cluster_layout(workdir)
        if layout.get("min_stake"):
            suggested_power = int(layout["min_stake"], 10)

    return ValidatorIdentity(
        owner_address=owner_address,
        operator_address=operator_address,
        owner_private_key=normalize_hex(private_identity["account_private_key"]),
        rest_url=rest_url_override or node.rest_url,
        user_dir=node.user_dir,
        owner_config_file=owner_config_file,
        operator_config_file=operator_config_file,
        suggested_power=suggested_power,
    )


def discover_validator_identity_by_address(
    *,
    workdir: Path,
    validator_address: str,
    rest_url_override: Optional[str],
) -> Optional[ValidatorIdentity]:
    wanted = normalize_hex(validator_address)
    for node in load_cluster_nodes(workdir):
        identity = discover_validator_identity(
            workdir=workdir,
            validator_index=node.index,
            rest_url_override=rest_url_override,
        )
        if identity.owner_address == wanted:
            return identity
    return None


def make_txn_options(
    *,
    private_key: str,
    rest_url: str,
    sender_account: Optional[str],
    max_gas: int,
    gas_unit_price: int,
) -> List[str]:
    cmd = [
        "--url",
        rest_url,
        "--private-key",
        private_key,
        "--assume-yes",
        "--max-gas",
        str(max_gas),
        "--gas-unit-price",
        str(gas_unit_price),
    ]
    if sender_account:
        cmd.extend(["--sender-account", sender_account])
    return cmd


def aptos_move_run(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    function_id: str,
    private_key: str,
    rest_url: str,
    args: Sequence[str],
    sender_account: Optional[str] = None,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> None:
    cmd = (
        list(aptos_cli)
        + [
            "move",
            "run",
            "--function-id",
            function_id,
        ]
        + make_txn_options(
            private_key=private_key,
            rest_url=rest_url,
            sender_account=sender_account,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )
    )
    if args:
        cmd.append("--args")
        cmd.extend(args)
    run_logged(cmd, cwd=repo_root, redactions=[private_key])


def aptos_node_initialize_validator(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    private_key: str,
    rest_url: str,
    operator_config_file: Path,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    cmd = (
        list(aptos_cli)
        + [
            "node",
            "initialize-validator",
            "--operator-config-file",
            str(operator_config_file),
        ]
        + make_txn_options(
            private_key=private_key,
            rest_url=rest_url,
            sender_account=None,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )
    )
    run_logged(cmd, cwd=repo_root, redactions=[private_key])


def aptos_node_join_validator_set(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    private_key: str,
    rest_url: str,
    pool_address: str,
    sender_account: Optional[str],
    max_gas: int,
    gas_unit_price: int,
) -> None:
    cmd = (
        list(aptos_cli)
        + [
            "node",
            "join-validator-set",
            "--pool-address",
            pool_address,
        ]
        + make_txn_options(
            private_key=private_key,
            rest_url=rest_url,
            sender_account=sender_account,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )
    )
    run_logged(cmd, cwd=repo_root, redactions=[private_key])


def aptos_node_leave_validator_set(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    private_key: str,
    rest_url: str,
    pool_address: str,
    sender_account: Optional[str],
    max_gas: int,
    gas_unit_price: int,
) -> None:
    cmd = (
        list(aptos_cli)
        + [
            "node",
            "leave-validator-set",
            "--pool-address",
            pool_address,
        ]
        + make_txn_options(
            private_key=private_key,
            rest_url=rest_url,
            sender_account=sender_account,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )
    )
    run_logged(cmd, cwd=repo_root, redactions=[private_key])


def stage_power(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    core_private_key: str,
    validator_address: str,
    power: int,
    sender_account: str,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::topo_governance::stage_power_update_test_only",
        private_key=core_private_key,
        rest_url=rest_url,
        sender_account=sender_account,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[
            f"address:{validator_address}",
            f"u64:{power}",
        ],
    )


def set_power_period(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    core_private_key: str,
    power_period_in_epochs: int,
    sender_account: str,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::topo_governance::set_power_period_in_epochs_test_only",
        private_key=core_private_key,
        rest_url=rest_url,
        sender_account=sender_account,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[f"u64:{power_period_in_epochs}"],
    )


def force_end_epoch(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    core_private_key: str,
    sender_account: str,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::topo_governance::force_end_epoch_test_only",
        private_key=core_private_key,
        rest_url=rest_url,
        sender_account=sender_account,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[],
    )


def mint_topo(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    core_private_key: str,
    recipient: str,
    amount: int,
    sender_account: str,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::topo_coin::mint",
        private_key=core_private_key,
        rest_url=rest_url,
        sender_account=sender_account,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[
            f"address:{recipient}",
            f"u64:{amount}",
        ],
    )


def ensure_account_exists(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    private_key: str,
    address: str,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::topo_account::create_account",
        private_key=private_key,
        rest_url=rest_url,
        sender_account=None,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[f"address:{address}"],
    )


def register_validator(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    private_key: str,
    commission_bps: int,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::staking_registry::register_validator",
        private_key=private_key,
        rest_url=rest_url,
        sender_account=None,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[f"u64:{commission_bps}"],
    )


def registry_deposit(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    private_key: str,
    amount: int,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::staking_registry::deposit",
        private_key=private_key,
        rest_url=rest_url,
        sender_account=None,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[f"u64:{amount}"],
    )


def registry_delegate(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    private_key: str,
    validator_address: str,
    max_gas: int,
    gas_unit_price: int,
) -> None:
    aptos_move_run(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::staking_registry::delegate",
        private_key=private_key,
        rest_url=rest_url,
        sender_account=None,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
        args=[f"address:{validator_address}"],
    )


def read_move_view(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    function_id: str,
    args: Sequence[str],
) -> str:
    cmd = list(aptos_cli) + ["move", "view", "--function-id", function_id, "--url", rest_url]
    if args:
        cmd.append("--args")
        cmd.extend(args)
    result = run_command(cmd, cwd=repo_root, capture_output=True)
    return result.stdout.strip()


def parse_view_scalar(output: str) -> str:
    output = output.strip()
    if not output:
        raise SystemExit("empty response from move view")

    try:
        parsed = json.loads(output)
    except json.JSONDecodeError:
        pass
    else:
        if isinstance(parsed, list) and len(parsed) == 1:
            value = parsed[0]
            if isinstance(value, (str, int, float, bool)):
                return str(value)
        if isinstance(parsed, (str, int, float, bool)):
            return str(parsed)

    match = re.search(r'"?result"?\s*:\s*\[\s*"?(.*?)"?\s*\]', output)
    if match:
        return match.group(1)
    return output


def view_u64(
    *,
    aptos_cli: Sequence[str],
    repo_root: Path,
    rest_url: str,
    function_id: str,
    args: Sequence[str],
) -> int:
    raw = read_move_view(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=rest_url,
        function_id=function_id,
        args=args,
    )
    value = parse_view_scalar(raw)
    return int(value, 10)


def resolve_validator_identity(
    args: argparse.Namespace,
    *,
    workdir: Path,
) -> ValidatorIdentity:
    if args.validator_index is not None:
        return discover_validator_identity(
            workdir=workdir,
            validator_index=args.validator_index,
            rest_url_override=args.rest_url,
        )

    discovered: Optional[ValidatorIdentity] = None
    if args.validator_address:
        try:
            discovered = discover_validator_identity_by_address(
                workdir=workdir,
                validator_address=args.validator_address,
                rest_url_override=args.rest_url,
            )
        except SystemExit:
            discovered = None

    if not args.validator_address:
        raise SystemExit(
            "provide either --validator-index or --validator-address "
            "(plus overrides only when auto-discovery is not possible)"
        )

    rest_url = args.rest_url
    if not rest_url:
        try:
            cluster_nodes = load_cluster_nodes(workdir)
        except SystemExit:
            cluster_nodes = []
        if cluster_nodes:
            rest_url = cluster_nodes[0].rest_url

    validator_private_key = args.validator_private_key
    if not validator_private_key and discovered:
        validator_private_key = discovered.owner_private_key

    if not validator_private_key or not rest_url:
        raise SystemExit(
            "provide either --validator-index or enough explicit data to submit transactions: "
            "--validator-address --validator-private-key --rest-url"
        )

    validator_address = normalize_hex(args.validator_address)
    operator_address = normalize_hex(
        args.operator_address
        or (discovered.operator_address if discovered else validator_address)
    )
    operator_config_file = (
        Path(args.operator_config_file).resolve()
        if args.operator_config_file
        else (discovered.operator_config_file if discovered else None)
    )
    user_dir = Path(args.user_dir).resolve() if args.user_dir else (discovered.user_dir if discovered else Path(""))
    return ValidatorIdentity(
        owner_address=validator_address,
        operator_address=operator_address,
        owner_private_key=normalize_hex(validator_private_key),
        rest_url=rest_url,
        user_dir=user_dir,
        owner_config_file=discovered.owner_config_file if discovered else None,
        operator_config_file=operator_config_file,
        suggested_power=discovered.suggested_power if discovered else None,
    )


def parse_validator_indexes(raw: str) -> List[int]:
    indexes: List[int] = []
    for token in raw.split(","):
        value = token.strip()
        if not value:
            continue
        try:
            index = int(value, 10)
        except ValueError as exc:
            raise SystemExit(f"invalid validator index: {value}") from exc
        if index < 0:
            raise SystemExit(f"validator index must be non-negative: {index}")
        indexes.append(index)
    if not indexes:
        raise SystemExit("at least one validator index is required")
    return sorted(dict.fromkeys(indexes))


def resolve_validator_identities(
    args: argparse.Namespace,
    *,
    workdir: Path,
) -> List[ValidatorIdentity]:
    if args.validator_indexes:
        return [
            discover_validator_identity(
                workdir=workdir,
                validator_index=index,
                rest_url_override=args.rest_url,
            )
            for index in parse_validator_indexes(args.validator_indexes)
        ]
    return [resolve_validator_identity(args, workdir=workdir)]


def require_core_private_key(args: argparse.Namespace, *, workdir: Path) -> str:
    if args.core_private_key:
        return normalize_hex(args.core_private_key)

    layout = load_cluster_layout(workdir)
    root_key = layout.get("root_key")
    if root_key:
        return normalize_hex(root_key)

    raise SystemExit(
        "--core-private-key is required for power staging and epoch forcing; "
        "for prod_like cluster output it is auto-discovered from genesis-workspace/layout.yaml "
        "when available"
    )


def resolve_power_argument(args: argparse.Namespace, identity: ValidatorIdentity, *, workdir: Path) -> int:
    if args.power is not None:
        return args.power

    if identity.suggested_power is not None:
        return identity.suggested_power

    layout = load_cluster_layout(workdir)
    if layout.get("min_stake"):
        return int(layout["min_stake"], 10)

    raise SystemExit(
        "--power is required when it cannot be auto-derived from "
        "genesis-workspace/validator-*/owner.yaml or layout.yaml"
    )


def require_operator_config(identity: ValidatorIdentity) -> Path:
    operator_config_file = identity.operator_config_file
    if operator_config_file:
        return operator_config_file
    raise SystemExit(
        "operator config not found; use --validator-index from prod-like cluster output "
        "or provide --operator-config-file explicitly"
    )


def print_identity_summary(
    identity: ValidatorIdentity,
    *,
    power: Optional[int] = None,
    show_operator_config: bool = False,
    show_owner_config: bool = False,
) -> None:
    print(f"validator_address: {identity.owner_address}")
    print(f"operator_address:  {identity.operator_address}")
    print(f"rest_url:          {identity.rest_url}")
    if power is not None:
        print(f"power:             {power}")
    if show_owner_config and identity.owner_config_file:
        print(f"owner_config:      {identity.owner_config_file}")
    if show_operator_config and identity.operator_config_file:
        print(f"operator_config:   {identity.operator_config_file}")


def print_identity_batch_summary(
    identities: Sequence[ValidatorIdentity],
    *,
    power: Optional[int] = None,
    show_operator_config: bool = False,
    show_owner_config: bool = False,
) -> None:
    for index, identity in enumerate(identities, start=1):
        if len(identities) > 1:
            print(f"[validator {index}/{len(identities)}]")
        print_identity_summary(
            identity,
            power=power,
            show_operator_config=show_operator_config,
            show_owner_config=show_owner_config,
        )


def maybe_initialize_validator(
    *,
    args: argparse.Namespace,
    aptos_cli: Sequence[str],
    repo_root: Path,
    identity: ValidatorIdentity,
) -> None:
    if not args.initialize_validator:
        return
    operator_config_file = require_operator_config(identity)
    aptos_node_initialize_validator(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        private_key=identity.owner_private_key,
        rest_url=identity.rest_url,
        operator_config_file=operator_config_file,
        max_gas=args.max_gas,
        gas_unit_price=args.gas_unit_price,
    )


def command_stage_power(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    identity = resolve_validator_identity(args, workdir=workdir)
    core_private_key = require_core_private_key(args, workdir=workdir)
    power = resolve_power_argument(args, identity, workdir=workdir)
    print_identity_summary(identity, power=power)

    if args.set_power_period is not None:
        set_power_period(
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            rest_url=identity.rest_url,
            core_private_key=core_private_key,
            power_period_in_epochs=args.set_power_period,
            sender_account=normalize_hex(args.core_sender_account),
            max_gas=args.max_gas,
            gas_unit_price=args.gas_unit_price,
        )

    stage_power(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        core_private_key=core_private_key,
        validator_address=identity.owner_address,
        power=power,
        sender_account=normalize_hex(args.core_sender_account),
        max_gas=args.max_gas,
        gas_unit_price=args.gas_unit_price,
    )

    for _ in range(args.force_epochs):
        force_end_epoch(
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            rest_url=identity.rest_url,
            core_private_key=core_private_key,
            sender_account=normalize_hex(args.core_sender_account),
            max_gas=args.max_gas,
            gas_unit_price=args.gas_unit_price,
        )
        time.sleep(args.force_epoch_sleep_secs)
    return 0


def command_join(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    identities = resolve_validator_identities(args, workdir=workdir)
    for offset, identity in enumerate(identities, start=1):
        if len(identities) > 1:
            print(f"== join validator {offset}/{len(identities)} ==")
        print_identity_summary(identity, show_operator_config=args.initialize_validator)
        maybe_initialize_validator(
            args=args,
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            identity=identity,
        )
        aptos_node_join_validator_set(
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            private_key=identity.owner_private_key,
            rest_url=identity.rest_url,
            pool_address=identity.owner_address,
            sender_account=args.validator_sender_account,
            max_gas=args.max_gas,
            gas_unit_price=args.gas_unit_price,
        )
    return 0


def command_leave(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    identities = resolve_validator_identities(args, workdir=workdir)
    for offset, identity in enumerate(identities, start=1):
        if len(identities) > 1:
            print(f"== leave validator {offset}/{len(identities)} ==")
        print_identity_summary(identity)
        aptos_node_leave_validator_set(
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            private_key=identity.owner_private_key,
            rest_url=identity.rest_url,
            pool_address=identity.owner_address,
            sender_account=args.validator_sender_account,
            max_gas=args.max_gas,
            gas_unit_price=args.gas_unit_price,
        )
    return 0


def command_prepare_join(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    core_private_key = require_core_private_key(args, workdir=workdir)
    identities = resolve_validator_identities(args, workdir=workdir)
    core_sender_account = normalize_hex(args.core_sender_account)

    for offset, identity in enumerate(identities, start=1):
        power = resolve_power_argument(args, identity, workdir=workdir)
        if len(identities) > 1:
            print(f"== prepare validator {offset}/{len(identities)} ==")
        print_identity_summary(
            identity,
            power=power,
            show_operator_config=args.initialize_validator,
            show_owner_config=True,
        )

        maybe_initialize_validator(
            args=args,
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            identity=identity,
        )

        if args.ensure_account:
            ensure_account_exists(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                private_key=identity.owner_private_key,
                address=identity.owner_address,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )

        if args.set_power_period is not None:
            set_power_period(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                core_private_key=core_private_key,
                power_period_in_epochs=args.set_power_period,
                sender_account=core_sender_account,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )

        stage_power(
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            rest_url=identity.rest_url,
            core_private_key=core_private_key,
            validator_address=identity.owner_address,
            power=power,
            sender_account=core_sender_account,
            max_gas=args.max_gas,
            gas_unit_price=args.gas_unit_price,
        )

        for _ in range(args.force_epochs_before_delegate):
            force_end_epoch(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                core_private_key=core_private_key,
                sender_account=core_sender_account,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )
            time.sleep(args.force_epoch_sleep_secs)

        if args.mint_topo > 0:
            mint_topo(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                core_private_key=core_private_key,
                recipient=identity.owner_address,
                amount=args.mint_topo,
                sender_account=core_sender_account,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )

        if args.register_validator:
            register_validator(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                private_key=identity.owner_private_key,
                commission_bps=args.commission_bps,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )

        if args.deposit_amount > 0:
            registry_deposit(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                private_key=identity.owner_private_key,
                amount=args.deposit_amount,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )

        if args.delegate_self:
            registry_delegate(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                private_key=identity.owner_private_key,
                validator_address=identity.owner_address,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )

        aptos_node_join_validator_set(
            aptos_cli=aptos_cli,
            repo_root=repo_root,
            private_key=identity.owner_private_key,
            rest_url=identity.rest_url,
            pool_address=identity.owner_address,
            sender_account=args.validator_sender_account,
            max_gas=args.max_gas,
            gas_unit_price=args.gas_unit_price,
        )

        for _ in range(args.force_epochs_after_join):
            force_end_epoch(
                aptos_cli=aptos_cli,
                repo_root=repo_root,
                rest_url=identity.rest_url,
                core_private_key=core_private_key,
                sender_account=core_sender_account,
                max_gas=args.max_gas,
                gas_unit_price=args.gas_unit_price,
            )
            time.sleep(args.force_epoch_sleep_secs)
    return 0


def command_status(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    workdir = Path(args.workdir).resolve()
    aptos_cli = choose_aptos_cli(repo_root, args.aptos_cli)
    identity = resolve_validator_identity(args, workdir=workdir)

    current_period = view_u64(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::poc_power_store::get_current_period",
        args=[],
    )
    committed_power = view_u64(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::poc_power_store::get_user_committed_power",
        args=[f"address:{identity.owner_address}"],
    )
    next_power = view_u64(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::poc_power_store::get_user_power_for_period",
        args=[
            f"address:{identity.owner_address}",
            f"u64:{current_period + 1}",
        ],
    )
    power_period = view_u64(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::poc_power_store::get_power_period_in_epochs",
        args=[],
    )
    validator_total_power = view_u64(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::stake::get_current_epoch_voting_power",
        args=[f"address:{identity.owner_address}"],
    )
    stake_info_raw = read_move_view(
        aptos_cli=aptos_cli,
        repo_root=repo_root,
        rest_url=identity.rest_url,
        function_id=f"{DEFAULT_FRAMEWORK_ADDRESS}::staking_registry::get_user_stake_info",
        args=[f"address:{identity.owner_address}"],
    )

    print(f"validator_address: {identity.owner_address}")
    print(f"operator_address:  {identity.operator_address}")
    print(f"rest_url:          {identity.rest_url}")
    print(f"current_period:    {current_period}")
    print(f"power_period:      {power_period}")
    print(f"committed_power:   {committed_power}")
    print(f"next_period_power: {next_power}")
    print(f"epoch_voting_power:{validator_total_power}")
    print(f"user_stake_info:   {stake_info_raw}")
    return 0


def add_shared_paths(parser: argparse.ArgumentParser, repo_root: Path) -> None:
    parser.add_argument(
        "--repo-root",
        default=str(repo_root),
        help="repo root; defaults to the parent of this script",
    )
    parser.add_argument(
        "--workdir",
        default=str(default_workdir(repo_root)),
        help=f"cluster workdir; default: {default_workdir(repo_root)}",
    )
    parser.add_argument("--aptos-cli", help="path to aptos CLI binary")


def add_validator_selector(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--validator-index",
        type=int,
        help="validator index from prod-like cluster output; auto-discovers key/rest/operator config",
    )
    parser.add_argument(
        "--validator-indexes",
        help="comma-separated validator indexes, e.g. 4,5,6; batch mode for join/leave/prepare-join",
    )
    parser.add_argument("--validator-address", help="validator owner / pool address")
    parser.add_argument("--validator-private-key", help="validator owner private key")
    parser.add_argument("--operator-address", help="explicit operator address override")
    parser.add_argument("--rest-url", help="REST endpoint, e.g. http://127.0.0.1:8080/v1")
    parser.add_argument(
        "--operator-config-file",
        help="path to operator.yaml; auto-discovered from genesis-workspace/validator-*/operator.yaml when available",
    )
    parser.add_argument("--user-dir", help="validator user directory")


def add_txn_tuning(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--max-gas", type=int, default=DEFAULT_MAX_GAS)
    parser.add_argument("--gas-unit-price", type=int, default=DEFAULT_GAS_UNIT_PRICE)


def add_core_resources_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--core-private-key",
        help="private key authorized for sender-account 0xa550c18 in this local testnet; defaults to genesis-workspace/layout.yaml root_key when available",
    )
    parser.add_argument(
        "--core-sender-account",
        default=DEFAULT_CORE_RESOURCES_ADDRESS,
        help=f"sender address for core_resources transactions; default: {DEFAULT_CORE_RESOURCES_ADDRESS}",
    )


def build_parser() -> argparse.ArgumentParser:
    repo_root = repo_root_from_script()
    parser = argparse.ArgumentParser(
        description="Operate POC validator power/join/leave against a local Aptos validator cluster."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    stage_parser = subparsers.add_parser("stage-power", help="stage committed power for a validator")
    add_shared_paths(stage_parser, repo_root)
    add_validator_selector(stage_parser)
    add_core_resources_args(stage_parser)
    add_txn_tuning(stage_parser)
    stage_parser.add_argument(
        "--power",
        type=int,
        help="target committed power; defaults to owner stake_amount or layout.min_stake when auto-discovery is available",
    )
    stage_parser.add_argument(
        "--set-power-period",
        type=int,
        help="optionally set power_period_in_epochs before staging",
    )
    stage_parser.add_argument(
        "--force-epochs",
        type=int,
        default=0,
        help="force this many epoch transitions after staging",
    )
    stage_parser.add_argument(
        "--force-epoch-sleep-secs",
        type=float,
        default=DEFAULT_FORCE_EPOCH_SLEEP_SECS,
    )
    stage_parser.set_defaults(func=command_stage_power)

    join_parser = subparsers.add_parser("join", help="join validator set for a prepared validator")
    add_shared_paths(join_parser, repo_root)
    add_validator_selector(join_parser)
    add_txn_tuning(join_parser)
    join_parser.add_argument(
        "--initialize-validator",
        action="store_true",
        help="initialize validator metadata from discovered operator.yaml before join",
    )
    join_parser.add_argument(
        "--validator-sender-account",
        help="override sender account for the validator transaction if auth key was rotated",
    )
    join_parser.set_defaults(func=command_join)

    leave_parser = subparsers.add_parser("leave", help="leave validator set")
    add_shared_paths(leave_parser, repo_root)
    add_validator_selector(leave_parser)
    add_txn_tuning(leave_parser)
    leave_parser.add_argument(
        "--validator-sender-account",
        help="override sender account for the validator transaction if auth key was rotated",
    )
    leave_parser.set_defaults(func=command_leave)

    prepare_parser = subparsers.add_parser(
        "prepare-join",
        help="stage power, optionally mint/deposit/delegate, then join validator set",
    )
    add_shared_paths(prepare_parser, repo_root)
    add_validator_selector(prepare_parser)
    add_core_resources_args(prepare_parser)
    add_txn_tuning(prepare_parser)
    prepare_parser.add_argument(
        "--power",
        type=int,
        help="target committed power; defaults to owner stake_amount or layout.min_stake when auto-discovery is available",
    )
    prepare_parser.add_argument(
        "--set-power-period",
        type=int,
        default=1,
        help="set power_period_in_epochs before staging; default: 1",
    )
    prepare_parser.add_argument(
        "--force-epochs-before-delegate",
        type=int,
        default=2,
        help="epoch transitions after staging so the new power becomes active; default: 2",
    )
    prepare_parser.add_argument(
        "--force-epochs-after-join",
        type=int,
        default=1,
        help="epoch transitions after join to activate pending_active; default: 1",
    )
    prepare_parser.add_argument(
        "--force-epoch-sleep-secs",
        type=float,
        default=DEFAULT_FORCE_EPOCH_SLEEP_SECS,
    )
    prepare_parser.add_argument(
        "--initialize-validator",
        action="store_true",
        help="initialize validator metadata from discovered operator.yaml before join",
    )
    prepare_parser.add_argument(
        "--ensure-account",
        action="store_true",
        help="call topo_account::create_account for the validator address before other steps",
    )
    prepare_parser.add_argument(
        "--register-validator",
        action="store_true",
        help="call staking_registry::register_validator before deposit/delegate",
    )
    prepare_parser.add_argument(
        "--commission-bps",
        type=int,
        default=DEFAULT_COMMISSION_BPS,
        help="commission_bps when --register-validator is used; default: 0",
    )
    prepare_parser.add_argument(
        "--mint-topo",
        type=int,
        default=0,
        help="mint TOPO to the validator owner from core_resources before deposit",
    )
    prepare_parser.add_argument(
        "--deposit-amount",
        type=int,
        default=0,
        help="deposit this amount into staking_registry before delegate",
    )
    prepare_parser.add_argument(
        "--delegate-self",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="delegate validator owner to itself before join; default: enabled",
    )
    prepare_parser.add_argument(
        "--validator-sender-account",
        help="override sender account for the validator transaction if auth key was rotated",
    )
    prepare_parser.set_defaults(func=command_prepare_join)

    status_parser = subparsers.add_parser("status", help="show power and stake status for a validator")
    add_shared_paths(status_parser, repo_root)
    add_validator_selector(status_parser)
    status_parser.set_defaults(func=command_status)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "validator_index", None) is not None and getattr(args, "validator_indexes", None):
        raise SystemExit("use either --validator-index or --validator-indexes, not both")
    return args.func(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        eprint("interrupted")
        raise SystemExit(130)
