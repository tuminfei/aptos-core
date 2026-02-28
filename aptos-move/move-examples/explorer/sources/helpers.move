/// These are immutable, helper functions that are used by the Aptos Explorer
module explorer::helpers {
    use aptos_framework::delegation_pool;
    use aptos_framework::stake;
    use aptos_std::vector;

    #[view]
    public fun pool_address_info(pool_addrs: vector<address>): vector<vector<u64>> {
        let pool_infos = vector::empty<vector<u64>>();
        for (i in 0..vector::length(&pool_addrs)) {
            let pool_addr = *vector::borrow(&pool_addrs, i);
            let operator_commission_percentage = delegation_pool::operator_commission_percentage(pool_addr);
            let validator_state = stake::get_validator_state(pool_addr);
            vector::push_back(&mut pool_infos, vector[operator_commission_percentage, validator_state]);
        };
        pool_infos
    }
}