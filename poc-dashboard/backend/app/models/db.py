import aiosqlite
from typing import Optional

_db_path: str = "./poc_dashboard.db"
_db: Optional[aiosqlite.Connection] = None

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS operation_logs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    action      TEXT NOT NULL,
    target      TEXT,
    params      TEXT,
    tx_hash     TEXT,
    status      TEXT NOT NULL,
    error       TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_logs_action ON operation_logs(action);
CREATE INDEX IF NOT EXISTS idx_logs_created ON operation_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_logs_target ON operation_logs(target);

CREATE TABLE IF NOT EXISTS watch_addresses (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    kind        TEXT NOT NULL,
    address     TEXT NOT NULL,
    label       TEXT,
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(kind, address)
);

CREATE INDEX IF NOT EXISTS idx_watch_kind_enabled ON watch_addresses(kind, enabled);

CREATE TABLE IF NOT EXISTS event_cursors (
    event_key   TEXT PRIMARY KEY,
    last_version TEXT NOT NULL,
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS managed_keys (
    address     TEXT PRIMARY KEY,
    private_key TEXT NOT NULL,
    label       TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS dapp_demo_configs (
    app_admin           TEXT PRIMARY KEY,
    module_address      TEXT NOT NULL,
    label               TEXT,
    metadata_uri        TEXT,
    initial_supply      INTEGER NOT NULL DEFAULT 0,
    price_per_equity    INTEGER NOT NULL DEFAULT 0,
    auto_whitelist      INTEGER NOT NULL DEFAULT 0,
    deploy_tx_hash      TEXT,
    register_tx_hash    TEXT,
    whitelist_tx_hash   TEXT,
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_dapp_demo_module ON dapp_demo_configs(module_address);

CREATE TABLE IF NOT EXISTS dapp_demo_trade_tasks (
    app_admin             TEXT PRIMARY KEY,
    task_id               TEXT NOT NULL,
    module_address        TEXT NOT NULL,
    interval_secs         REAL NOT NULL,
    tx_per_tick           INTEGER NOT NULL DEFAULT 1,
    amount_min            INTEGER NOT NULL DEFAULT 0,
    amount_max            INTEGER NOT NULL DEFAULT 0,
    max_runs              INTEGER NOT NULL DEFAULT 0,
    buyer_addresses       TEXT NOT NULL DEFAULT '[]',
    buyer_selection_mode  TEXT NOT NULL DEFAULT 'fixed',
    auto_create_buyers    INTEGER NOT NULL DEFAULT 0,
    mint_octas            INTEGER NOT NULL DEFAULT 0,
    max_gas               INTEGER NOT NULL DEFAULT 0,
    gas_unit_price        INTEGER NOT NULL DEFAULT 0,
    status                TEXT NOT NULL DEFAULT 'running',
    run_count             INTEGER NOT NULL DEFAULT 0,
    success_count         INTEGER NOT NULL DEFAULT 0,
    failure_count         INTEGER NOT NULL DEFAULT 0,
    last_tx_hash          TEXT,
    last_error            TEXT,
    created_at_epoch      REAL NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at            TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_dapp_demo_trade_tasks_status ON dapp_demo_trade_tasks(status);

CREATE TABLE IF NOT EXISTS contribution_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    tx_hash         TEXT NOT NULL,
    event_index     INTEGER NOT NULL DEFAULT 0,
    version         INTEGER NOT NULL DEFAULT 0,
    app_admin       TEXT,
    app_address     TEXT NOT NULL,
    contributor     TEXT NOT NULL,
    equity_token    TEXT,
    equity_amount   INTEGER NOT NULL DEFAULT 0,
    event_type      TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    raw_event       TEXT,
    UNIQUE(tx_hash, event_index)
);

CREATE INDEX IF NOT EXISTS idx_contribution_events_contributor ON contribution_events(contributor, created_at);
CREATE INDEX IF NOT EXISTS idx_contribution_events_app_admin ON contribution_events(app_admin, created_at);
CREATE INDEX IF NOT EXISTS idx_contribution_events_app_address ON contribution_events(app_address, created_at);
CREATE INDEX IF NOT EXISTS idx_contribution_events_tx_hash ON contribution_events(tx_hash);

CREATE TABLE IF NOT EXISTS chain_snapshots (
    id                              INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at                      TEXT NOT NULL,
    chain_id                        INTEGER NOT NULL DEFAULT 0,
    epoch                           INTEGER NOT NULL DEFAULT 0,
    ledger_version                  INTEGER NOT NULL DEFAULT 0,
    block_height                    INTEGER NOT NULL DEFAULT 0,
    ledger_timestamp                TEXT,
    current_period                  INTEGER NOT NULL DEFAULT 0,
    power_period_in_epochs          INTEGER NOT NULL DEFAULT 0,
    retention_bps                   INTEGER NOT NULL DEFAULT 0,
    reward_rate_numerator           INTEGER NOT NULL DEFAULT 0,
    reward_rate_denominator         INTEGER NOT NULL DEFAULT 0,
    reward_rate_bps                 INTEGER NOT NULL DEFAULT 0,
    active_validator_count          INTEGER NOT NULL DEFAULT 0,
    pending_active_validator_count  INTEGER NOT NULL DEFAULT 0,
    pending_inactive_validator_count INTEGER NOT NULL DEFAULT 0,
    total_staked_power              INTEGER NOT NULL DEFAULT 0,
    octas_per_power                 INTEGER NOT NULL DEFAULT 0,
    cooldown_secs                   INTEGER NOT NULL DEFAULT 0,
    voting_duration_secs            INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_chain_snapshots_sampled ON chain_snapshots(sampled_at);
CREATE INDEX IF NOT EXISTS idx_chain_snapshots_epoch ON chain_snapshots(epoch);

CREATE TABLE IF NOT EXISTS validator_snapshots (
    id                              INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at                      TEXT NOT NULL,
    epoch                           INTEGER NOT NULL DEFAULT 0,
    address                         TEXT NOT NULL,
    label                           TEXT,
    status                          TEXT NOT NULL DEFAULT 'unknown',
    status_code                     INTEGER NOT NULL DEFAULT 0,
    in_watchlist                    INTEGER NOT NULL DEFAULT 0,
    voting_power                    INTEGER NOT NULL DEFAULT 0,
    commission_bps                  INTEGER NOT NULL DEFAULT 0,
    delegator_count                 INTEGER NOT NULL DEFAULT 0,
    total_pool_power                INTEGER NOT NULL DEFAULT 0,
    stake_active_octas              INTEGER NOT NULL DEFAULT 0,
    stake_inactive_octas            INTEGER NOT NULL DEFAULT 0,
    stake_pending_active_octas      INTEGER NOT NULL DEFAULT 0,
    stake_pending_inactive_octas    INTEGER NOT NULL DEFAULT 0,
    proposals_successful            INTEGER NOT NULL DEFAULT 0,
    proposals_failed                INTEGER NOT NULL DEFAULT 0,
    estimated_epoch_reward_octas    INTEGER NOT NULL DEFAULT 0,
    estimated_epoch_fee_octas       INTEGER NOT NULL DEFAULT 0,
    estimated_epoch_total_octas     INTEGER NOT NULL DEFAULT 0,
    estimated_commission_octas      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_validator_snapshots_address_sampled ON validator_snapshots(address, sampled_at);
CREATE INDEX IF NOT EXISTS idx_validator_snapshots_epoch ON validator_snapshots(epoch);

CREATE TABLE IF NOT EXISTS user_snapshots (
    id                                  INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at                          TEXT NOT NULL,
    epoch                               INTEGER NOT NULL DEFAULT 0,
    address                             TEXT NOT NULL,
    label                               TEXT,
    balance_octas                       INTEGER NOT NULL DEFAULT 0,
    committed_power                     INTEGER NOT NULL DEFAULT 0,
    effective_power                     INTEGER NOT NULL DEFAULT 0,
    power_for_next_epoch                INTEGER NOT NULL DEFAULT 0,
    deposit_octas                       INTEGER NOT NULL DEFAULT 0,
    delegated_to                        TEXT NOT NULL DEFAULT '0x0',
    cooldown_until_secs                 INTEGER NOT NULL DEFAULT 0,
    is_in_cooldown                      INTEGER NOT NULL DEFAULT 0,
    estimated_epoch_reward_octas        INTEGER NOT NULL DEFAULT 0,
    estimated_epoch_fee_octas           INTEGER NOT NULL DEFAULT 0,
    estimated_epoch_total_octas         INTEGER NOT NULL DEFAULT 0,
    estimated_owner_commission_octas    INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_user_snapshots_address_sampled ON user_snapshots(address, sampled_at);
CREATE INDEX IF NOT EXISTS idx_user_snapshots_epoch ON user_snapshots(epoch);

CREATE TABLE IF NOT EXISTS user_power_period_history (
    id                              INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at                      TEXT NOT NULL,
    epoch                           INTEGER NOT NULL DEFAULT 0,
    address                         TEXT NOT NULL,
    label                           TEXT,
    period                          INTEGER NOT NULL,
    raw_power                       INTEGER NOT NULL DEFAULT 0,
    source_slot                     TEXT NOT NULL DEFAULT '',
    observed_current_period         INTEGER NOT NULL DEFAULT 0,
    observed_next_epoch_period      INTEGER NOT NULL DEFAULT 0,
    observed_committed_power        INTEGER NOT NULL DEFAULT 0,
    created_at                      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at                      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(address, period)
);

CREATE INDEX IF NOT EXISTS idx_user_power_period_address_period ON user_power_period_history(address, period);
CREATE INDEX IF NOT EXISTS idx_user_power_period_sampled ON user_power_period_history(sampled_at);

CREATE TABLE IF NOT EXISTS reward_epoch_estimates (
    id                              INTEGER PRIMARY KEY AUTOINCREMENT,
    kind                            TEXT NOT NULL,
    address                         TEXT NOT NULL,
    epoch                           INTEGER NOT NULL,
    sampled_at                      TEXT NOT NULL,
    reward_octas                    INTEGER NOT NULL DEFAULT 0,
    fee_octas                       INTEGER NOT NULL DEFAULT 0,
    total_estimated_reward_octas    INTEGER NOT NULL DEFAULT 0,
    owner_commission_octas          INTEGER NOT NULL DEFAULT 0,
    created_at                      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(kind, address, epoch)
);

CREATE INDEX IF NOT EXISTS idx_reward_epoch_address ON reward_epoch_estimates(kind, address, epoch);

CREATE TABLE IF NOT EXISTS consensus_validator_epoch_snapshots (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    sampled_at          TEXT NOT NULL,
    epoch               INTEGER NOT NULL,
    source_url          TEXT,
    peer_id             TEXT NOT NULL,
    voting_power        INTEGER NOT NULL DEFAULT 0,
    total_voting_power  INTEGER NOT NULL DEFAULT 0,
    validator_count     INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(epoch, peer_id)
);

CREATE INDEX IF NOT EXISTS idx_consensus_validator_epoch ON consensus_validator_epoch_snapshots(epoch);
CREATE INDEX IF NOT EXISTS idx_consensus_validator_peer_epoch ON consensus_validator_epoch_snapshots(peer_id, epoch);
"""


async def init_db(db_path: str = "./poc_dashboard.db"):
    global _db_path, _db
    _db_path = db_path
    _db = await aiosqlite.connect(_db_path)
    _db.row_factory = aiosqlite.Row
    await _db.executescript(SCHEMA_SQL)
    await _db.commit()


async def get_db() -> aiosqlite.Connection:
    global _db
    if _db is None:
        await init_db(_db_path)
    return _db


async def close_db():
    global _db
    if _db:
        await _db.close()
        _db = None
