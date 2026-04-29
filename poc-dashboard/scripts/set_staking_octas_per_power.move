script {
    use aptos_framework::staking_registry;
    use aptos_framework::topo_governance;

    fun main(core_resources: &signer, octas_per_power: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        staking_registry::set_octas_per_power(&framework_signer, octas_per_power);
    }
}
