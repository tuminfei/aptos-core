script {
    use aptos_framework::block;
    use aptos_framework::topo_governance;

    fun main(core_resources: &signer, epoch_interval_microsecs: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @aptos_framework);
        block::update_epoch_interval_microsecs(&framework_signer, epoch_interval_microsecs);
    }
}
