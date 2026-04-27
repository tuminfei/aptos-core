from nacl.signing import SigningKey
from nacl.encoding import RawEncoder
import hashlib


class Ed25519Key:
    def __init__(self, private_key_hex: str):
        hex_str = private_key_hex.removeprefix("0x")
        if len(hex_str) < 2:
            self._signing_key = SigningKey.generate()
            return
        raw = bytes.fromhex(hex_str)
        self._signing_key = SigningKey(raw[:32])

    @property
    def private_key_hex(self) -> str:
        return "0x" + bytes(self._signing_key).hex()

    @property
    def public_key_bytes(self) -> bytes:
        return bytes(self._signing_key.verify_key)

    @property
    def public_key_hex(self) -> str:
        return "0x" + self.public_key_bytes.hex()

    @property
    def auth_key(self) -> str:
        h = hashlib.sha3_256()
        h.update(self.public_key_bytes + b"\x00")
        return "0x" + h.hexdigest()

    @property
    def account_address(self) -> str:
        return self.auth_key

    def sign(self, data: bytes) -> bytes:
        return self._signing_key.sign(data, encoder=RawEncoder)[:64]


class KeyManager:
    def __init__(self):
        self.core_resources_key: Ed25519Key | None = None
        self.core_resources_address: str = ""
        self.operator_keys: dict[str, Ed25519Key] = {}
        self.operator_addresses: dict[str, str] = {}

    def load_from_config(self, keys_config):
        cr = keys_config.core_resources
        self.core_resources_key = Ed25519Key(cr.private_key)
        self.core_resources_address = cr.address

        for op in keys_config.operators:
            self.operator_keys[op.name] = Ed25519Key(op.private_key)
            self.operator_addresses[op.name] = op.address

    def get_operator_key(self, name: str) -> Ed25519Key | None:
        return self.operator_keys.get(name)

    def get_operator_key_by_address(self, address: str) -> Ed25519Key | None:
        for name, addr in self.operator_addresses.items():
            if addr.lower() == address.lower():
                return self.operator_keys[name]
        return None

    def _key_name(self, label: str, address: str) -> str:
        name = label or address
        existing_addr = self.operator_addresses.get(name)
        if existing_addr and existing_addr.lower() != address.lower():
            return address
        return name

    def generate_account(self, label: str = "") -> tuple[Ed25519Key, str]:
        key = Ed25519Key("0x")  # generates random
        address = key.account_address
        name = self._key_name(label, address)
        self.operator_keys[name] = key
        self.operator_addresses[name] = address
        return key, address

    def register_key(self, private_key_hex: str, label: str = "") -> tuple[Ed25519Key, str]:
        key = Ed25519Key(private_key_hex)
        address = key.account_address
        name = self._key_name(label, address)
        self.operator_keys[name] = key
        self.operator_addresses[name] = address
        return key, address

    async def load_managed_keys(self):
        """Load persisted keys from DB into memory."""
        from app.models.db import get_db
        db = await get_db()
        rows = await db.execute_fetchall("SELECT address, private_key, label FROM managed_keys")
        for r in rows:
            addr, pk, label = r[0], r[1], r[2] or ""
            key = Ed25519Key(pk)
            name = label or addr
            existing_addr = self.operator_addresses.get(name)
            if existing_addr and existing_addr.lower() != addr.lower():
                name = addr
            self.operator_keys[name] = key
            self.operator_addresses[name] = addr
        if rows:
            print(f"[keys] 从数据库加载 {len(rows)} 个托管密钥")

    async def persist_key(self, key: Ed25519Key, address: str, label: str = ""):
        """Save a generated key to DB for persistence."""
        from app.models.db import get_db
        db = await get_db()
        await db.execute(
            "INSERT OR REPLACE INTO managed_keys (address, private_key, label) VALUES (?, ?, ?)",
            (address, key.private_key_hex, label),
        )
        await db.commit()


_key_manager: KeyManager | None = None


def get_key_manager() -> KeyManager:
    global _key_manager
    if _key_manager is None:
        _key_manager = KeyManager()
    return _key_manager
