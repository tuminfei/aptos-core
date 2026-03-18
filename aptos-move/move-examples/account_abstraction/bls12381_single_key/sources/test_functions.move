module aa::test_functions {
    use aptos_framework::topo_account;

    /// test function for multi-agent aa.
    public entry fun transfer_to_the_last(a: &signer, b: &signer, c: &signer, d: address) {
        topo_account::transfer(a, d, 1);
        topo_account::transfer(b, d, 1);
        topo_account::transfer(c, d, 1);
    }
}
