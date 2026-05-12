// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use super::Test;
use crate::{CoreContext, Result, TestReport};
use anyhow::anyhow;
use aptos_cached_packages::topo_stdlib;
use aptos_logger::info;
use aptos_rest_client::{Client as RestClient, PendingTransaction, State, Transaction};
use aptos_sdk::{
    crypto::ed25519::Ed25519PublicKey,
    transaction_builder::TransactionFactory,
    types::{
        account_address::AccountAddress,
        account_config::CORE_CODE_ADDRESS,
        chain_id::ChainId,
        transaction::{
            authenticator::{AnyPublicKey, AuthenticationKey},
            SignedTransaction,
        },
        LocalAccount,
    },
};
use rand::{rngs::OsRng, Rng, SeedableRng};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const TEST_TRANSACTION_EXPIRATION_SECS: u64 = 120;
const TEST_TRANSACTION_RETRY_ATTEMPTS: usize = 3;
const TEST_TRANSACTION_RETRY_DELAY: Duration = Duration::from_secs(1);
const DEFINITIVE_TRANSACTION_EXPIRED_ERROR: &str =
    "Transaction expired. It is guaranteed it will not be committed on chain.";

#[async_trait::async_trait]
pub trait AptosTest: Test {
    /// Executes the test against the given context.
    async fn run<'t>(&self, ctx: &mut AptosContext<'t>) -> Result<()>;
}

pub struct AptosContext<'t> {
    core: CoreContext,
    public_info: AptosPublicInfo,
    pub report: &'t mut TestReport,
}

impl<'t> AptosContext<'t> {
    pub fn new(
        core: CoreContext,
        public_info: AptosPublicInfo,
        report: &'t mut TestReport,
    ) -> Self {
        Self {
            core,
            public_info,
            report,
        }
    }

    pub fn client(&self) -> RestClient {
        RestClient::new(self.public_info.rest_api_url.clone())
    }

    pub fn url(&self) -> &str {
        self.public_info.rest_api_url.as_str()
    }

    pub fn core(&self) -> &CoreContext {
        &self.core
    }

    pub fn rng(&mut self) -> &mut ::rand::rngs::StdRng {
        self.core.rng()
    }

    pub fn random_account(&mut self) -> LocalAccount {
        LocalAccount::generate(self.core.rng())
    }

    pub fn chain_id(&self) -> ChainId {
        self.public_info.chain_id
    }

    pub fn transaction_factory(&self) -> TransactionFactory {
        let unit_price = std::cmp::max(aptos_global_constants::GAS_UNIT_PRICE, 1);
        TransactionFactory::new(self.chain_id()).with_gas_unit_price(unit_price)
    }

    pub fn aptos_transaction_factory(&self) -> TransactionFactory {
        self.public_info.transaction_factory()
    }

    pub async fn create_user_account(&mut self, pubkey: &Ed25519PublicKey) -> Result<()> {
        self.public_info.create_user_account(pubkey).await
    }

    pub async fn mint(&mut self, addr: AccountAddress, amount: u64) -> Result<()> {
        self.public_info.mint(addr, amount).await
    }

    pub async fn transfer(
        &self,
        from_account: &mut LocalAccount,
        to_account: &LocalAccount,
        amount: u64,
    ) -> Result<PendingTransaction> {
        self.public_info
            .transfer(from_account, to_account, amount)
            .await
    }

    pub async fn get_balance(&self, address: AccountAddress) -> u64 {
        self.public_info.get_balance(address).await
    }

    pub fn root_account(&mut self) -> Arc<LocalAccount> {
        self.public_info.root_account.clone()
    }
}

#[derive(Clone)]
pub struct AptosPublicInfo {
    chain_id: ChainId,
    inspection_service_url: Url,
    rest_api_url: Url,
    rest_client: RestClient,
    root_account: Arc<LocalAccount>,
    rng: ::rand::rngs::StdRng,
}

