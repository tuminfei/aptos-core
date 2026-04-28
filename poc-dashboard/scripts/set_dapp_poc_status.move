script {
    use aptos_framework::poc_registry;
    use aptos_framework::topo_governance;

    fun main(core_resources: &signer, app_admin: address, status: u8) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        poc_registry::set_poc_listing_status(&framework_signer, app_admin, status);
    }
}
