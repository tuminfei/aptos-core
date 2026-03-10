#[test_only]
module poto_framework::poto_coin_tests {
    use poto_framework::poto_coin;
    use poto_framework::coin;
    use poto_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use poto_framework::primary_fungible_store;
    use poto_framework::object::{Self, Object};

    public fun mint_topo_fa_to_for_test<T: key>(store: Object<T>, amount: u64) {
        fungible_asset::deposit(store, poto_coin::mint_topo_fa_for_test(amount));
    }

    public fun mint_topo_fa_to_primary_fungible_store_for_test(
        owner: address,
        amount: u64,
    ) {
        primary_fungible_store::deposit(owner, poto_coin::mint_topo_fa_for_test(amount));
    }

    #[test(poto_framework = @poto_framework)]
    fun test_topo_setup_and_mint(poto_framework: &signer) {
        let (burn_cap, mint_cap) = poto_coin::initialize_for_test(poto_framework);
        let coin = coin::mint(100, &mint_cap);
        let fa = coin::coin_to_fungible_asset(coin);
        primary_fungible_store::deposit(@poto_framework, fa);
        assert!(
            primary_fungible_store::balance(
                @poto_framework,
                object::address_to_object<Metadata>(@poto_fungible_asset)
            ) == 100,
            0
        );
        coin::destroy_mint_cap(mint_cap);
        coin::destroy_burn_cap(burn_cap);
    }

    #[test]
    fun test_fa_helpers_for_test() {
        assert!(!object::object_exists<Metadata>(@poto_fungible_asset), 0);
        poto_coin::ensure_initialized_with_topo_fa_metadata_for_test();
        assert!(object::object_exists<Metadata>(@poto_fungible_asset), 0);
        mint_topo_fa_to_primary_fungible_store_for_test(@poto_framework, 100);
        let metadata = object::address_to_object<Metadata>(@poto_fungible_asset);
        assert!(primary_fungible_store::balance(@poto_framework, metadata) == 100, 0);
        let store_addr = primary_fungible_store::primary_store_address(@poto_framework, metadata);
        mint_topo_fa_to_for_test(object::address_to_object<FungibleStore>(store_addr), 100);
        assert!(primary_fungible_store::balance(@poto_framework, metadata) == 200, 0);
    }
}
