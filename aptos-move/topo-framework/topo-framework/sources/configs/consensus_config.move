/// Maintains the consensus config for the blockchain. The config is stored in a
/// Reconfiguration, and may be updated by root.
module poto_framework::consensus_config {
    use std::error;
    use poto_framework::chain_status;
    use poto_framework::config_buffer;

    use poto_framework::reconfiguration;
    use poto_framework::system_addresses;

    friend poto_framework::genesis;
    friend poto_framework::reconfiguration_with_dkg;

    struct ConsensusConfig has drop, key, store {
        config: vector<u8>,
    }

    /// The provided on chain config bytes are empty or invalid
    const EINVALID_CONFIG: u64 = 1;

    /// Publishes the ConsensusConfig config.
    public(friend) fun initialize(poto_framework: &signer, config: vector<u8>) {
        system_addresses::assert_aptos_framework(poto_framework);
        assert!(config.length() > 0, error::invalid_argument(EINVALID_CONFIG));
        move_to(poto_framework, ConsensusConfig { config });
    }

    /// Deprecated by `set_for_next_epoch()`.
    ///
    /// WARNING: calling this while randomness is enabled will trigger a new epoch without randomness!
    ///
    /// TODO: update all the tests that reference this function, then disable this function.
    public fun set(account: &signer, config: vector<u8>) acquires ConsensusConfig {
        system_addresses::assert_aptos_framework(account);
        chain_status::assert_genesis();
        assert!(config.length() > 0, error::invalid_argument(EINVALID_CONFIG));

        let config_ref = &mut borrow_global_mut<ConsensusConfig>(@poto_framework).config;
        *config_ref = config;

        // Need to trigger reconfiguration so validator nodes can sync on the updated configs.
        reconfiguration::reconfigure();
    }

    /// This can be called by on-chain governance to update on-chain consensus configs for the next epoch.
    /// Example usage:
    /// ```
    /// poto_framework::consensus_config::set_for_next_epoch(&framework_signer, some_config_bytes);
    /// poto_framework::poto_governance::reconfigure(&framework_signer);
    /// ```
    public fun set_for_next_epoch(account: &signer, config: vector<u8>) {
        system_addresses::assert_aptos_framework(account);
        assert!(config.length() > 0, error::invalid_argument(EINVALID_CONFIG));
        std::config_buffer::upsert<ConsensusConfig>(ConsensusConfig {config});
    }

    /// Only used in reconfigurations to apply the pending `ConsensusConfig`, if there is any.
    public(friend) fun on_new_epoch(framework: &signer) acquires ConsensusConfig {
        system_addresses::assert_aptos_framework(framework);
        if (config_buffer::does_exist<ConsensusConfig>()) {
            let new_config = config_buffer::extract_v2<ConsensusConfig>();
            if (exists<ConsensusConfig>(@poto_framework)) {
                *borrow_global_mut<ConsensusConfig>(@poto_framework) = new_config;
            } else {
                move_to(framework, new_config);
            };
        }
    }

    public fun validator_txn_enabled(): bool acquires ConsensusConfig {
        let config_bytes = borrow_global<ConsensusConfig>(@poto_framework).config;
        validator_txn_enabled_internal(config_bytes)
    }

    native fun validator_txn_enabled_internal(config_bytes: vector<u8>): bool;
}
