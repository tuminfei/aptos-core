script {
    use std::features;

    use topo_framework::poc_power_store;
    use topo_framework::staking_config;
    use topo_framework::topo_governance;
    use topo_std::fixed_point64;

    fun main(core_resources: &signer, power_period_in_epochs: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);

        poc_power_store::set_retention_bps_per_period(&framework_signer, 9998);
        poc_power_store::set_power_period_in_epochs(&framework_signer, power_period_in_epochs);

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
