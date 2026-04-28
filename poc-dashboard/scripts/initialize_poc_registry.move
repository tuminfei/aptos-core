script {
    use aptos_framework::poc_registry;
    use aptos_framework::topo_governance;

    fun main(core_resources: &signer) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        poc_registry::initialize_registry(&framework_signer);
    }
}
