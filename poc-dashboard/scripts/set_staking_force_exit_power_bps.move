script {
    use topo_framework::staking_registry;
    use topo_framework::topo_governance;

    fun main(core_resources: &signer, force_exit_power_bps: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        staking_registry::set_force_exit_power_bps(&framework_signer, force_exit_power_bps);
    }
}
