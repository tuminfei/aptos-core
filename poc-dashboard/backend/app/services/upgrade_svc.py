import asyncio
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from app.api.ws import broadcast
from app.chain.client import get_chain_client
from app.chain.keys import get_key_manager
from app.services.dapp_svc import (
    FRAMEWORK_MODULE_ADDRESS,
    FRAMEWORK_PACKAGE_NAME,
    _aptos_cli,
    _extract_tx_hash,
    _repo_root,
    framework_dir as _framework_dir,
)

META_CHUNK_SIZE = 60000
MODULE_CHUNK_SIZE = 55000

_upgrading = False


def is_upgrading() -> bool:
    return _upgrading


async def _broadcast_progress(step: str, status: str, **kwargs):
    await broadcast("framework_upgrade_progress", {"step": step, "status": status, **kwargs})


async def get_framework_status() -> dict:
    client = get_chain_client()
    repo_root = _repo_root()
    framework_dir = _framework_dir(repo_root)

    has_staging = False
    resource = await client.get_account_resource("0x1", "0x7::large_packages::StagingArea")
    if resource is not None:
        has_staging = True

    upgrade_number = await _get_upgrade_number(repo_root, client.base_url)

    return {
        "upgrade_number": upgrade_number,
        "has_staging_area": has_staging,
        "framework_source_exists": framework_dir.is_dir(),
    }


async def _get_upgrade_number(repo_root: Path, rest_url: str) -> int:
    cmd = [*_aptos_cli(repo_root), "move", "list", "--account", "0x1", "--url", rest_url]
    proc = await asyncio.to_thread(
        subprocess.run, cmd, capture_output=True, text=True, timeout=60
    )
    output = proc.stdout or ""
    in_framework_package = False
    for line in output.splitlines():
        if FRAMEWORK_PACKAGE_NAME in line and "package" in line:
            in_framework_package = True
        if in_framework_package and "upgrade_number" in line:
            parts = line.split(":")
            if len(parts) >= 2:
                return int(parts[-1].strip())
    return -1


