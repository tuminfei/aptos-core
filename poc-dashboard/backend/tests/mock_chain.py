from typing import Any


class MockChainClient:
    def __init__(self):
        self.base_url = "http://mock:8080/v1"
        self.submitted_txns: list[dict] = []
        self._tx_counter = 0
        self._view_responses: dict[str, Any] = {}
        self._resources: dict[str, dict] = {}
        self._setup_defaults()

    def _setup_defaults(self):
        self._ledger_info = {
            "chain_id": 4,
            "epoch": "142",
            "ledger_version": "58923",
            "block_height": "5821",
            "ledger_timestamp": "1719000000000000",
        }
        v = {
            "0x1::poc_power_store::get_current_period": [23],
            "0x1::poc_power_store::get_power_period_in_epochs": [5],
            "0x1::poc_power_store::get_retention_bps_per_period": [9950],
            "0x1::poc_power_store::get_operator": ["0xabc"],
            "0x1::poc_power_store::get_user_committed_power": [5000],
            "0x1::poc_power_store::get_user_committed_powers": [[5000, 3000]],
            "0x1::poc_power_store::get_user_power_for_period": [4500],
            "0x1::poc_power_store::get_user_committed_power_for_next_epoch": [5000],
            "0x1::poc_power_store::get_user_power_version": [20, 4000, 23, 5000, 5000],
            "0x1::poc_power_store::get_user_power_versions_by_addresses": [["0xaaa"], [20], [4000], [23], [5000], [5000]],
            "0x1::staking_registry::get_user_stake_info": [50000000000, "0x1a2b", 0],
            "0x1::staking_registry::get_effective_power": [5000],
            "0x1::staking_registry::get_validator_total_power": [10000],
            "0x1::staking_registry::get_validator_joining_power": [5000],
            "0x1::staking_registry::get_total_staked_power": [40000],
            "0x1::staking_registry::get_validator_commission_bps": [1000],
            "0x1::stake::get_pending_transaction_fee": [[110000000, 220000000]],
            "0x1::staking_config::reward_rate": [1, 100],
            "0x1::staking_registry::get_cooldown_secs": [3600],
            "0x1::staking_registry::get_octas_per_power": [10000000],
            "0x1::staking_registry::get_min_active_power": [1],
            "0x1::staking_registry::get_force_exit_power_bps": [8000],
            "0x1::staking_registry::validator_exists": [True],
            "0x1::staking_registry::get_validator_view": ["0x1a2b", "0x1a2b", 1000, 2, 5, 5000, 10000],
            "0x1::staking_registry::get_validator_views_by_addresses": [["0x1a2b"], ["0x1a2b"], [1000], [2], [5], [5000], [10000]],
            "0x1::staking_registry::get_user_stake_view": ["0xaaa", 50000000000, "0x1a2b", 0, 5000, 5000],
            "0x1::staking_registry::get_user_stake_views_by_addresses": [["0xaaa"], [50000000000], ["0x1a2b"], [0], [5000], [5000]],
            "0x1::staking_registry::get_validator_delegator_count": [2],
            "0x1::staking_registry::get_validator_delegators": [["0xaaa", "0xbbb"]],
            "0x1::staking_registry::get_validator_delegator_views": [["0xaaa", "0xbbb"], [50000000000, 30000000000], [5000, 3000], [5000, 3000]],
            "0x1::stake::get_validator_state": [2],
            "0x1::stake::get_current_epoch_voting_power": [10000],
            "0x1::stake::get_stake": [100000000000, 0, 0, 0],
            "0x1::stake::get_operator": ["0x3c4d"],
            "0x1::stake::get_validator_index": [0],
            "0x1::stake::get_current_epoch_proposal_counts": [120, 2],
            "0x1::stake::get_validator_config": ["0xpubkey", "0xnetaddr", "0xfnaddr"],
            "0x1::stake::is_current_epoch_validator": [True],
            "0x1::stake::stake_pool_exists": [True],
            "0x1::stake::get_active_validator_count": [4],
            "0x1::stake::get_pending_active_validator_count": [1],
            "0x1::stake::get_pending_inactive_validator_count": [0],
            "0x1::stake::get_active_validators": [["0x1a2b", "0x3c4d"]],
            "0x1::stake::get_pending_active_validators": [["0x5e6f"]],
            "0x1::stake::get_pending_inactive_validators": [[]],
            "0x1::topo_governance::get_voting_duration_secs": [86400],
            "0x1::topo_governance::get_min_voting_threshold": [50000],
            "0x1::topo_governance::get_required_proposer_stake": [10000],
            "0x1::poc_registry::get_app_info": [{"admin": "0xddd", "app_address": "0xeee"}],
            "0x1::poc_registry::get_app_infos_by_admins": [[{"admin": "0xddd"}]],
            "0x1::poc_registry::exists_apps": [[True]],
            "0x1::poc_registry::get_app_state": [1],
            "0x1::poc_registry::get_poc_listing_status": [2],
            "0x1::poc_registry::get_effective_weight_pbs": [5000],
            "0xabc::poc_demo::custody_inventory": [100],
            "0x1::coin::balance": [100000000000],
        }
        self._view_responses = v
        self.set_resource(
            "0x1",
            "0x1::poc_power_store::PowerPeriodClock",
            {
                "type": "0x1::poc_power_store::PowerPeriodClock",
                "data": {"epochs_until_next_power_period": "2"},
            },
        )

    def set_view_response(self, function_id: str, response: list):
        self._view_responses[function_id] = response

    def set_resource(self, address: str, resource_type: str, resource: dict):
        self._resources[f"{address}:{resource_type}"] = resource

    def remove_view_response(self, function_id: str):
        self._view_responses.pop(function_id, None)

    async def close(self):
        pass

    async def get_ledger_info(self) -> dict:
        return self._ledger_info

    async def get_account(self, address: str) -> dict:
        return {"sequence_number": "0", "authentication_key": address}

    async def account_exists(self, address: str) -> bool:
        return True

    async def get_account_resource(self, address: str, resource_type: str) -> dict | None:
        key = f"{address}:{resource_type}"
        if key in self._resources:
            return self._resources[key]
        if "CoinStore" in resource_type:
            return {"data": {"coin": {"value": "100000000000"}}}
        return None

    async def call_view(self, function_id: str, type_args=None, args=None) -> list:
        fn = function_id.split("::")[-1]
        for key, val in self._view_responses.items():
            if key.endswith(f"::{fn}") or key == function_id:
                return val
        return [0]

    async def get_account_sequence_number(self, address: str) -> int:
        return 0

    async def encode_submission(self, raw_txn: dict) -> bytes:
        return b"\x00" * 32

    async def submit_transaction(self, signed_txn: dict) -> dict:
        self._tx_counter += 1
        tx_hash = f"0x{'a' * 62}{self._tx_counter:02d}"
        self.submitted_txns.append({**signed_txn, "hash": tx_hash})
        return {"hash": tx_hash}

    async def wait_for_transaction(self, tx_hash: str, timeout_secs: int = 30) -> dict:
        txn = await self.get_transaction_by_hash(tx_hash)
        if txn:
            return txn
        return {"hash": tx_hash, "success": True, "type": "user_transaction", "vm_status": "Executed successfully", "events": []}

    async def get_transaction_by_hash(self, tx_hash: str) -> dict | None:
        tx = next((item for item in self.submitted_txns if item.get("hash") == tx_hash), None)
        events = []
        if tx and tx.get("payload", {}).get("function", "").endswith("::buy_equity"):
            args = tx.get("payload", {}).get("arguments", [])
            events = [{
                "type": "0x1::poc_contribution::ContributionEvent",
                "data": {
                    "contributor": tx.get("sender", ""),
                    "equity_token": "0xasset",
                    "equity_amount": args[1] if len(args) > 1 else "0",
                    "app_address": tx.get("payload", {}).get("function", "").split("::")[0],
                },
            }]
        return {
            "hash": tx_hash,
            "version": str(self._tx_counter),
            "success": True,
            "type": "user_transaction",
            "vm_status": "Executed successfully",
            "events": events,
        }

    async def get_transactions(self, start: int | None = None, limit: int = 25) -> list:
        return [
            {
                "version": "58901",
                "events": [
                    {
                        "sequence_number": "0",
                        "type": "0x1::poc_power_store::PowerUpdateStagedEvent",
                        "data": {"target_period": "24", "effective_period": "24", "user": "0xaaa", "power": "5000"},
                    }
                ],
                "type": "user_transaction",
            },
            {
                "version": "58900",
                "events": [
                    {
                        "sequence_number": "0",
                        "type": "0x1::test::TestEvent",
                        "data": {"key": "value"},
                    }
                ],
                "type": "user_transaction",
            },
        ][:limit]

    async def get_events(self, address, event_handle, field_name, start=0, limit=25) -> list:
        return [
            {"version": "58900", "sequence_number": "0", "type": "0x1::test::TestEvent", "data": {"key": "value"}},
        ]
