script {
    use topo_framework::topo_governance;
    use topo_framework::coin;
    use topo_framework::topo_coin::TopoCoin;
    use topo_framework::staking_config;

    fun main(proposal_id: u64) {
        let framework_signer = topo_governance::resolve(proposal_id, @topo_framework);
        let one_topo_coin_with_decimals = 10 ** (coin::decimals<TopoCoin>() as u64);
        // Change min to 1000 and max to 1M Aptos coins.
        let new_min_stake = 1000 * one_topo_coin_with_decimals;
        let new_max_stake = 1000000 * one_topo_coin_with_decimals;
        staking_config::update_required_stake(&framework_signer, new_min_stake, new_max_stake);
    }
}
