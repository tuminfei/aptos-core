// Enable confidential transfers for APT.
script {
    use topo_framework::topo_governance;
    use topo_framework::confidential_asset;
    use std::features;

    // The mainnet chain ID.
    const MAINNET_CHAIN_ID: u8 = 1;

    // The testnet chain ID.
    const TESTNET_CHAIN_ID: u8 = 2;

    fun main(proposal_id: u64) {
        let framework = topo_governance::resolve_multi_step_proposal(
            proposal_id,
            @0x1,
            {{ script_hash }},
        );

        let chain_id = topo_framework::chain_id::get();
        if(chain_id == MAINNET_CHAIN_ID || chain_id == TESTNET_CHAIN_ID) {
            features::change_feature_flags_for_next_epoch(&framework, vector[features::get_bulletproofs_batch_feature()], vector[]);
            confidential_asset::set_confidentiality_for_apt(&framework, true);
            topo_governance::reconfigure(&framework);
        }
    }
}
