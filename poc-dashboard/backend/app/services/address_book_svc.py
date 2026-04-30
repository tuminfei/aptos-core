from app.chain import view
from app.chain.client import ChainClient, get_chain_client
from app.chain.keys import get_key_manager
from app.models import watchlist
from app.utils.address import address_key, address_variants


def _normalize_default_validator_name(name: str) -> str:
    if name.startswith("validator-") and name.removeprefix("validator-").isdigit():
        return f"验证者{name.removeprefix('validator-')}"
    return name


async def build_address_book(client: ChainClient | None = None, include_chain_validators: bool = True) -> dict[str, dict]:
    client = client or get_chain_client()
    entries: dict[str, dict] = {}

    def put(address: str, kind: str, name: str = "", label: str = "", source: str = "") -> None:
        if not address:
            return
        key = address_key(address)
        current = entries.get(key)
        if not current:
            current = {
                "address": address,
                "kind": kind,
                "name": "",
                "label": "",
                "source": source,
            }
            entries[key] = current
        if kind == "user" and current.get("kind") not in {"validator", "dapp"}:
            current["kind"] = "user"
        if kind == "validator":
            current["kind"] = "validator"
        if label and not current.get("label"):
            current["label"] = label
        if name and not current.get("name"):
            current["name"] = name
        if source and not current.get("source"):
            current["source"] = source

    for item in await watchlist.get_all_addresses():
        kind = item.get("kind", "")
        if kind not in {"user", "validator", "dapp"}:
            continue
        label = item.get("label", "") or ""
        put(item.get("address", ""), kind, label, label, "watchlist")

    km = get_key_manager()
    for key_name, address in km.operator_addresses.items():
        display_name = _normalize_default_validator_name(key_name)
        if display_name and display_name != address:
            put(address, "validator" if key_name.startswith("validator") else "user", display_name, display_name, "keys")

    if include_chain_validators:
        for getter in (view.get_active_validators, view.get_pending_active_validators):
            try:
                for address in await getter(client, 0, 200):
                    put(address, "validator", "", "", "chain")
            except Exception:
                pass

    validator_addresses = [
        entry["address"]
        for entry in entries.values()
        if entry.get("kind") == "validator" and not entry.get("name")
    ]
    for address in validator_addresses:
        try:
            idx = await view.get_validator_index(client, address)
            entries[address_key(address)]["name"] = f"验证者{idx}"
        except Exception:
            entries[address_key(address)]["name"] = "验证者"

    for entry in entries.values():
        if not entry.get("name"):
            entry["name"] = entry.get("label") or ""
        entry["display_name"] = entry.get("name") or entry.get("label") or ""

    for entry in list(entries.values()):
        for alias in address_variants(entry.get("address", "")):
            entries.setdefault(alias, entry)

    return entries


async def get_display_name(address: str, kind: str = "", client: ChainClient | None = None) -> str:
    if not address:
        return ""
    book = await build_address_book(client)
    entry = book.get(address_key(address))
    if entry and (not kind or entry.get("kind") == kind):
        return entry.get("display_name", "")
    return ""