impl AptosPublicInfo {
    pub fn new(
        chain_id: ChainId,
        inspection_service_url_str: String,
        rest_api_url_str: String,
        root_account: Arc<LocalAccount>,
    ) -> Self {
        let rest_api_url = Url::parse(&rest_api_url_str).unwrap();
        let inspection_service_url = Url::parse(&inspection_service_url_str).unwrap();
        Self {
            inspection_service_url,
            rest_client: RestClient::new(rest_api_url.clone()),
            rest_api_url,
            chain_id,
            root_account,
            rng: ::rand::rngs::StdRng::from_seed(OsRng.r#gen()),
        }
    }

    pub fn client(&self) -> &RestClient {
        &self.rest_client
    }

    pub fn url(&self) -> &str {
        self.rest_api_url.as_str()
    }

    pub fn inspection_service_url(&self) -> &str {
        self.inspection_service_url.as_str()
    }

    pub fn root_account(&mut self) -> Arc<LocalAccount> {
        self.root_account.clone()
    }

    pub async fn create_user_account(&mut self, pubkey: &Ed25519PublicKey) -> Result<()> {
        let auth_key = AuthenticationKey::ed25519(pubkey);
        let create_account_txn =
            self.root_account
                .sign_with_transaction_builder(self.transaction_factory().payload(
                    topo_stdlib::topo_account_create_account(auth_key.account_address()),
                ));
        self.rest_client
            .submit_and_wait(&create_account_txn)
            .await?;
        Ok(())
    }

    pub async fn create_user_account_with_any_key(
        &mut self,
        pubkey: &AnyPublicKey,
    ) -> Result<AccountAddress> {
        let auth_key = AuthenticationKey::any_key(pubkey.clone());
        let create_account_txn =
            self.root_account
                .sign_with_transaction_builder(self.transaction_factory().payload(
                    topo_stdlib::topo_account_create_account(auth_key.account_address()),
                ));
        self.rest_client
            .submit_and_wait(&create_account_txn)
            .await?;
        Ok(auth_key.account_address())
    }

    pub async fn mint(&mut self, addr: AccountAddress, amount: u64) -> Result<()> {
        let mint_txn = self.root_account.sign_with_transaction_builder(
            self.transaction_factory()
                .payload(topo_stdlib::topo_coin_mint(addr, amount)),
        );
        self.rest_client.submit_and_wait(&mint_txn).await?;
        Ok(())
    }

    pub async fn transfer_non_blocking(
        &self,
        from_account: &mut LocalAccount,
        to_account: &LocalAccount,
        amount: u64,
    ) -> Result<PendingTransaction> {
        let tx = sign_transfer_transaction(
            &self.transaction_factory(),
            from_account,
            to_account,
            amount,
        );
        let pending_txn = self.rest_client.submit(&tx).await?.into_inner();
        Ok(pending_txn)
    }

    pub async fn transfer(
        &self,
        from_account: &mut LocalAccount,
        to_account: &LocalAccount,
        amount: u64,
    ) -> Result<PendingTransaction> {
        let mut last_error = None;
        for _attempt in 1..=TEST_TRANSACTION_RETRY_ATTEMPTS {
            let sequence_number_before_signing = from_account.sequence_number();
            let pending_txn = self
                .transfer_non_blocking(from_account, to_account, amount)
                .await?;
            match self.rest_client.wait_for_transaction(&pending_txn).await {
                Ok(_) => return Ok(pending_txn),
                Err(error) if is_definitively_expired_transaction_error(&error.to_string()) => {
                    from_account.set_sequence_number(sequence_number_before_signing);
                    last_error = Some(error);
                    tokio::time::sleep(TEST_TRANSACTION_RETRY_DELAY).await;
                },
                Err(error) => return Err(error.into()),
            }
        }

        Err(anyhow!(
            "transfer transaction expired after {} attempts: {:?}",
            TEST_TRANSACTION_RETRY_ATTEMPTS,
            last_error
        ))
    }

    pub fn transaction_factory(&self) -> TransactionFactory {
        let unit_price = std::cmp::max(aptos_global_constants::GAS_UNIT_PRICE, 1);
        TransactionFactory::new(self.chain_id)
            .with_gas_unit_price(unit_price)
            .with_absolute_transaction_expiration_timestamp(
                test_transaction_expiration_timestamp_secs(),
            )
    }

    pub async fn get_approved_execution_hash_at_topo_governance(
        &self,
        proposal_id: u64,
    ) -> Vec<u8> {
        let approved_execution_hashes = self
            .rest_client
            .get_account_resource_bcs::<SimpleMap<u64, Vec<u8>>>(
                CORE_CODE_ADDRESS,
                "0x1::topo_governance::ApprovedExecutionHashes",
            )
            .await;
        let hashes = approved_execution_hashes.unwrap().into_inner().data;
        let mut execution_hash = vec![];
        for hash in hashes {
            if hash.key == proposal_id {
                execution_hash = hash.value;
                break;
            }
        }
        execution_hash
    }

    pub async fn get_balance(&self, address: AccountAddress) -> u64 {
        self.rest_client
            .get_account_balance(address, "0x1::topo_coin::TopoCoin")
            .await
            .unwrap()
            .into_inner()
    }

    pub async fn account_exists(&self, address: AccountAddress) -> Result<()> {
        self.rest_client
            .get_account_resources(address)
            .await
            .is_ok()
            .then_some(())
            .ok_or_else(|| anyhow!("Account does not exist"))
    }

    pub async fn get_account_sequence_number(&mut self, address: AccountAddress) -> Result<u64> {
        self.account_exists(address).await?;

        Ok(self
            .client()
            .get_account_bcs(address)
            .await
            .unwrap()
            .into_inner()
            .sequence_number())
    }

    pub fn random_account(&mut self) -> LocalAccount {
        LocalAccount::generate(&mut self.rng)
    }

    pub async fn create_and_fund_user_account(&mut self, amount: u64) -> Result<LocalAccount> {
        let account = self.random_account();
        self.create_user_account(account.public_key()).await?;
        self.mint(account.address(), amount).await?;
        Ok(account)
    }

    pub async fn reconfig(&self) -> State {
        // dedupe with smoke-test::test_utils::reconfig
        reconfig(
            &self.rest_client,
            &self.transaction_factory(),
            self.root_account.clone(),
        )
        .await
    }

    /// Syncs the root account to it's sequence number in the event that a faucet changed it's value
    pub async fn sync_root_account_sequence_number(&mut self) {
        let root_address = self.root_account().address();
        let root_sequence_number = self
            .client()
            .get_account_bcs(root_address)
            .await
            .unwrap()
            .into_inner()
            .sequence_number();
        self.root_account()
            .set_sequence_number(root_sequence_number);
    }
}

pub async fn reconfig(
    client: &RestClient,
    transaction_factory: &TransactionFactory,
    root_account: Arc<LocalAccount>,
) -> State {
    let txns = {
        vec![root_account.sign_with_transaction_builder(
            transaction_factory
                .clone()
                .payload(topo_stdlib::topo_governance_force_end_epoch_test_only()),
        )]
    };

    submit_and_wait_reconfig(client, txns).await
}

pub async fn submit_and_wait_reconfig(
    client: &RestClient,
    mut txns: Vec<SignedTransaction>,
) -> State {
    let state = client.get_ledger_information().await.unwrap().into_inner();
    let last_txn = txns.pop().unwrap();
    for txn in txns {
        let _ = client.submit(&txn).await;
    }
    let result = client.submit_and_wait(&last_txn).await;
    if let Err(e) = result {
        let last_transactions = client
            .get_account_ordered_transactions(last_txn.sender(), None, None)
            .await
            .map(|result| {
                result
                    .into_inner()
                    .iter()
                    .map(|t| {
                        if let Transaction::UserTransaction(ut) = t {
                            format!(
                                "user seq={}, payload={:?}",
                                ut.request.sequence_number, ut.request.payload
                            )
                        } else {
                            t.type_str().to_string()
                        }
                    })
                    .collect::<Vec<_>>()
            });

        panic!(
            "Couldn't execute {:?}, for account {:?}, error {:?}, last account transactions: {:?}",
            last_txn,
            last_txn.sender(),
            e,
            last_transactions.unwrap_or_default()
        )
    }

    let transaction = result.unwrap();
    // Next transaction after reconfig should be a new epoch.
    let new_state = client
        .wait_for_version(transaction.inner().version().unwrap() + 1)
        .await
        .unwrap();

    info!(
        "Applied reconfig from (epoch={}, ledger_v={}), to (epoch={}, ledger_v={})",
        state.epoch, state.version, new_state.epoch, new_state.version
    );
    assert_ne!(state.epoch, new_state.epoch);

    new_state
}

#[derive(Serialize, Deserialize)]
struct SimpleMap<K, V> {
    data: Vec<Element<K, V>>,
}

#[derive(Serialize, Deserialize)]
struct Element<K, V> {
    key: K,
    value: V,
}

fn sign_transfer_transaction(
    transaction_factory: &TransactionFactory,
    from_account: &LocalAccount,
    to_account: &LocalAccount,
    amount: u64,
) -> SignedTransaction {
    from_account.sign_with_transaction_builder(
        transaction_factory
            .payload(topo_stdlib::topo_coin_transfer(
                to_account.address(),
                amount,
            ))
            .expiration_timestamp_secs(test_transaction_expiration_timestamp_secs()),
    )
}

fn test_transaction_expiration_timestamp_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + TEST_TRANSACTION_EXPIRATION_SECS
}

fn is_definitively_expired_transaction_error(error: &str) -> bool {
    error.contains(DEFINITIVE_TRANSACTION_EXPIRED_ERROR)
}
