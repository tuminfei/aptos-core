script {
    use aptos_framework::staking_config;
    use aptos_framework::topo_governance;
    use aptos_std::fixed_point64;

    fun main(
        core_resources: &signer,
        rewards_rate_numerator: u128,
        rewards_rate_denominator: u128,
        min_rewards_rate_numerator: u128,
        min_rewards_rate_denominator: u128,
        rewards_rate_decrease_rate_numerator: u128,
        rewards_rate_decrease_rate_denominator: u128,
        rewards_rate_period_in_secs: u64,
    ) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        staking_config::update_rewards_config(
            &framework_signer,
            fixed_point64::create_from_rational(rewards_rate_numerator, rewards_rate_denominator),
            fixed_point64::create_from_rational(min_rewards_rate_numerator, min_rewards_rate_denominator),
            rewards_rate_period_in_secs,
            fixed_point64::create_from_rational(
                rewards_rate_decrease_rate_numerator,
                rewards_rate_decrease_rate_denominator,
            ),
        );
    }
}
