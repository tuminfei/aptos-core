script {
    use topo_framework::poc_power_store;
    use topo_framework::topo_governance;

    fun main(
        core_resources: &signer,
        target_period: u64,
        users: vector<address>,
        powers: vector<u64>,
    ) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        poc_power_store::stage_batch_update(&framework_signer, target_period, users, powers);
    }
}
