/// Provides a common place for exporting `create_signer` across the Aptos Framework.
///
/// To use create_signer, add the module below, such that:
/// `friend topo_framework::friend_wants_create_signer`
/// where `friend_wants_create_signer` is the module that needs `create_signer`.
///
/// Note, that this is only available within the Aptos Framework.
///
/// This exists to make auditing straight forward and to limit the need to depend
/// on account to have access to this.
module topo_framework::create_signer {
    friend topo_framework::account;
    friend topo_framework::topo_account;
    friend topo_framework::coin;
    friend topo_framework::fungible_asset;
    friend topo_framework::genesis;
    friend topo_framework::account_abstraction;
    friend topo_framework::multisig_account;
    friend topo_framework::object;
    friend topo_framework::permissioned_signer;
    friend topo_framework::transaction_validation;

    public(friend) native fun create_signer(addr: address): signer;
}
