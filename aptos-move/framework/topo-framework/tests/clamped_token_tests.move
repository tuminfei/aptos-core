#[test_only]
module topo_framework::clamped_token_tests {
    use topo_framework::fungible_asset::{Self, Metadata, TestToken};
    use topo_framework::dispatchable_fungible_asset;
    use topo_framework::clamped_token;
    use std::features;
    use std::option;

    #[test(creator = @topo_framework)]
    fun test_clamped(
        creator: &signer,
    ) {
        features::change_feature_flags_for_testing(creator, vector[features::get_function_value_dispatch_feature()], vector[]);
        let (creator_ref, token_object) = fungible_asset::create_test_token(creator);
        let (mint, _, _, _) = fungible_asset::init_test_metadata(&creator_ref);
        let metadata = token_object.convert<TestToken, Metadata>();

        let creator_store = fungible_asset::create_test_store(creator, metadata);

        clamped_token::initialize(creator, &creator_ref);

        assert!(dispatchable_fungible_asset::derived_supply(metadata) == option::some(0), 2);
        // Mint
        let fa = mint.mint(100);
        dispatchable_fungible_asset::deposit(creator_store, fa);

        assert!(dispatchable_fungible_asset::derived_balance(creator_store) == 100, 4);
        assert!(dispatchable_fungible_asset::derived_supply(metadata) == option::some(100), 5);

        let fa = dispatchable_fungible_asset::withdraw(creator, creator_store, 5);
        dispatchable_fungible_asset::deposit(creator_store, fa);
    }

    #[test(creator = @topo_framework)]
    #[expected_failure(abort_code = 0, location = topo_framework::clamped_token)]
    fun test_clamped_aborted(
        creator: &signer,
    ) {
        features::change_feature_flags_for_testing(creator, vector[features::get_function_value_dispatch_feature()], vector[]);
        let (creator_ref, token_object) = fungible_asset::create_test_token(creator);
        let (mint, _, _, _) = fungible_asset::init_test_metadata(&creator_ref);
        let metadata = token_object.convert<TestToken, Metadata>();

        let creator_store = fungible_asset::create_test_store(creator, metadata);

        clamped_token::initialize(creator, &creator_ref);

        assert!(dispatchable_fungible_asset::derived_supply(metadata) == option::some(0), 2);
        // Mint
        let fa = mint.mint(100);
        dispatchable_fungible_asset::deposit(creator_store, fa);

        // Failed to withdraw as it exceeds the withdraw limit.
        let fa = dispatchable_fungible_asset::withdraw(creator, creator_store, 20);
        dispatchable_fungible_asset::deposit(creator_store, fa);
    }
}
