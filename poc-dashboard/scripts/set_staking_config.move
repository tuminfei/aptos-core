script {
    use topo_framework::staking_config;
    use topo_framework::topo_governance;

    fun main(
        core_resources: &signer,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        voting_power_increase_limit: u64,
    ) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        staking_config::update_required_stake(&framework_signer, minimum_stake, maximum_stake);
        staking_config::update_recurring_lockup_duration_secs(&framework_signer, recurring_lockup_duration_secs);
        staking_config::update_voting_power_increase_limit(&framework_signer, voting_power_increase_limit);
    }
}
