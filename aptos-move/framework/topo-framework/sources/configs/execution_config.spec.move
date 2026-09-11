spec topo_framework::execution_config {
    spec module {
        pragma verify = true;
        pragma aborts_if_is_strict;
    }

    /// Ensure the caller is admin
    /// When setting now time must be later than last_reconfiguration_time.
    spec set(account: &signer, config: vector<u8>) {
        use topo_framework::timestamp;
        use std::signer;
        use std::features;
        use topo_framework::chain_status;
        use topo_framework::staking_config;
        use topo_framework::topo_coin;

        let addr = signer::address_of(account);
        requires chain_status::is_genesis();
        requires exists<staking_config::StakingRewardsConfig>(@topo_framework);
        requires len(config) > 0;
        include features::spec_periodical_reward_rate_decrease_enabled() ==> staking_config::StakingRewardsConfigEnabledRequirement;
        include topo_coin::ExistsTopoCoin;
        requires system_addresses::is_topo_framework_address(addr);
        requires timestamp::spec_now_microseconds() >= reconfiguration::last_reconfiguration_time();

        ensures exists<ExecutionConfig>(@topo_framework);
    }

    spec set_for_next_epoch(account: &signer, config: vector<u8>) {
        aborts_if topo_framework::reconfiguration_state::spec_is_in_progress();
        pragma opaque;
        modifies global<config_buffer::PendingConfigs>(@topo_framework);
        include config_buffer::SetForNextEpochAbortsIf;
        let key = std::type_info::type_name<ExecutionConfig>();
        let post configs_post = global<config_buffer::PendingConfigs>(@topo_framework).configs;
        ensures std::simple_map::spec_contains_key(configs_post, key);
        ensures std::simple_map::spec_get(configs_post, key) == std::any::pack(ExecutionConfig { config });
    }

    spec on_new_epoch(framework: &signer) {
        pragma opaque;
        include config_buffer::OnNewEpochApply<ExecutionConfig>;
    }
}
