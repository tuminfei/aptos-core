import asyncio
import contextlib
import random
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from app.api.ws import broadcast
from app.chain import view
from app.chain.client import ChainClient, get_chain_client
from app.chain.keys import Ed25519Key, get_key_manager
from app.chain.transaction import submit_entry_function
from app.models import contribution_event, dapp_demo, dapp_trade_task, operation_log, watchlist
from app.services.cache_svc import invalidate_many


DEFAULT_MAX_GAS = 400_000
DEFAULT_GAS_UNIT_PRICE = 100
DEFAULT_DEMO_MODULE = "poc_demo"
DEFAULT_BUYER_MINT_OCTAS = 100_000_000
DEFAULT_AUTO_TRADE_CUSTODY_TOP_UP_TICKS = 10
POC_FRAMEWORK_ADDRESS = "0x1"


async def get_dapp_list(client: ChainClient) -> list[dict]:
    addresses = await watchlist.get_addresses("dapp")
    if not addresses:
        return []

    admins = [a["address"] for a in addresses]
    try:
        infos = await view.get_app_infos_by_admins(client, admins)
    except Exception:
        infos = []

    return infos


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def _aptos_cli(repo_root: Path) -> list[str]:
    for candidate in (
        repo_root / "target" / "release" / "aptos",
        repo_root / "target" / "debug" / "aptos",
    ):
        if candidate.exists():
            return [str(candidate)]
    return ["cargo", "run", "-p", "aptos", "--"]


def _extract_tx_hash(output: str) -> str:
    for token in output.replace('"', " ").replace("'", " ").split():
        if token.startswith("0x") and len(token) == 66:
            return token
    return ""


def _extract_object_address(output: str) -> str:
    match = re.search(r"object address (0x[0-9a-fA-F]+)", output)
    if match:
        return match.group(1)
    raise RuntimeError(f"无法解析 demo dapp object address: {output[-600:]}")


def _normalize_address(addr: str) -> str:
    value = (addr or "").strip()
    if not value:
        return value
    return value if value.startswith("0x") else f"0x{value}"


def _event_address(value) -> str:
    if isinstance(value, str):
        return _normalize_address(value)
    if isinstance(value, dict):
        for key in ("inner", "address", "object", "object_address"):
            if key in value:
                return _event_address(value[key])
    return str(value or "")


def _extract_contribution_events(txn: dict, *, app_admin: str = "") -> list[dict]:
    tx_hash = txn.get("hash", "")
    try:
        version = int(txn.get("version", 0) or 0)
    except Exception:
        version = 0

    rows: list[dict] = []
    for index, event in enumerate(txn.get("events") or []):
        event_type = str(event.get("type") or "")
        if not event_type.endswith("::poc_contribution::ContributionEvent"):
            continue
        data = event.get("data") or {}
        rows.append({
            "tx_hash": tx_hash,
            "event_index": index,
            "version": version,
            "app_admin": _normalize_address(app_admin),
            "app_address": _event_address(data.get("app_address")),
            "contributor": _event_address(data.get("contributor")),
            "equity_token": _event_address(data.get("equity_token")),
            "equity_amount": int(data.get("equity_amount") or 0),
            "period": int(data.get("period") or 0),
            "event_type": event_type,
            "raw_event": event,
        })
    return rows


async def persist_contribution_events_from_tx(
    client: ChainClient,
    tx_hash: str,
    *,
    app_admin: str = "",
) -> list[dict]:
    txn = await client.get_transaction_by_hash(tx_hash)
    if not txn or txn.get("type") == "pending_transaction":
        return []
    events = _extract_contribution_events(txn, app_admin=app_admin)
    if not events:
        return []
    await contribution_event.insert_events(events)
    for event in events:
        await broadcast("contribution_event", event)
    return events