async def _run_cli(cmd: list[str], repo_root: Path, timeout: int = 300) -> str:
    proc = await asyncio.to_thread(
        subprocess.run, cmd, cwd=repo_root, capture_output=True, text=True, timeout=timeout
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0 and '"success": true' not in output and '"Result": "Success"' not in output:
        raise RuntimeError(output[-2000:] or "CLI command failed")
    return output


async def upgrade_framework(*, max_gas: int = 2_000_000, gas_unit_price: int = 100):
    global _upgrading
    if _upgrading:
        raise RuntimeError("升级正在进行中")

    _upgrading = True
    try:
        await _do_upgrade(max_gas=max_gas, gas_unit_price=gas_unit_price)
    except Exception as e:
        await _broadcast_progress("error", "failed", error=str(e))
        raise
    finally:
        _upgrading = False


async def _do_upgrade(*, max_gas: int, gas_unit_price: int):
    repo_root = _repo_root()
    client = get_chain_client()
    km = get_key_manager()
    framework_dir = _framework_dir(repo_root)
    experimental_dir = repo_root / "aptos-move" / "framework" / "aptos-experimental"

    # Step 1: Pre-flight
    resource = await client.get_account_resource("0x1", "0x7::large_packages::StagingArea")
    if resource is not None:
        raise RuntimeError("链上存在残留 StagingArea，请先清理后重试")
    if not framework_dir.is_dir():
        raise RuntimeError(f"Framework 源码目录不存在: {framework_dir}")

    old_upgrade_number = await _get_upgrade_number(repo_root, client.base_url)
    await _broadcast_progress("preflight", "ok", upgrade_number=old_upgrade_number)

    # Step 2: Compile & build payload
    tmp_dir = tempfile.mkdtemp(prefix="fw_upgrade_")
    try:
        payload_path = os.path.join(tmp_dir, "payload.json")
        cmd = [
            *_aptos_cli(repo_root),
            "move", "build-publish-payload",
            "--package-dir", str(framework_dir),
            "--json-output-file", payload_path,
            "--override-size-check",
            "--skip-fetch-latest-git-deps",
        ]
        await _run_cli(cmd, repo_root, timeout=600)

        with open(payload_path) as f:
            payload = json.load(f)

        metadata_hex = payload["args"][0]["value"]
        modules_hex = payload["args"][1]["value"]
        if metadata_hex.startswith("0x"):
            metadata_hex = metadata_hex[2:]
        metadata_bytes = bytes.fromhex(metadata_hex)
        module_bytes_list = []
        for m in modules_hex:
            if m.startswith("0x"):
                m = m[2:]
            module_bytes_list.append(bytes.fromhex(m))

        total_bytes = len(metadata_bytes) + sum(len(m) for m in module_bytes_list)
        await _broadcast_progress("compile", "ok", total_bytes=total_bytes, modules=len(module_bytes_list))

        # Step 3: Chunk
        chunks = _build_chunks(metadata_bytes, module_bytes_list)
        await _broadcast_progress("chunk", "ok", total_chunks=len(chunks))

        # Step 4: Generate scripts, compile, submit
        pkg_dir = os.path.join(tmp_dir, "pkg")
        os.makedirs(os.path.join(pkg_dir, "sources"), exist_ok=True)

        move_toml = f"""[package]
name = "UpgradeScript"
version = "0.0.1"

[addresses]

[dependencies]
AptosExperimental = {{ local = "{experimental_dir}" }}
"""
        with open(os.path.join(pkg_dir, "Move.toml"), "w") as f:
            f.write(move_toml)

        for chunk_idx, (meta, indices, mods) in enumerate(chunks):
            is_last = chunk_idx == len(chunks) - 1
            script_source = _generate_chunk_script(meta, indices, mods, is_last)

            sources_dir = os.path.join(pkg_dir, "sources")
            for old_file in os.listdir(sources_dir):
                os.remove(os.path.join(sources_dir, old_file))
            with open(os.path.join(sources_dir, f"chunk_{chunk_idx}.move"), "w") as f:
                f.write(script_source)

            # Compile
            compile_cmd = [
                *_aptos_cli(repo_root),
                "move", "compile",
                "--package-dir", pkg_dir,
                "--skip-fetch-latest-git-deps",
            ]
            await _run_cli(compile_cmd, repo_root, timeout=120)

            # Submit
            bytecode_path = os.path.join(pkg_dir, "build", "UpgradeScript", "bytecode_scripts", "main.mv")
            submit_cmd = [
                *_aptos_cli(repo_root),
                "move", "run-script",
                "--compiled-script-path", bytecode_path,
                "--sender-account", km.core_resources_address,
                "--url", client.base_url,
                "--private-key", km.core_resources_key.private_key_hex,
                "--assume-yes",
                "--max-gas", str(max_gas),
                "--gas-unit-price", str(gas_unit_price),
            ]
            output = await _run_cli(submit_cmd, repo_root, timeout=120)
            tx_hash = _extract_tx_hash(output)
            await _broadcast_progress(
                "submit", "ok",
                current=chunk_idx + 1, total=len(chunks), tx_hash=tx_hash
            )

        # Step 5: Verify
        await asyncio.sleep(2)
        resource = await client.get_account_resource("0x1", "0x7::large_packages::StagingArea")
        staging_cleaned = resource is None
        new_upgrade_number = await _get_upgrade_number(repo_root, client.base_url)

        await _broadcast_progress(
            "verify", "ok",
            upgrade_number=new_upgrade_number,
            staging_cleaned=staging_cleaned,
            old_upgrade_number=old_upgrade_number,
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


async def cleanup_staging_area(*, max_gas: int = 200_000, gas_unit_price: int = 100) -> str:
    repo_root = _repo_root()
    client = get_chain_client()
    km = get_key_manager()

    script = f"""script {{
    use {FRAMEWORK_MODULE_ADDRESS}::topo_governance;
    use aptos_experimental::large_packages;

    fun main(core_resources: &signer) {{
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @{FRAMEWORK_MODULE_ADDRESS});
        large_packages::cleanup_staging_area(&framework_signer);
    }}
}}
"""
    tmp_dir = tempfile.mkdtemp(prefix="fw_cleanup_")
    try:
        experimental_dir = repo_root / "aptos-move" / "framework" / "aptos-experimental"
        pkg_dir = os.path.join(tmp_dir, "pkg")
        os.makedirs(os.path.join(pkg_dir, "sources"), exist_ok=True)

        move_toml = f"""[package]
name = "CleanupScript"
version = "0.0.1"

[addresses]

[dependencies]
AptosExperimental = {{ local = "{experimental_dir}" }}
"""
        with open(os.path.join(pkg_dir, "Move.toml"), "w") as f:
            f.write(move_toml)
        with open(os.path.join(pkg_dir, "sources", "cleanup.move"), "w") as f:
            f.write(script)

        compile_cmd = [
            *_aptos_cli(repo_root),
            "move", "compile",
            "--package-dir", pkg_dir,
            "--skip-fetch-latest-git-deps",
        ]
        await _run_cli(compile_cmd, repo_root, timeout=120)

        bytecode_path = os.path.join(pkg_dir, "build", "CleanupScript", "bytecode_scripts", "main.mv")
        submit_cmd = [
            *_aptos_cli(repo_root),
            "move", "run-script",
            "--compiled-script-path", bytecode_path,
            "--sender-account", km.core_resources_address,
            "--url", client.base_url,
            "--private-key", km.core_resources_key.private_key_hex,
            "--assume-yes",
            "--max-gas", str(max_gas),
            "--gas-unit-price", str(gas_unit_price),
        ]
        output = await _run_cli(submit_cmd, repo_root, timeout=120)
        return _extract_tx_hash(output) or "cleanup:done"
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _build_chunks(
    metadata_bytes: bytes, module_bytes_list: list[bytes]
) -> list[tuple[bytes, list[int], list[bytes]]]:
    chunks: list[tuple[bytes, list[int], list[bytes]]] = []

    # Metadata chunks (no modules)
    for i in range(0, len(metadata_bytes), META_CHUNK_SIZE):
        chunks.append((metadata_bytes[i:i + META_CHUNK_SIZE], [], []))

    # Module chunks
    current_modules: list[bytes] = []
    current_indices: list[int] = []
    current_size = 0

    for i, mod_bytes in enumerate(module_bytes_list):
        if current_size + len(mod_bytes) > MODULE_CHUNK_SIZE and current_modules:
            chunks.append((b"", current_indices[:], current_modules[:]))
            current_modules = []
            current_indices = []
            current_size = 0
        current_modules.append(mod_bytes)
        current_indices.append(i)
        current_size += len(mod_bytes)

    if current_modules:
        chunks.append((b"", current_indices[:], current_modules[:]))

    return chunks


def _generate_chunk_script(
    meta: bytes, indices: list[int], mods: list[bytes], is_last: bool
) -> str:
    lines = [
        "script {",
        "    use std::vector;",
        f"    use {FRAMEWORK_MODULE_ADDRESS}::topo_governance;",
        "    use aptos_experimental::large_packages;",
        "",
        "    fun main(core_resources: &signer) {",
        f"        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @{FRAMEWORK_MODULE_ADDRESS});",
        "",
    ]

    if meta:
        lines.append(f'        let metadata_chunk = x"{meta.hex()}";')
    else:
        lines.append("        let metadata_chunk = vector::empty<u8>();")
    lines.append("")

    lines.append("        let code_indices = vector::empty<u16>();")
    for idx in indices:
        lines.append(f"        vector::push_back(&mut code_indices, {idx}u16);")
    lines.append("")

    lines.append("        let code_chunks = vector::empty<vector<u8>>();")
    for mod_bytes in mods:
        lines.append(f'        vector::push_back(&mut code_chunks, x"{mod_bytes.hex()}");')
    lines.append("")

    if is_last:
        lines.append("        large_packages::stage_code_chunk_and_publish_to_account(")
    else:
        lines.append("        large_packages::stage_code_chunk(")
    lines.append("            &framework_signer,")
    lines.append("            metadata_chunk,")
    lines.append("            code_indices,")
    lines.append("            code_chunks,")
    lines.append("        );")
    lines.append("    }")
    lines.append("}")
    lines.append("")

    return "\n".join(lines)
