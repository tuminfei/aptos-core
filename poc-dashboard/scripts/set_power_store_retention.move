script {
    use topo_framework::poc_power_store;
    use topo_framework::topo_governance;

    fun main(core_resources: &signer, retention_bps_per_period: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        poc_power_store::set_retention_bps_per_period(&framework_signer, retention_bps_per_period);
    }
}