def _ensure_demo_package(repo_root: Path) -> Path:
    source_dir = repo_root / "aptos-move" / "move-examples" / "poc_demo"
    source_file = source_dir / "sources" / "poc_demo.move"
    framework_dir = repo_root / "aptos-move" / "framework" / "aptos-framework"
    if not source_file.exists():
        raise RuntimeError(f"找不到 demo dapp 源码: {source_file}")
    if not framework_dir.exists():
        raise RuntimeError(f"找不到正式 AptosFramework: {framework_dir}")

    target_dir = repo_root / "poc-dashboard" / ".generated" / "poc_demo_formal"
    sources_dir = target_dir / "sources"
    sources_dir.mkdir(parents=True, exist_ok=True)

    source = source_file.read_text()
    source = source.replace("use poc_framework::poc_contribution;", "use aptos_framework::poc_contribution;")
    source = source.replace("use poc_framework::poc_registry;", "use aptos_framework::poc_registry;")
    (sources_dir / "poc_demo.move").write_text(source)
    test_file = sources_dir / "poc_demo_test.move"
    if test_file.exists():
        test_file.unlink()

    move_toml = f"""[package]
name = "PocDemoFormal"
version = "0.0.0"

[addresses]
poc_demo = "_"

[dependencies]
AptosFramework = {{ local = "{framework_dir}" }}
"""
    (target_dir / "Move.toml").write_text(move_toml)
    return target_dir


