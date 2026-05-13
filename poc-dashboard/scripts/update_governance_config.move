script {
    use topo_framework::topo_governance;

    fun main(
        core_resources: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @topo_framework);
        topo_governance::update_governance_config(
            &framework_signer,
            min_voting_threshold,
            required_proposer_stake,
            voting_duration_secs,
        );
    }
}
