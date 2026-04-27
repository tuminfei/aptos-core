script {
    use std::features;

    use aptos_framework::poc_power_store;
    use aptos_framework::staking_config;
    use aptos_framework::topo_governance;
    use aptos_std::fixed_point64;

    fun main(core_resources: &signer) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);

        poc_power_store::set_retention_bps_per_period(&framework_signer, 9998);
        poc_power_store::set_power_period_in_epochs(&framework_signer, 1);

        if (features::periodical_reward_rate_decrease_enabled()) {
            staking_config::update_rewards_config(
                &framework_signer,
                fixed_point64::create_from_rational(10000, 1000000000),
                fixed_point64::create_from_rational(0, 1000),
                365 * 24 * 60 * 60,
                fixed_point64::create_from_rational(0, 1000),
            );
        } else {
            staking_config::update_rewards_rate(&framework_signer, 10000, 1000000000);
        };
    }
}