async def deploy_demo_package(
    *,
    admin_key: Ed25519Key,
    rest_url: str,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> tuple[str, str]:
    repo_root = _repo_root()
    package_dir = _ensure_demo_package(repo_root)
    aptos_cli = _aptos_cli(repo_root)
    cmd = [
        *aptos_cli,
        "move",
        "create-object-and-publish-package",
        "--address-name",
        DEFAULT_DEMO_MODULE,
        "--package-dir",
        str(package_dir),
        "--url",
        rest_url,
        "--private-key",
        admin_key.private_key_hex,
        "--assume-yes",
        "--max-gas",
        str(max_gas),
        "--gas-unit-price",
        str(gas_unit_price),
    ]

    proc = await asyncio.to_thread(
        subprocess.run,
        cmd,
        cwd=repo_root,
        text=True,
        capture_output=True,
        timeout=300,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0 and '"success": true' not in output and '"Result": "Success"' not in output:
        raise RuntimeError(output[-1200:] or "部署 demo dapp 失败")
    return _extract_object_address(output), _extract_tx_hash(output) or "cli:deploy-poc-demo"


async def run_poc_framework_script(
    script_name: str,
    *,
    core_key: Ed25519Key,
    core_address: str,
    rest_url: str,
    args: list[str] | None = None,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
    timeout_secs: int = 300,
) -> str:
    repo_root = _repo_root()
    script_path = repo_root / "poc-dashboard" / "scripts" / script_name
    framework_dir = repo_root / "aptos-move" / "framework" / "aptos-framework"
    if not script_path.exists():
        raise RuntimeError(f"找不到 POC 管理脚本: {script_path}")
    if not framework_dir.exists():
        raise RuntimeError(f"找不到正式 AptosFramework: {framework_dir}")

    cmd = [
        *_aptos_cli(repo_root),
        "move",
        "run-script",
        "--script-path",
        str(script_path),
        "--sender-account",
        core_address,
        "--framework-local-dir",
        str(framework_dir),
        "--skip-fetch-latest-git-deps",
        "--url",
        rest_url,
        "--private-key",
        core_key.private_key_hex,
        "--assume-yes",
        "--max-gas",
        str(max_gas),
        "--gas-unit-price",
        str(gas_unit_price),
    ]
    for arg in args or []:
        cmd.extend(["--args", arg])

    proc = await asyncio.to_thread(
        subprocess.run,
        cmd,
        cwd=repo_root,
        text=True,
        capture_output=True,
        timeout=timeout_secs,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0 and '"success": true' not in output and '"Result": "Success"' not in output:
        raise RuntimeError(output[-1200:] or f"执行 POC 管理脚本失败: {script_name}")
    return _extract_tx_hash(output) or f"cli:{script_path.stem}"


async def initialize_poc_registry_with_core_resources(
    *,
    core_key: Ed25519Key,
    core_address: str,
    rest_url: str,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> str:
    return await run_poc_framework_script(
        "initialize_poc_registry.move",
        core_key=core_key,
        core_address=core_address,
        rest_url=rest_url,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
    )


async def set_poc_listing_status_with_core_resources(
    *,
    core_key: Ed25519Key,
    core_address: str,
    rest_url: str,
    app_admin: str,
    status: int,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> str:
    return await run_poc_framework_script(
        "set_dapp_poc_status.move",
        core_key=core_key,
        core_address=core_address,
        rest_url=rest_url,
        args=[f"address:{_normalize_address(app_admin)}", f"u8:{status}"],
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
    )


async def set_effective_weight_with_core_resources(
    *,
    core_key: Ed25519Key,
    core_address: str,
    rest_url: str,
    app_admin: str,
    weight_pbs: int,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> str:
    return await run_poc_framework_script(
        "set_dapp_weight.move",
        core_key=core_key,
        core_address=core_address,
        rest_url=rest_url,
        args=[f"address:{_normalize_address(app_admin)}", f"u64:{weight_pbs}"],
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
    )


async def create_demo_dapp(
    *,
    label: str,
    metadata_uri: str,
    initial_supply: int,
    price_per_equity: int,
    auto_whitelist: bool,
    gas_mint_octas: int = 0,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> dict:
    if initial_supply <= 0:
        raise ValueError("initial_supply 必须大于 0")
    if price_per_equity <= 0:
        raise ValueError("price_per_equity 必须大于 0")

    client = get_chain_client()
    km = get_key_manager()
    admin_key, admin_address = km.generate_account(label or "demo-dapp")
    await km.persist_key(admin_key, admin_address, label or "")
    await watchlist.add_address("dapp", admin_address, label or "")

    steps: list[dict] = []

    async def run_step(name: str, target: str, params: dict | None, fn):
        try:
            value = await fn()
            tx_hash = value[1] if isinstance(value, tuple) else value
            steps.append({"step": name, "status": "success", "tx_hash": tx_hash})
            await operation_log.create_log(name, target, params, tx_hash, "success")
            await broadcast("dapp_operation", {"action": name, "target": target, "status": "success", "tx_hash": tx_hash})
            return value
        except Exception as e:
            steps.append({"step": name, "status": "failed", "error": str(e)})
            await operation_log.create_log(name, target, params, None, "failed", str(e))
            await broadcast("dapp_operation", {"action": name, "target": target, "status": "failed", "error": str(e)})
            raise

    if not await client.account_exists(admin_address):
        await run_step(
            "create_account",
            admin_address,
            None,
            lambda: submit_entry_function(
                client,
                km.core_resources_key,
                km.core_resources_address,
                "0x1::topo_account::create_account",
                args=[admin_address],
            ),
        )
    else:
        steps.append({"step": "create_account", "status": "skipped", "reason": "account_exists"})

    if gas_mint_octas > 0:
        await run_step(
            "mint_topo",
            admin_address,
            {"amount": gas_mint_octas},
            lambda: submit_entry_function(
                client,
                km.core_resources_key,
                km.core_resources_address,
                "0x1::topo_coin::mint",
                args=[admin_address, str(gas_mint_octas)],
            ),
        )

    module_address, deploy_tx = await run_step(
        "deploy_demo_dapp",
        admin_address,
        {"poc_framework": POC_FRAMEWORK_ADDRESS},
        lambda: deploy_demo_package(
            admin_key=admin_key,
            rest_url=client.base_url,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        ),
    )

    await run_step(
        "initialize_poc_registry",
        POC_FRAMEWORK_ADDRESS,
        None,
        lambda: initialize_poc_registry_with_core_resources(
            core_key=km.core_resources_key,
            core_address=km.core_resources_address,
            rest_url=client.base_url,
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        ),
    )

    register_tx = await run_step(
        "register_demo_dapp",
        admin_address,
        {
            "module_address": module_address,
            "metadata_uri": metadata_uri,
            "initial_supply": initial_supply,
            "price_per_equity": price_per_equity,
        },
        lambda: submit_entry_function(
            client,
            admin_key,
            admin_address,
            f"{module_address}::{DEFAULT_DEMO_MODULE}::register_demo_app",
            args=[metadata_uri, str(initial_supply), str(price_per_equity)],
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        ),
    )

    whitelist_tx = None
    if auto_whitelist:
        whitelist_tx = await run_step(
            "whitelist_app",
            admin_address,
            None,
            lambda: set_poc_listing_status_with_core_resources(
                core_key=km.core_resources_key,
                core_address=km.core_resources_address,
                rest_url=client.base_url,
                app_admin=admin_address,
                status=2,
                max_gas=max_gas,
                gas_unit_price=gas_unit_price,
            ),
        )

    await dapp_demo.upsert_config(
        app_admin=admin_address,
        module_address=module_address,
        label=label,
        metadata_uri=metadata_uri,
        initial_supply=initial_supply,
        price_per_equity=price_per_equity,
        auto_whitelist=auto_whitelist,
        deploy_tx_hash=deploy_tx,
        register_tx_hash=register_tx,
        whitelist_tx_hash=whitelist_tx,
    )
    await invalidate_many("dapps:", f"dapp:detail:{admin_address.lower()}")
    await broadcast("dapp_changed", {"app_admin": admin_address, "module_address": module_address})
    return {
        "success": True,
        "app_admin": admin_address,
        "module_address": module_address,
        "steps": steps,
    }


async def get_demo_runtime(app_admin: str, module_address: str | None = None) -> dict:
    client = get_chain_client()
    config = await dapp_demo.get_config(app_admin)
    module = module_address or (config or {}).get("module_address", "")
    runtime = {"configured": bool(config), "module_address": module}
    if not module:
        return runtime

    async def read(name: str, fn, default):
        try:
            runtime[name] = await fn()
        except Exception:
            runtime[name] = default

    await read("exists", lambda: view.demo_exists_app(client, module, app_admin), False)
    await read("price_per_equity", lambda: view.demo_price_per_equity(client, module, app_admin), 0)
    await read("trade_count", lambda: view.demo_trade_count(client, module, app_admin), 0)
    await read("total_equity_sold", lambda: view.demo_total_equity_sold(client, module, app_admin), 0)
    await read("custody_inventory", lambda: view.demo_custody_inventory(client, module, app_admin), 0)
    if config:
        runtime.update(config)
    await _apply_contribution_stats(runtime, app_admin)
    return runtime


async def apply_contribution_stats_to_demo_configs(configs: dict[str, dict]) -> dict[str, dict]:
    for app_admin, runtime in configs.items():
        await _apply_contribution_stats(runtime, app_admin)
    return configs


async def _apply_contribution_stats(runtime: dict, app_admin: str) -> None:
    local_trade_count = await contribution_event.count_events(app_admin=app_admin)
    local_equity_sold = await contribution_event.sum_equity_amount(app_admin=app_admin)
    runtime["local_trade_count"] = local_trade_count
    runtime["local_total_equity_sold"] = local_equity_sold
    runtime["trade_count"] = max(int(runtime.get("trade_count") or 0), local_trade_count)
    runtime["total_equity_sold"] = max(int(runtime.get("total_equity_sold") or 0), local_equity_sold)


async def mint_equity_to_custody(
    *,
    app_admin: str,
    amount: int,
    module_address: str = "",
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> str:
    if amount <= 0:
        raise ValueError("amount 必须大于 0")
    client = get_chain_client()
    km = get_key_manager()
    admin_key = km.get_operator_key_by_address(app_admin)
    if not admin_key:
        raise ValueError(f"找不到 DApp 管理员托管私钥: {app_admin}")
    module = module_address or (await dapp_demo.get_config(app_admin) or {}).get("module_address", "")
    if not module:
        raise ValueError("缺少 demo module address")

    return await submit_entry_function(
        client,
        admin_key,
        app_admin,
        f"{module}::{DEFAULT_DEMO_MODULE}::mint_equity_to_custody",
        args=[str(amount)],
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
    )


async def ensure_buyer_account(
    buyer_address: str = "",
    *,
    label: str = "",
    mint_octas: int = 0,
) -> tuple[Ed25519Key, str, list[dict]]:
    client = get_chain_client()
    km = get_key_manager()
    steps: list[dict] = []

    if buyer_address:
        buyer_address = _normalize_address(buyer_address)
        key = km.get_operator_key_by_address(buyer_address)
        if not key:
            raise ValueError(f"找不到买家托管私钥: {buyer_address}")
    else:
        key, buyer_address = km.generate_account(label or "demo-buyer")
        await km.persist_key(key, buyer_address, label or "")
        await watchlist.add_address("user", buyer_address, label or "")

    if not await client.account_exists(buyer_address):
        tx = await submit_entry_function(
            client,
            km.core_resources_key,
            km.core_resources_address,
            "0x1::topo_account::create_account",
            args=[buyer_address],
        )
        steps.append({"step": "create_account", "status": "success", "tx_hash": tx})
        await operation_log.create_log("create_account", buyer_address, None, tx, "success")

    if mint_octas > 0:
        tx = await submit_entry_function(
            client,
            km.core_resources_key,
            km.core_resources_address,
            "0x1::topo_coin::mint",
            args=[buyer_address, str(mint_octas)],
        )
        steps.append({"step": "mint_topo", "status": "success", "tx_hash": tx})
        await operation_log.create_log("mint_topo", buyer_address, {"amount": mint_octas}, tx, "success")

    return key, buyer_address, steps


async def buy_equity(
    *,
    app_admin: str,
    equity_amount: int,
    buyer_address: str = "",
    buyer_label: str = "",
    module_address: str = "",
    auto_create_buyer: bool = True,
    mint_octas: int = 0,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> dict:
    if equity_amount <= 0:
        raise ValueError("equity_amount 必须大于 0")

    module = module_address or (await dapp_demo.get_config(app_admin) or {}).get("module_address", "")
    if not module:
        raise ValueError("缺少 demo module address")
    if not buyer_address and not auto_create_buyer:
        raise ValueError("必须指定 buyer_address 或允许自动生成买家")

    try:
        buyer_key, buyer, prep_steps = await ensure_buyer_account(
            buyer_address,
            label=buyer_label,
            mint_octas=mint_octas,
        )
        client = get_chain_client()
        tx = await submit_entry_function(
            client,
            buyer_key,
            buyer,
            f"{module}::{DEFAULT_DEMO_MODULE}::buy_equity",
            args=[app_admin, str(equity_amount)],
            max_gas=max_gas,
            gas_unit_price=gas_unit_price,
        )
        params = {
            "app_admin": app_admin,
            "module_address": module,
            "buyer": buyer,
            "equity_amount": equity_amount,
            "mint_octas": mint_octas,
        }
        contribution_events = await persist_contribution_events_from_tx(client, tx, app_admin=app_admin)
        await invalidate_many(
            "dapps:",
            f"dapp:detail:{app_admin.lower()}",
            f"user:detail:{buyer.lower()}",
            f"contribution:app:{app_admin.lower()}",
            f"contribution:user:{buyer.lower()}",
            "contribution:all:",
        )
        await operation_log.create_log("demo_dapp_buy_equity", app_admin, params, tx, "success")
        await broadcast(
            "dapp_trade",
            {
                "app_admin": app_admin,
                "buyer": buyer,
                "equity_amount": equity_amount,
                "tx_hash": tx,
                "contribution_events": len(contribution_events),
            },
        )
        return {
            "success": True,
            "tx_hash": tx,
            "buyer": buyer,
            "steps": prep_steps,
            "contribution_events": contribution_events,
        }
    except Exception as e:
        await operation_log.create_log(
            "demo_dapp_buy_equity",
            app_admin,
            {"module_address": module, "buyer": buyer_address, "equity_amount": equity_amount},
            None,
            "failed",
            str(e),
        )
        await broadcast("dapp_trade", {"app_admin": app_admin, "status": "failed", "error": str(e)})
        raise


@dataclass
class DemoTradeTask:
    task_id: str
    app_admin: str
    module_address: str
    interval_secs: float
    tx_per_tick: int
    amount_min: int
    amount_max: int
    max_runs: int
    buyer_addresses: list[str]
    buyer_selection_mode: str
    auto_create_buyers: int
    mint_octas: int
    max_gas: int
    gas_unit_price: int
    created_at: float = field(default_factory=time.time)
    status: str = "running"
    run_count: int = 0
    success_count: int = 0
    failure_count: int = 0
    last_tx_hash: str = ""
    last_error: str = ""
    _task: asyncio.Task | None = None
    _buyer_index: int = 0
    _prepared_buyers: set[str] = field(default_factory=set)

    def public_status(self) -> dict:
        return {
            "task_id": self.task_id,
            "app_admin": self.app_admin,
            "module_address": self.module_address,
            "interval_secs": self.interval_secs,
            "tx_per_tick": self.tx_per_tick,
            "amount_min": self.amount_min,
            "amount_max": self.amount_max,
            "max_runs": self.max_runs,
            "buyer_addresses": self.buyer_addresses,
            "buyer_selection_mode": self.buyer_selection_mode,
            "buyer_count": len(self.buyer_addresses),
            "auto_create_buyers": self.auto_create_buyers,
            "mint_octas": self.mint_octas,
            "prepared_buyer_count": len(self._prepared_buyers),
            "max_gas": self.max_gas,
            "gas_unit_price": self.gas_unit_price,
            "created_at": self.created_at,
            "status": self.status,
            "run_count": self.run_count,
            "success_count": self.success_count,
            "failure_count": self.failure_count,
            "last_tx_hash": self.last_tx_hash,
            "last_error": self.last_error,
        }


_trade_tasks: dict[str, DemoTradeTask] = {}


def _task_from_status(status: dict) -> DemoTradeTask:
    return DemoTradeTask(
        task_id=status.get("task_id", ""),
        app_admin=status.get("app_admin", ""),
        module_address=status.get("module_address", ""),
        interval_secs=float(status.get("interval_secs", 0) or 0),
        tx_per_tick=int(status.get("tx_per_tick", 0) or 0),
        amount_min=int(status.get("amount_min", 0) or 0),
        amount_max=int(status.get("amount_max", 0) or 0),
        max_runs=int(status.get("max_runs", 0) or 0),
        buyer_addresses=list(status.get("buyer_addresses") or []),
        buyer_selection_mode=status.get("buyer_selection_mode", "fixed"),
        auto_create_buyers=int(status.get("auto_create_buyers", 0) or 0),
        mint_octas=int(status.get("mint_octas", 0) or 0),
        max_gas=int(status.get("max_gas", DEFAULT_MAX_GAS) or DEFAULT_MAX_GAS),
        gas_unit_price=int(status.get("gas_unit_price", DEFAULT_GAS_UNIT_PRICE) or DEFAULT_GAS_UNIT_PRICE),
        created_at=float(status.get("created_at", 0) or time.time()),
        status=status.get("status", "running"),
        run_count=int(status.get("run_count", 0) or 0),
        success_count=int(status.get("success_count", 0) or 0),
        failure_count=int(status.get("failure_count", 0) or 0),
        last_tx_hash=status.get("last_tx_hash", "") or "",
        last_error=status.get("last_error", "") or "",
    )


async def start_trade_task(
    *,
    app_admin: str,
    module_address: str = "",
    interval_secs: float,
    tx_per_tick: int,
    amount_min: int,
    amount_max: int,
    max_runs: int,
    buyer_addresses: list[str],
    auto_create_buyers: int,
    mint_octas: int,
    max_gas: int = DEFAULT_MAX_GAS,
    gas_unit_price: int = DEFAULT_GAS_UNIT_PRICE,
) -> dict:
    if interval_secs < 1:
        raise ValueError("interval_secs 必须至少为 1")
    if tx_per_tick < 1:
        raise ValueError("tx_per_tick 必须至少为 1")
    if amount_min <= 0 or amount_max <= 0 or amount_min > amount_max:
        raise ValueError("交易金额区间不合法")
    if max_runs < 0:
        raise ValueError("max_runs 不能为负数")

    await stop_trade_task(app_admin, missing_ok=True)
    module = module_address or (await dapp_demo.get_config(app_admin) or {}).get("module_address", "")
    if not module:
        raise ValueError("缺少 demo module address")

    normalized_buyers = [_normalize_address(b) for b in buyer_addresses if b.strip()]
    buyer_selection_mode = "fixed"
    if not normalized_buyers:
        normalized_buyers = await _get_effective_user_buyers()
        buyer_selection_mode = "watchlist_random"
    if not normalized_buyers:
        raise ValueError("没有固定买家地址，也没有可用的有效用户。请先新增普通用户，或在固定买家地址中填写托管用户地址。")
    auto_create_buyers = 0

    task_id = f"{app_admin}:{int(time.time())}"
    task = DemoTradeTask(
        task_id=task_id,
        app_admin=app_admin,
        module_address=module,
        interval_secs=interval_secs,
        tx_per_tick=tx_per_tick,
        amount_min=amount_min,
        amount_max=amount_max,
        max_runs=max_runs,
        buyer_addresses=normalized_buyers,
        buyer_selection_mode=buyer_selection_mode,
        auto_create_buyers=auto_create_buyers,
        mint_octas=mint_octas,
        max_gas=max_gas,
        gas_unit_price=gas_unit_price,
    )
    _trade_tasks[app_admin] = task
    await dapp_trade_task.upsert_task(task.public_status())
    task._task = asyncio.create_task(_trade_loop(task))
    await operation_log.create_log("demo_dapp_auto_trade_start", app_admin, task.public_status(), None, "success")
    await broadcast("dapp_trade_task", task.public_status())
    return task.public_status()


async def _get_effective_user_buyers() -> list[str]:
    km = get_key_manager()
    buyers: list[str] = []
    seen: set[str] = set()
    for item in await watchlist.get_addresses("user"):
        address = _normalize_address(item.get("address", ""))
        if not address:
            continue
        lowered = address.lower()
        if lowered in seen:
            continue
        if not km.get_operator_key_by_address(address):
            continue
        seen.add(lowered)
        buyers.append(address)
    return buyers


async def _prepare_task_buyer(task: DemoTradeTask, buyer: str) -> None:
    key = buyer.lower()
    if key in task._prepared_buyers:
        return
    _, _, steps = await ensure_buyer_account(buyer, mint_octas=task.mint_octas)
    task._prepared_buyers.add(key)
    for step in steps:
        await broadcast("dapp_trade_task", {"task_id": task.task_id, "buyer": buyer, "prep_step": step})


async def _ensure_demo_custody_inventory(task: DemoTradeTask, required_amount: int) -> None:
    if required_amount <= 0:
        return

    client = get_chain_client()
    inventory = await view.demo_custody_inventory(client, task.module_address, task.app_admin)
    if inventory >= required_amount:
        return

    top_up_amount = max(
        required_amount - inventory,
        task.amount_max * max(task.tx_per_tick, DEFAULT_AUTO_TRADE_CUSTODY_TOP_UP_TICKS),
    )
    params = {
        "inventory": inventory,
        "required_amount": required_amount,
        "amount": top_up_amount,
        "module_address": task.module_address,
    }
    try:
        tx = await mint_equity_to_custody(
            app_admin=task.app_admin,
            amount=top_up_amount,
            module_address=task.module_address,
            max_gas=task.max_gas,
            gas_unit_price=task.gas_unit_price,
        )
        await operation_log.create_log("demo_dapp_auto_trade_mint_equity", task.app_admin, params, tx, "success")
        await invalidate_many("dapps:", f"dapp:detail:{task.app_admin.lower()}")
        await broadcast(
            "dapp_operation",
            {
                "action": "demo_dapp_auto_trade_mint_equity",
                "target": task.app_admin,
                "status": "success",
                "tx_hash": tx,
            },
        )
        await broadcast(
            "dapp_trade_task",
            {
                "task_id": task.task_id,
                "prep_step": {"step": "mint_equity_to_custody", "status": "success", "tx_hash": tx},
            },
        )
    except Exception as e:
        await operation_log.create_log(
            "demo_dapp_auto_trade_mint_equity",
            task.app_admin,
            params,
            None,
            "failed",
            str(e),
        )
        raise


async def stop_trade_task(app_admin: str, missing_ok: bool = False, persist: bool = True) -> dict:
    task = _trade_tasks.get(app_admin)
    if not task:
        if missing_ok:
            if persist:
                await dapp_trade_task.update_task_state(app_admin, status="stopped")
            return {"running": False}
        raise ValueError("没有运行中的定时交易任务")
    task.status = "stopping" if persist else "shutdown"
    if task._task:
        task._task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task._task
    task.status = "stopped" if persist else "running"
    _trade_tasks.pop(app_admin, None)
    if persist:
        await dapp_trade_task.update_task_state(app_admin, status="stopped")
        await operation_log.create_log("demo_dapp_auto_trade_stop", app_admin, task.public_status(), None, "success")
        await broadcast("dapp_trade_task", task.public_status())
    return task.public_status()


async def get_trade_task_status(app_admin: str | None = None) -> dict:
    if app_admin:
        task = _trade_tasks.get(app_admin)
        if task:
            return task.public_status()
        persisted = await dapp_trade_task.get_task(app_admin)
        return persisted if persisted else {"running": False}
    return {"tasks": [task.public_status() for task in _trade_tasks.values()]}


async def stop_all_trade_tasks() -> None:
    for app_admin in list(_trade_tasks.keys()):
        with contextlib.suppress(Exception):
            await stop_trade_task(app_admin, missing_ok=True, persist=False)


async def restore_trade_tasks() -> list[dict]:
    restored: list[dict] = []
    for row in await dapp_trade_task.get_running_tasks():
        app_admin = row.get("app_admin", "")
        if not app_admin or app_admin in _trade_tasks:
            continue
        task = _task_from_status(row)
        if not task.module_address:
            await dapp_trade_task.update_task_state(app_admin, status="stopped", last_error="restore failed: missing module_address")
            continue
        task.status = "running"
        _trade_tasks[app_admin] = task
        task._task = asyncio.create_task(_trade_loop(task))
        restored.append(task.public_status())
        await broadcast("dapp_trade_task", task.public_status())
    return restored


async def _trade_loop(task: DemoTradeTask) -> None:
    task.status = "running"
    await dapp_trade_task.update_task_state(task.app_admin, status=task.status)
    try:
        while task.status == "running":
            for _ in range(task.tx_per_tick):
                if task.max_runs and task.run_count >= task.max_runs:
                    task.status = "completed"
                    await dapp_trade_task.update_task_state(
                        task.app_admin,
                        status=task.status,
                        run_count=task.run_count,
                        success_count=task.success_count,
                        failure_count=task.failure_count,
                        last_tx_hash=task.last_tx_hash,
                        last_error=task.last_error,
                    )
                    await broadcast("dapp_trade_task", task.public_status())
                    return
                buyer = _next_buyer(task)
                amount = random.randint(task.amount_min, task.amount_max)
                task.run_count += 1
                try:
                    await _prepare_task_buyer(task, buyer)
                    await _ensure_demo_custody_inventory(task, amount)
                    result = await buy_equity(
                        app_admin=task.app_admin,
                        module_address=task.module_address,
                        buyer_address=buyer,
                        equity_amount=amount,
                        auto_create_buyer=False,
                        mint_octas=0,
                        max_gas=task.max_gas,
                        gas_unit_price=task.gas_unit_price,
                    )
                    task.success_count += 1
                    task.last_tx_hash = result.get("tx_hash", "")
                    task.last_error = ""
                except Exception as e:
                    task.failure_count += 1
                    task.last_error = str(e)
                await dapp_trade_task.update_task_state(
                    task.app_admin,
                    status=task.status,
                    run_count=task.run_count,
                    success_count=task.success_count,
                    failure_count=task.failure_count,
                    last_tx_hash=task.last_tx_hash,
                    last_error=task.last_error,
                )
                await broadcast("dapp_trade_task", task.public_status())
            await asyncio.sleep(task.interval_secs)
    except asyncio.CancelledError:
        raise
    finally:
        if task.status == "running":
            task.status = "stopped"
            await dapp_trade_task.update_task_state(task.app_admin, status=task.status)


def _next_buyer(task: DemoTradeTask) -> str:
    if not task.buyer_addresses:
        raise RuntimeError("没有可用买家地址")
    if task.buyer_selection_mode == "watchlist_random":
        return random.choice(task.buyer_addresses)
    buyer = task.buyer_addresses[task._buyer_index % len(task.buyer_addresses)]
    task._buyer_index += 1
    return buyer
