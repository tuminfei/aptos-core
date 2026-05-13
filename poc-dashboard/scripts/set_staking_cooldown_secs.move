script {
    use topo_framework::staking_registry;
    use topo_framework::topo_governance;

    fun main(core_resources: &signer, cooldown_secs: u64) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        staking_registry::set_cooldown_secs(&framework_signer, cooldown_secs);
    }
}
