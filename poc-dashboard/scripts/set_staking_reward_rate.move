script {
    use aptos_framework::staking_config;
    use aptos_framework::topo_governance;

    fun main(
        core_resources: &signer,
        new_rewards_rate: u64,
        new_rewards_rate_denominator: u64,
    ) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        staking_config::update_rewards_rate(&framework_signer, new_rewards_rate, new_rewards_rate_denominator);
    }
}
