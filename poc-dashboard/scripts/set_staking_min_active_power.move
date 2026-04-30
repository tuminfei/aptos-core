script {
    use aptos_framework::staking_registry;
    use aptos_framework::topo_governance;

    fun main(core_resources: &signer, min_active_power: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        staking_registry::set_min_active_power(&framework_signer, min_active_power);
    }
}
