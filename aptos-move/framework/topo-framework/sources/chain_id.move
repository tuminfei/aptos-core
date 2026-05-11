/// The chain id distinguishes between different chains (e.g., testnet and the main network).
/// One important role is to prevent transactions intended for one chain from being executed on another.
/// This code provides a container for storing a chain id and functions to initialize and get it.
module topo_framework::chain_id {
    use topo_framework::system_addresses;

    friend topo_framework::genesis;

    struct ChainId has key {
        id: u8
    }

    /// Only called during genesis.
    /// Publish the chain ID `id` of this instance under the SystemAddresses address
    public(friend) fun initialize(topo_framework: &signer, id: u8) {
        system_addresses::assert_aptos_framework(topo_framework);
        move_to(topo_framework, ChainId { id })
    }

    #[view]
    /// Return the chain ID of this instance.
    public fun get(): u8 acquires ChainId {
        borrow_global<ChainId>(@topo_framework).id
    }

    #[test_only]
    use std::signer;

    #[test_only]
    public fun initialize_for_test(topo_framework: &signer, id: u8) {
        if (!exists<ChainId>(signer::address_of(topo_framework))) {
            initialize(topo_framework, id);
        }
    }

    #[test(topo_framework = @0x1)]
    fun test_get(topo_framework: &signer) acquires ChainId {
        initialize_for_test(topo_framework, 1u8);
        assert!(get() == 1u8, 1);
    }
}
