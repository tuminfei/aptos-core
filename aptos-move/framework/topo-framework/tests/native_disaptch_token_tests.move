#[test_only]
module topo_framework::native_dispatch_token_tests {
    use topo_framework::fungible_asset;
    use topo_framework::native_dispatch_token;

    #[test(creator = @topo_framework)]
    #[expected_failure(abort_code=0x10019, location=topo_framework::fungible_asset)]
    fun test_native_dispatch_token(
        creator: &signer,
    ) {
        let (creator_ref, _) = fungible_asset::create_test_token(creator);
        fungible_asset::init_test_metadata(&creator_ref);

        native_dispatch_token::initialize(creator, &creator_ref);
    }
}
