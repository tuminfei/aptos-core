script {
    use topo_framework::poc_power_store;
    use topo_framework::topo_governance;

    fun main(core_resources: &signer, new_operator: address) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        poc_power_store::set_operator(&framework_signer, new_operator);
    }
}
