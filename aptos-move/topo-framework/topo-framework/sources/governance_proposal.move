/// Define the GovernanceProposal that will be used as part of on-chain governance by PotoGovernance.
///
/// This is separate from the PotoGovernance module to avoid circular dependency between PotoGovernance and Stake.
module poto_framework::governance_proposal {
    friend poto_framework::poto_governance;

    struct GovernanceProposal has store, drop {}

    /// Create and return a GovernanceProposal resource. Can only be called by PotoGovernance
    public(friend) fun create_proposal(): GovernanceProposal {
        GovernanceProposal {}
    }

    /// Useful for PotoGovernance to create an empty proposal as proof.
    public(friend) fun create_empty_proposal(): GovernanceProposal {
        create_proposal()
    }

    #[test_only]
    public fun create_test_proposal(): GovernanceProposal {
        create_empty_proposal()
    }
}
