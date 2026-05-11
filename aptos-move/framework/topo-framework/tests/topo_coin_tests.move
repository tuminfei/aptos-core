#[test_only]
module topo_framework::topo_coin_tests {
    use topo_framework::topo_coin;
    use topo_framework::coin;
    use topo_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use topo_framework::primary_fungible_store;
    use topo_framework::object::{Self, Object};

    public fun mint_topo_fa_to_for_test<T: key>(store: Object<T>, amount: u64) {
        fungible_asset::deposit(store, topo_coin::mint_topo_fa_for_test(amount));
    }

    public fun mint_topo_fa_to_primary_fungible_store_for_test(
        owner: address,
        amount: u64,
    ) {
        primary_fungible_store::deposit(owner, topo_coin::mint_topo_fa_for_test(amount));
    }

    #[test(topo_framework = @topo_framework)]
    fun test_topo_setup_and_mint(topo_framework: &signer) {
        let (burn_cap, mint_cap) = topo_coin::initialize_for_test(topo_framework);
        let coin = coin::mint(100, &mint_cap);
        let fa = coin::coin_to_fungible_asset(coin);
        primary_fungible_store::deposit(@topo_framework, fa);
        assert!(
            primary_fungible_store::balance(
                @topo_framework,
                object::address_to_object<Metadata>(@aptos_fungible_asset)
            ) == 100,
            0
        );
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_fa_helpers_for_test() {
        assert!(!object::object_exists<Metadata>(@aptos_fungible_asset), 0);
        topo_coin::ensure_initialized_with_topo_fa_metadata_for_test();
        assert!(object::object_exists<Metadata>(@aptos_fungible_asset), 0);
        mint_topo_fa_to_primary_fungible_store_for_test(@topo_framework, 100);
        let metadata = object::address_to_object<Metadata>(@aptos_fungible_asset);
        assert!(primary_fungible_store::balance(@topo_framework, metadata) == 100, 0);
        let store_addr = primary_fungible_store::primary_store_address(@topo_framework, metadata);
        mint_topo_fa_to_for_test(object::address_to_object<FungibleStore>(store_addr), 100);
        assert!(primary_fungible_store::balance(@topo_framework, metadata) == 200, 0);
    }
}
