// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{
    common::{
        types::{
            CliCommand, CliError, CliResult, CliTypedResult, TransactionOptions,
            TransactionOptionsExt, TransactionSummary,
        },
        utils::prompt_yes_with_override,
    },
    node::{get_stake_pools, StakePoolType},
};
use aptos_cached_packages::topo_stdlib;
use aptos_types::{
    account_address::AccountAddress,
};
use async_trait::async_trait;
use clap::Parser;

fn unsupported_pool_type(pool_type: StakePoolType, action: &str) -> CliError {
    CliError::UnexpectedError(format!(
        "{} is not supported for {:?} pools under the current POC/stake framework",
        action, pool_type
    ))
}

/// Tool for manipulating stake and stake pools
///
#[derive(Parser)]
pub enum StakeTool {
    AddStake(AddStake),
    CreateStakingContract(CreateStakingContract),
    DistributeVestedCoins(DistributeVestedCoins),
    IncreaseLockup(IncreaseLockup),
    InitializeStakeOwner(InitializeStakeOwner),
    RequestCommission(RequestCommission),
    SetDelegatedVoter(SetDelegatedVoter),
    SetOperator(SetOperator),
    UnlockStake(UnlockStake),
    UnlockVestedCoins(UnlockVestedCoins),
    WithdrawStake(WithdrawStake),
}

impl StakeTool {
    pub async fn execute(self) -> CliResult {
        use StakeTool::*;
        match self {
            AddStake(tool) => tool.execute_serialized().await,
            CreateStakingContract(tool) => tool.execute_serialized().await,
            DistributeVestedCoins(tool) => tool.execute_serialized().await,
            IncreaseLockup(tool) => tool.execute_serialized().await,
            InitializeStakeOwner(tool) => tool.execute_serialized().await,
            RequestCommission(tool) => tool.execute_serialized().await,
            SetDelegatedVoter(tool) => tool.execute_serialized().await,
            SetOperator(tool) => tool.execute_serialized().await,
            UnlockStake(tool) => tool.execute_serialized().await,
            UnlockVestedCoins(tool) => tool.execute_serialized().await,
            WithdrawStake(tool) => tool.execute_serialized().await,
        }
    }
}

/// Add APT to a stake pool
///
/// This command allows stake pool owners to add APT to their stake.
#[derive(Parser)]
pub struct AddStake {
    /// Amount of Octas (10^-8 APT) to add to stake
    #[clap(long)]
    pub amount: u64,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for AddStake {
    fn command_name(&self) -> &'static str {
        "AddStake"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let client = self
            .txn_options
            .rest_options
            .client(&self.txn_options.profile_options)?;
        let amount = self.amount;
        let owner_address = self.txn_options.sender_address()?;
        let mut transaction_summaries: Vec<TransactionSummary> = vec![];

        let stake_pool_results = get_stake_pools(&client, owner_address).await?;
        for stake_pool in stake_pool_results {
            match stake_pool.pool_type {
                StakePoolType::Direct => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Adding stake via CLI",
                    ));
                },
                StakePoolType::StakingContract => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Adding stake via CLI",
                    ));
                },
                StakePoolType::Vesting => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Adding stake via CLI",
                    ))
                },
            }
        }
        Ok(transaction_summaries)
    }
}

/// Unlock staked APT in a stake pool
///
/// APT coins can only be unlocked if they no longer have an applied lockup period
#[derive(Parser)]
pub struct UnlockStake {
    /// Amount of Octas (10^-8 APT) to unlock
    #[clap(long)]
    pub amount: u64,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for UnlockStake {
    fn command_name(&self) -> &'static str {
        "UnlockStake"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let client = self
            .txn_options
            .rest_options
            .client(&self.txn_options.profile_options)?;
        let amount = self.amount;
        let owner_address = self.txn_options.sender_address()?;
        let mut transaction_summaries: Vec<TransactionSummary> = vec![];

        let stake_pool_results = get_stake_pools(&client, owner_address).await?;
        for stake_pool in stake_pool_results {
            match stake_pool.pool_type {
                StakePoolType::Direct => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Unlocking stake via CLI",
                    ));
                },
                StakePoolType::StakingContract => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Unlocking stake via CLI",
                    ));
                },
                StakePoolType::Vesting => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Unlocking stake via CLI",
                    ))
                },
            }
        }
        Ok(transaction_summaries)
    }
}

/// Withdraw unlocked staked APT from a stake pool
///
/// This allows users to withdraw stake back into their CoinStore.
/// Before calling `WithdrawStake`, `UnlockStake` must be called first.
#[derive(Parser)]
pub struct WithdrawStake {
    /// Amount of Octas (10^-8 APT) to withdraw.
    /// This only applies to stake pools owned directly by the owner account, instead of via
    /// a staking contract. In the latter case, when withdrawal is issued, all coins are distributed
    #[clap(long)]
    pub amount: u64,

