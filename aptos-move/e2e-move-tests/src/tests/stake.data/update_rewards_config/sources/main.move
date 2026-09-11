script {
    use topo_framework::topo_governance;
    use topo_framework::staking_config;
    use topo_std::fixed_point64;

    fun main(core_resources: &signer) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        staking_config::update_rewards_config(
            &framework_signer,
            fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(3, 1000),
            365 * 24 * 60 * 60,
            fixed_point64::create_from_rational(50, 100),
        );
        topo_governance::force_end_epoch(&framework_signer);
    }
}
