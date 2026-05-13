script {
    use topo_framework::block;
    use topo_framework::topo_governance;

    fun main(core_resources: &signer, epoch_interval_microsecs: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        block::update_epoch_interval_microsecs(&framework_signer, epoch_interval_microsecs);
    }
}
