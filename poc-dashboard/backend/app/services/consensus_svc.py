import glob
import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Any

import httpx
import yaml

from app.api.ws import broadcast
from app.config import get_settings
from app.models import history


logger = logging.getLogger(__name__)

JSON_VALIDATOR_POWER_PREFIX = "aptos_all_validators_voting_power."
PROM_VALUE_RE = re.compile(
    r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s+([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)"
)
PROM_PEER_ID_RE = re.compile(r'peer_id="([^"]+)"')

_last_captured_epoch: int | None = None


async def sample_consensus_epoch_voting_power(force: bool = False, expected_epoch: int | None = None) -> dict[str, Any]:
    if not force and expected_epoch is not None and _last_captured_epoch == expected_epoch:
        return {
            "captured": False,
            "skipped": True,
            "reason": "当前 epoch 已采集",
            "epoch": expected_epoch,
        }

    candidates = _inspection_urls()
    if not candidates:
        return {"captured": False, "reason": "没有找到节点 inspection metrics 地址"}

    last_error = ""
    timeout = httpx.Timeout(1.0, connect=0.3)
    async with httpx.AsyncClient(timeout=timeout) as client:
        for base_url in candidates:
            for path in ("/json_metrics", "/metrics"):
                source_url = f"{base_url}{path}"
                try:
                    resp = await client.get(source_url)
                    resp.raise_for_status()
                    metrics = _parse_json_metrics(resp.json()) if path == "/json_metrics" else _parse_prometheus_metrics(resp.text)
                    if not metrics["validators"]:
                        last_error = f"{source_url} 没有 validator voting power metrics"
                        continue
                    return await _store_metrics(source_url, metrics, force)
                except Exception as exc:
                    last_error = f"{source_url}: {exc}"
                    continue

    return {"captured": False, "reason": last_error or "节点 metrics 不可用"}


def _inspection_urls() -> list[str]:
    settings = get_settings()
    cluster_dir = settings.cluster_dir
    if not cluster_dir:
        return []

    candidates: list[str] = []
    state_path = os.path.join(cluster_dir, ".prod_like_validator_cluster_state.json")
    if os.path.exists(state_path):
        try:
            with open(state_path) as f:
                state = json.load(f) or {}
            for node in state.get("nodes", []):
                ports = node.get("ports", {}) or {}
                port = ports.get("inspection_port")
                if port:
                    candidates.append(_local_http_url("127.0.0.1", port))
        except Exception as exc:
            logger.debug("failed to parse cluster state for inspection urls: %s", exc)

    for node_yaml in sorted(glob.glob(os.path.join(cluster_dir, "nodes", "*", "node.yaml"))):
        try:
            with open(node_yaml) as f:
                node_cfg = yaml.safe_load(f) or {}
            inspection = node_cfg.get("inspection_service", {}) or {}
            port = inspection.get("port")
            if not port:
                continue
            candidates.append(_local_http_url(str(inspection.get("address") or "127.0.0.1"), port))
        except Exception as exc:
            logger.debug("failed to parse inspection url from %s: %s", node_yaml, exc)

    deduped: list[str] = []
    seen = set()
    for candidate in candidates:
        if candidate not in seen:
            deduped.append(candidate)
            seen.add(candidate)
    return deduped


def _local_http_url(address: str, port: int | str) -> str:
    host = address.strip()
    if host.startswith("http://") or host.startswith("https://"):
        return host.rstrip("/")
    if host in {"0.0.0.0", "::", ""}:
        host = "127.0.0.1"
    return f"http://{host}:{port}"


def _parse_json_metrics(payload: dict[str, Any]) -> dict[str, Any]:
    validators: list[dict[str, Any]] = []
    for key, value in payload.items():
        if not key.startswith(JSON_VALIDATOR_POWER_PREFIX):
            continue
        peer_id = key.removeprefix(JSON_VALIDATOR_POWER_PREFIX)
        if not peer_id:
            continue
        validators.append({"peer_id": peer_id, "voting_power": _int_metric(value)})

    total = _int_metric(payload.get("aptos_total_voting_power"))
    if total <= 0:
        total = sum(item["voting_power"] for item in validators)
    validator_count = _int_metric(payload.get("aptos_consensus_current_epoch_validators")) or len(validators)
    return {
        "epoch": _int_metric(payload.get("aptos_consensus_epoch")),
        "total_voting_power": total,
        "validator_count": validator_count,
        "validators": validators,
    }


def _parse_prometheus_metrics(text: str) -> dict[str, Any]:
    epoch = 0
    total = 0
    validator_count = 0
    validators: list[dict[str, Any]] = []

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = PROM_VALUE_RE.match(line)
        if not match:
            continue
        name, labels, value = match.groups()
        metric_value = _int_metric(value)
        if name == "aptos_consensus_epoch":
            epoch = metric_value
        elif name == "aptos_total_voting_power":
            total = metric_value
        elif name == "aptos_consensus_current_epoch_validators":
            validator_count = metric_value
        elif name == "aptos_all_validators_voting_power" and labels:
            peer_match = PROM_PEER_ID_RE.search(labels)
            if peer_match:
                validators.append({"peer_id": peer_match.group(1), "voting_power": metric_value})

    if total <= 0:
        total = sum(item["voting_power"] for item in validators)
    if validator_count <= 0:
        validator_count = len(validators)
    return {
        "epoch": epoch,
        "total_voting_power": total,
        "validator_count": validator_count,
        "validators": validators,
    }


async def _store_metrics(source_url: str, metrics: dict[str, Any], force: bool) -> dict[str, Any]:
    epoch = int(metrics.get("epoch") or 0)
    if epoch <= 0:
        return {"captured": False, "reason": f"{source_url} 没有 aptos_consensus_epoch"}

    global _last_captured_epoch
    if not force and _last_captured_epoch == epoch:
        return {
            "captured": False,
            "skipped": True,
            "reason": "当前 epoch 已采集",
            "epoch": epoch,
            "source_url": source_url,
        }

    sampled_at = datetime.now(timezone.utc).isoformat()
    validators = sorted(metrics["validators"], key=lambda item: (str(item["peer_id"]).lower()))
    await history.upsert_consensus_validator_epoch_snapshot(
        sampled_at=sampled_at,
        epoch=epoch,
        source_url=source_url,
        rows=validators,
        total_voting_power=int(metrics.get("total_voting_power") or 0),
        validator_count=int(metrics.get("validator_count") or 0),
    )
    _last_captured_epoch = epoch

    result = {
        "captured": True,
        "sampled_at": sampled_at,
        "epoch": epoch,
        "source_url": source_url,
        "validators": len(validators),
        "total_voting_power": int(metrics.get("total_voting_power") or 0),
        "validator_count": int(metrics.get("validator_count") or len(validators)),
    }
    await broadcast("consensus_validator_power_sampled", result)
    return result


def _int_metric(value: Any) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0