    #[clap(flatten)]
    pub(crate) node_op_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for WithdrawStake {
    fn command_name(&self) -> &'static str {
        "WithdrawStake"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let client = self
            .node_op_options
            .rest_options
            .client(&self.node_op_options.profile_options)?;
        let amount = self.amount;
        let owner_address = self.node_op_options.sender_address()?;
        let mut transaction_summaries: Vec<TransactionSummary> = vec![];

        let stake_pool_results = get_stake_pools(&client, owner_address).await?;
        for stake_pool in stake_pool_results {
            match stake_pool.pool_type {
                StakePoolType::Direct => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Withdrawing stake via CLI",
                    ));
                },
                StakePoolType::StakingContract => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Withdrawing stake via CLI",
                    ));
                },
                StakePoolType::Vesting => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Withdrawing stake via CLI",
                    ))
                },
            }
        }
        Ok(transaction_summaries)
    }
}

/// Increase lockup of all staked APT in a stake pool
///
/// Lockup may need to be increased in order to vote on a proposal.
#[derive(Parser)]
pub struct IncreaseLockup {
    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for IncreaseLockup {
    fn command_name(&self) -> &'static str {
        "IncreaseLockup"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let client = self
            .txn_options
            .rest_options
            .client(&self.txn_options.profile_options)?;
        let owner_address = self.txn_options.sender_address()?;
        let mut transaction_summaries: Vec<TransactionSummary> = vec![];

        let stake_pool_results = get_stake_pools(&client, owner_address).await?;
        for stake_pool in stake_pool_results {
            match stake_pool.pool_type {
                StakePoolType::Direct => {
                    transaction_summaries.push(
                        self.txn_options
                            .submit_transaction(topo_stdlib::stake_increase_lockup())
                            .await
                            .map(|inner| inner.into())?,
                    );
                },
                StakePoolType::StakingContract => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Increasing lockup via CLI",
                    ));
                },
                StakePoolType::Vesting => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Increasing lockup via CLI",
                    ));
                },
            }
        }
        Ok(transaction_summaries)
    }
}

/// Initialize a stake pool owner
///
/// Initializing stake owner adds the capability to delegate the
/// stake pool to an operator, or delegate voting to a different account.
#[derive(Parser)]
pub struct InitializeStakeOwner {
    /// Initial amount of Octas (10^-8 APT) to be staked
    #[clap(long)]
    pub initial_stake_amount: u64,

    /// Account Address of delegated operator
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub operator_address: Option<AccountAddress>,

    /// Account address of delegated voter
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub voter_address: Option<AccountAddress>,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<TransactionSummary> for InitializeStakeOwner {
    fn command_name(&self) -> &'static str {
        "InitializeStakeOwner"
    }

    async fn execute(mut self) -> CliTypedResult<TransactionSummary> {
        let owner_address = self.txn_options.sender_address()?;
        self.txn_options
            .submit_transaction(topo_stdlib::stake_initialize_stake_owner(
                self.initial_stake_amount,
                self.operator_address.unwrap_or(owner_address),
            ))
            .await
            .map(|inner| inner.into())
    }
}

/// Delegate operator capability to another account
///
/// This changes the operator capability from its current operator to a different operator.
/// By default, the operator of a stake pool is the owner of the stake pool
#[derive(Parser)]
pub struct SetOperator {
    /// Account Address of delegated operator
    ///
    /// If not specified, it will be the same as the owner
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub operator_address: AccountAddress,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for SetOperator {
    fn command_name(&self) -> &'static str {
        "SetOperator"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let client = self
            .txn_options
            .rest_options
            .client(&self.txn_options.profile_options)?;
        let owner_address = self.txn_options.sender_address()?;
        let new_operator_address = self.operator_address;
        let mut transaction_summaries: Vec<TransactionSummary> = vec![];

        let stake_pool_results = get_stake_pools(&client, owner_address).await?;
        for stake_pool in stake_pool_results {
            match stake_pool.pool_type {
                StakePoolType::Direct => {
                    transaction_summaries.push(
                        self.txn_options
                            .submit_transaction(topo_stdlib::stake_set_operator(
                                new_operator_address,
                            ))
                            .await
                            .map(|inner| inner.into())?,
                    );
                },
                StakePoolType::StakingContract => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Setting operator via CLI",
                    ));
                },
                StakePoolType::Vesting => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Setting operator via CLI",
                    ));
                },
            }
        }
        Ok(transaction_summaries)
    }
}

