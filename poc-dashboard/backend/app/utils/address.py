import re


_HEX_RE = re.compile(r"^(0x)?[0-9a-fA-F]+$")


def normalize_hex(value: object) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    if text.startswith(("0x", "0X")):
        text = text[2:]
    if not text or not _HEX_RE.match(text):
        return str(value or "").strip().lower()
    return f"0x{text.lower()}"


def address_key(value: object) -> str:
    normalized = normalize_hex(value)
    if not normalized.startswith("0x"):
        return normalized
    body = normalized[2:]
    if not body:
        return ""
    return f"0x{body.lstrip('0') or '0'}"


def full_address(value: object) -> str:
    normalized = normalize_hex(value)
    if not normalized.startswith("0x"):
        return normalized
    body = normalized[2:]
    if not body or len(body) > 64:
        return normalized
    return f"0x{body.rjust(64, '0')}"


def address_variants(value: object) -> list[str]:
    variants = []
    for candidate in (normalize_hex(value), address_key(value), full_address(value)):
        if candidate and candidate not in variants:
            variants.append(candidate)
    return variants or [""]
