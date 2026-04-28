from app.models.db import get_db


async def upsert_config(
    *,
    app_admin: str,
    module_address: str,
    label: str = "",
    metadata_uri: str = "",
    initial_supply: int = 0,
    price_per_equity: int = 0,
    auto_whitelist: bool = False,
    deploy_tx_hash: str | None = None,
    register_tx_hash: str | None = None,
    whitelist_tx_hash: str | None = None,
) -> None:
    db = await get_db()
    await db.execute(
        """
        INSERT INTO dapp_demo_configs (
            app_admin, module_address, label, metadata_uri, initial_supply,
            price_per_equity, auto_whitelist, deploy_tx_hash, register_tx_hash,
            whitelist_tx_hash, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(app_admin) DO UPDATE SET
            module_address = excluded.module_address,
            label = excluded.label,
            metadata_uri = excluded.metadata_uri,
            initial_supply = excluded.initial_supply,
            price_per_equity = excluded.price_per_equity,
            auto_whitelist = excluded.auto_whitelist,
            deploy_tx_hash = excluded.deploy_tx_hash,
            register_tx_hash = excluded.register_tx_hash,
            whitelist_tx_hash = excluded.whitelist_tx_hash,
            updated_at = datetime('now')
        """,
        (
            app_admin,
            module_address,
            label,
            metadata_uri,
            initial_supply,
            price_per_equity,
            1 if auto_whitelist else 0,
            deploy_tx_hash,
            register_tx_hash,
            whitelist_tx_hash,
        ),
    )
    await db.commit()


async def get_config(app_admin: str) -> dict | None:
    db = await get_db()
    rows = await db.execute_fetchall(
        """
        SELECT app_admin, module_address, label, metadata_uri, initial_supply,
               price_per_equity, auto_whitelist, deploy_tx_hash, register_tx_hash,
               whitelist_tx_hash, created_at, updated_at
        FROM dapp_demo_configs
        WHERE app_admin = ?
        """,
        (app_admin,),
    )
    if not rows:
        return None
    return _row_to_config(rows[0])


async def get_configs(app_admins: list[str] | None = None) -> dict[str, dict]:
    db = await get_db()
    if app_admins:
        placeholders = ",".join(["?"] * len(app_admins))
        rows = await db.execute_fetchall(
            f"""
            SELECT app_admin, module_address, label, metadata_uri, initial_supply,
                   price_per_equity, auto_whitelist, deploy_tx_hash, register_tx_hash,
                   whitelist_tx_hash, created_at, updated_at
            FROM dapp_demo_configs
            WHERE app_admin IN ({placeholders})
            """,
            app_admins,
        )
    else:
        rows = await db.execute_fetchall(
            """
            SELECT app_admin, module_address, label, metadata_uri, initial_supply,
                   price_per_equity, auto_whitelist, deploy_tx_hash, register_tx_hash,
                   whitelist_tx_hash, created_at, updated_at
            FROM dapp_demo_configs
            """
        )
    return {row[0]: _row_to_config(row) for row in rows}


def _row_to_config(row) -> dict:
    return {
        "app_admin": row[0],
        "module_address": row[1],
        "label": row[2] or "",
        "metadata_uri": row[3] or "",
        "initial_supply": int(row[4] or 0),
        "price_per_equity": int(row[5] or 0),
        "auto_whitelist": bool(row[6]),
        "deploy_tx_hash": row[7],
        "register_tx_hash": row[8],
        "whitelist_tx_hash": row[9],
        "created_at": row[10],
        "updated_at": row[11],
    }