/// Delegate voting capability to another account
///
/// Delegates voting capability from its current voter to a different voter.
/// By default, the voter of a stake pool is the owner of the stake pool
#[derive(Parser)]
pub struct SetDelegatedVoter {
    /// Account Address of delegated voter
    ///
    /// If not specified, it will be the same as the owner
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub voter_address: AccountAddress,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<Vec<TransactionSummary>> for SetDelegatedVoter {
    fn command_name(&self) -> &'static str {
        "SetDelegatedVoter"
    }

    async fn execute(mut self) -> CliTypedResult<Vec<TransactionSummary>> {
        let client = self
            .txn_options
            .rest_options
            .client(&self.txn_options.profile_options)?;
        let owner_address = self.txn_options.sender_address()?;
        let new_voter_address = self.voter_address;
        let mut transaction_summaries: Vec<TransactionSummary> = vec![];

        let stake_pool_results = get_stake_pools(&client, owner_address).await?;
        for stake_pool in stake_pool_results {
            match stake_pool.pool_type {
                StakePoolType::Direct => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Setting delegated voter via CLI",
                    ));
                },
                StakePoolType::StakingContract => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Setting delegated voter via CLI",
                    ));
                },
                StakePoolType::Vesting => {
                    return Err(unsupported_pool_type(
                        stake_pool.pool_type,
                        "Setting delegated voter via CLI",
                    ));
                },
            }
        }
        Ok(transaction_summaries)
    }
}

/// Create a staking contract stake pool
///
///
#[derive(Parser)]
pub struct CreateStakingContract {
    /// Account Address of operator
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub operator: AccountAddress,

    /// Account Address of delegated voter
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub voter: AccountAddress,

    /// Amount to create the staking contract with
    #[clap(long)]
    pub amount: u64,

    /// Percentage of accumulated rewards to pay the operator as commission
    #[clap(long)]
    pub commission_percentage: u64,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<TransactionSummary> for CreateStakingContract {
    fn command_name(&self) -> &'static str {
        "CreateStakingContract"
    }

    async fn execute(mut self) -> CliTypedResult<TransactionSummary> {
        let _ = (
            self.operator,
            self.voter,
            self.amount,
            self.commission_percentage,
        );
        Err(CliError::UnexpectedError(
            "Creating staking contracts is not supported under the current POC/stake framework"
                .to_string(),
        ))
    }
}

/// Distribute fully unlocked coins from vesting
///
/// Distribute fully unlocked coins (rewards and/or vested coins) from the vesting contract
/// to shareholders.
#[derive(Parser)]
pub struct DistributeVestedCoins {
    /// Address of the vesting contract's admin.
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub admin_address: AccountAddress,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<TransactionSummary> for DistributeVestedCoins {
    fn command_name(&self) -> &'static str {
        "DistributeVestedCoins"
    }

    async fn execute(mut self) -> CliTypedResult<TransactionSummary> {
        let _ = self.admin_address;
        Err(CliError::UnexpectedError(
            "Distributing vested coins is not supported under the current POC/stake framework"
                .to_string(),
        ))
    }
}

/// Unlock vested coins
///
/// Unlock vested coins according to the vesting contract's schedule.
/// This also unlocks any accumulated staking rewards and pays commission to the operator of the
/// vesting contract's stake pool first.
///
/// The unlocked vested tokens and staking rewards are still subject to the staking lockup and
/// cannot be withdrawn until after the lockup expires.
#[derive(Parser)]
pub struct UnlockVestedCoins {
    /// Address of the vesting contract's admin.
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub admin_address: AccountAddress,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<TransactionSummary> for UnlockVestedCoins {
    fn command_name(&self) -> &'static str {
        "UnlockVestedCoins"
    }

    async fn execute(mut self) -> CliTypedResult<TransactionSummary> {
        let _ = self.admin_address;
        Err(CliError::UnexpectedError(
            "Unlocking vested coins is not supported under the current POC/stake framework"
                .to_string(),
        ))
    }
}

/// Request commission from running a stake pool
///
/// Allows operators or owners to request commission from running a stake pool (only if there's a
/// staking contract set up with the staker).  The commission will be withdrawable at the end of the
/// stake pool's current lockup period.
#[derive(Parser)]
pub struct RequestCommission {
    /// Address of the owner of the stake pool
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub owner_address: AccountAddress,

    /// Address of the operator of the stake pool
    #[clap(long, value_parser = crate::common::types::load_account_arg)]
    pub operator_address: AccountAddress,

    #[clap(flatten)]
    pub(crate) txn_options: TransactionOptions,
}

#[async_trait]
impl CliCommand<TransactionSummary> for RequestCommission {
    fn command_name(&self) -> &'static str {
        "RequestCommission"
    }

    async fn execute(mut self) -> CliTypedResult<TransactionSummary> {
        let _ = (self.owner_address, self.operator_address);
        Err(CliError::UnexpectedError(
            "Requesting commission is not supported under the current POC/stake framework"
                .to_string(),
        ))
    }
}
