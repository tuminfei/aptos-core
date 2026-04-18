// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{
    common::types::TransactionOptionsExt,
    governance::{utils::*, *},
};
use clap::Subcommand;

/// Tool for on-chain governance from delegation pools
///
/// This tool allows voters that have stake in a delegation pool to submit proposals or vote on
/// a proposal.
#[derive(Subcommand)]
pub enum DelegationPoolTool {
    Propose(SubmitProposal),
    Vote(SubmitVote),
}

impl DelegationPoolTool {
    pub async fn execute(self) -> CliResult {
        use DelegationPoolTool::*;
        match self {
            Propose(tool) => tool.execute_serialized().await,
            Vote(tool) => tool.execute_serialized().await,
        }
    }
}

/// Submit a governance proposal
///
/// You can only submit a proposal when the remaining lockup period of this delegation pool is
/// longer than a proposal duration and you have enough voting power to meet the minimum proposing
/// threshold. If you are voting with a delegation pool which hasn't enabled partial governance
/// voting yet, this command will enable it for you.
#[derive(Parser)]
pub struct SubmitProposal {
    /// The address of the delegation pool to propose.
    #[clap(long)]
    delegation_pool_address: AccountAddress,
    #[clap(flatten)]
    pub(crate) args: SubmitProposalArgs,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ProposalSubmissionSummary {
    proposal_id: Option<u64>,
    txn_summaries: Vec<TransactionSummary>,
}

#[async_trait]
impl CliCommand<ProposalSubmissionSummary> for SubmitProposal {
    fn command_name(&self) -> &'static str {
        "SubmitDelegationPoolProposal"
    }

    async fn execute(mut self) -> CliTypedResult<ProposalSubmissionSummary> {
        let _ = (&self.args, self.delegation_pool_address);
        Err(CliError::UnexpectedError(
            "Delegation pool governance is not supported under the current POC framework"
                .to_string(),
        ))
    }
}

/// Submit a vote on a proposal
///
/// Votes can only be given on proposals that are currently open for voting. You can vote
/// with `--yes` for a yes vote, and `--no` for a no vote. If you are voting with a delegation pool
/// which hasn't enabled partial governance voting yet, this command will enable it for you.
#[derive(Parser)]
pub struct SubmitVote {
    /// The address of the delegation pool to vote.
    #[clap(long)]
    delegation_pool_address: AccountAddress,

    #[clap(flatten)]
    pub(crate) args: SubmitVoteArgs,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for SubmitVote {
    fn command_name(&self) -> &'static str {
        "SubmitDelegationPoolVote"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let _ = (&self.args, self.delegation_pool_address);
        Err(CliError::UnexpectedError(
            "Delegation pool governance is not supported under the current POC framework"
                .to_string(),
        ))
    }
}

/// Precheck before any delegation pool governance operations. Check if feature flags are enabled.
/// Also check if partial governance voting is enabled for delegation pool. If not, send a
/// transaction to enable it.
async fn delegation_pool_governance_precheck(
    txn_options: &TransactionOptions,
    pool_address: AccountAddress,
) -> CliTypedResult<Option<TransactionSummary>> {
    let _ = (txn_options, pool_address);
    Err(CliError::UnexpectedError(
        "Delegation pool governance is not supported under the current POC framework"
            .to_string(),
    ))
}

async fn is_partial_governance_voting_enabled_for_delegation_pool(
    client: &Client,
    pool_address: AccountAddress,
) -> CliTypedResult<bool> {
    let response = client
        .view_bcs_with_json_response(
            &ViewFunction {
                module: ModuleId::new(
                    AccountAddress::ONE,
                    ident_str!("delegation_pool").to_owned(),
                ),
                function: ident_str!("partial_governance_voting_enabled").to_owned(),
                ty_args: vec![],
                args: vec![bcs::to_bytes(&pool_address).unwrap()],
            },
            None,
        )
        .await?;
    response.inner()[0].as_bool().ok_or_else(|| {
        CliError::UnexpectedError(
            "Unexpected response from node when checking if partial governance_voting is \
        enabled for delegation pool"
                .to_string(),
        )
    })
}

async fn get_remaining_voting_power(
    client: &Client,
    pool_address: AccountAddress,
    voter_address: AccountAddress,
    proposal_id: u64,
) -> CliTypedResult<u64> {
    let response = client
        .view_bcs_with_json_response(
            &ViewFunction {
                module: ModuleId::new(
                    AccountAddress::ONE,
                    ident_str!("delegation_pool").to_owned(),
                ),
                function: ident_str!("calculate_and_update_remaining_voting_power").to_owned(),
                ty_args: vec![],
                args: vec![
                    bcs::to_bytes(&pool_address).unwrap(),
                    bcs::to_bytes(&voter_address).unwrap(),
                    bcs::to_bytes(&proposal_id).unwrap(),
                ],
            },
            None,
        )
        .await?;
    let remaining_voting_power_str = response.inner()[0].as_str().ok_or_else(|| {
        CliError::UnexpectedError(format!(
            "Unexpected response from node when getting remaining voting power of {}\
        in delegation pool {}",
            pool_address, voter_address
        ))
    })?;
    remaining_voting_power_str.parse().map_err(|err| {
        CliError::UnexpectedError(format!(
            "Unexpected response from node when getting remaining voting power of {}\
        in delegation pool {}: {}",
            pool_address, voter_address, err
        ))
    })
}
