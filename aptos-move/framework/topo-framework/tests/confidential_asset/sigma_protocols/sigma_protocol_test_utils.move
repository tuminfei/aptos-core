#[test_only]
/// Shared test utilities for sigma protocol proof tests.
module topo_framework::sigma_protocol_test_utils {
    use topo_framework::account;
    use topo_framework::chain_id;
    use topo_framework::fungible_asset::{Self, Metadata};
    use topo_framework::object::Object;

    /// Creates a test signer, initializes chain_id, and creates a fungible asset.
    /// WARNING: Can only be called once per test because it calls `create_fungible_asset`!
    public fun setup_test_environment(): (signer, Object<Metadata>) {
        let sender = account::create_signer_for_test(@0x1);
        chain_id::initialize_for_test(&sender, 4);
        let (_, _, _, _, asset_type) = fungible_asset::create_fungible_asset(&sender);
        (sender, asset_type)
    }
}
