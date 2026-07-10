// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{stream_coordinator::IndexerStreamCoordinator, ServiceContext};
use aptos_indexer_grpc_utils::{filter_utils::parse_transaction_filter, timestamp_now_proto};
use aptos_logger::{error, info};
use aptos_protos::{
    indexer::v1::{
        data_service_server::DataService, ping_data_service_response::Info,
        raw_data_server::RawData, GetTransactionsRequest, LiveDataServiceInfo,
        PingDataServiceRequest, PingDataServiceResponse, StreamInfo, TransactionsResponse,
    },
    internal::fullnode::v1::transactions_from_node_response,
};
use futures::Stream;
use std::pin::Pin;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tonic::{Request, Response, Status};

// Default Values
pub const DEFAULT_NUM_RETRIES: usize = 3;
pub const RETRY_TIME_MILLIS: u64 = 100;

type TransactionResponseStream =
    Pin<Box<dyn Stream<Item = Result<TransactionsResponse, Status>> + Send>>;

#[derive(Clone)]
pub struct LocalnetDataService {
    pub service_context: ServiceContext,
}

/// Exposes a transaction stream on the node that matches the interface exposed by the
/// full production data service.
///
/// NOTE: code is duplicated from fullnode_data_service.rs with some minor changes.
#[tonic::async_trait]
impl RawData for LocalnetDataService {
    type GetTransactionsStream = TransactionResponseStream;

    async fn get_transactions(
        &self,
        req: Request<GetTransactionsRequest>,
    ) -> Result<Response<<Self as RawData>::GetTransactionsStream>, Status> {
        // Some node metadata
        let context = self.service_context.context.clone();
        let r = req.into_inner();
        let starting_version = match r.starting_version {
            Some(version) => version,
            None => match context.db.get_synced_version() {
                Ok(Some(version)) => version,
                Ok(None) => return Err(Status::unavailable("No synced version available yet")),
                Err(e) => return Err(Status::internal(format!("{e}"))),
            },
        };
        let ending_version = if let Some(count) = r.transactions_count {
            starting_version.saturating_add(count)
        } else {
            u64::MAX
        };
        let processor_task_count = self.service_context.processor_task_count;
        let processor_batch_size = self.service_context.processor_batch_size;
        let output_batch_size = self.service_context.output_batch_size;
        let transaction_channel_size = self.service_context.transaction_channel_size;
        let ledger_chain_id = context.chain_id().id();
        let transactions_count = r.transactions_count;

        // Parse transaction filter if present.
        let filter = if let Some(proto_filter) = r.transaction_filter {
            Some(parse_transaction_filter(
                proto_filter,
                self.service_context.max_transaction_filter_size_bytes,
            )?)
        } else {
            None
        };

        // Creates a channel to send the stream to the client.
        let (tx, mut rx) = mpsc::channel(transaction_channel_size);
        let (external_service_tx, external_service_rx) = mpsc::channel(transaction_channel_size);

        tokio::spawn(async move {
            // Initialize the coordinator that tracks starting version and processes transactions.
            let mut coordinator = IndexerStreamCoordinator::new(
                context,
                starting_version,
                ending_version,
                processor_task_count,
                processor_batch_size,
                output_batch_size,
                tx.clone(),
                filter,
                None,
            );
            while coordinator.current_version < coordinator.end_version {
                // Processes and sends batch of transactions to client
                let results = coordinator.process_next_batch().await;
                if results.is_empty() {
                    info!(
                        start_version = starting_version,
                        chain_id = ledger_chain_id,
                        "[Indexer Fullnode] Client disconnected."
                    );
                    break;
                }
                let max_version = match IndexerStreamCoordinator::get_max_batch_version(results) {
                    Ok(max_version) => max_version,
                    Err(e) => {
                        error!("[indexer-grpc] Error sending to stream: {}", e);
                        break;
                    },
                };
                coordinator.current_version = max_version + 1;
            }
        });
        tokio::spawn(async move {
            let mut response_transactions_count = transactions_count;
            while let Some(response) = rx.recv().await {
                if let Some(count) = response_transactions_count.as_ref() {
                    if *count == 0 {
                        break;
                    }
                }

                let response = response.map(|t| TransactionsResponse {
                    chain_id: Some(ledger_chain_id as u64),
                    transactions: match t.response.expect("Response must be set") {
                        transactions_from_node_response::Response::Data(transaction_output) => {
                            let mut transactions = transaction_output.transactions;
                            let current_transactions_count = transactions.len() as u64;
                            if let Some(count) = response_transactions_count.as_mut() {
                                transactions =
                                    transactions.into_iter().take(*count as usize).collect();
                                *count = count.saturating_sub(current_transactions_count);
                            }
                            transactions
                        },
                        _ => panic!("Unexpected response type."),
                    },
                    processed_range: None,
                });
                match external_service_tx.send(response).await {
                    Ok(_) => {},
                    Err(e) => {
                        aptos_logger::warn!(
                            "[indexer-grpc] Unable to send end batch status: {:?}",
                            e
                        );
                        break;
                    },
                }
            }
        });

        let output_stream = ReceiverStream::new(external_service_rx);
        Ok(Response::new(
            Box::pin(output_stream) as Self::GetTransactionsStream
        ))
    }
}

#[tonic::async_trait]
impl DataService for LocalnetDataService {
    type GetTransactionsStream = TransactionResponseStream;

    async fn get_transactions(
        &self,
        req: Request<GetTransactionsRequest>,
    ) -> Result<Response<<Self as DataService>::GetTransactionsStream>, Status> {
        RawData::get_transactions(self, req).await
    }

    async fn ping(
        &self,
        req: Request<PingDataServiceRequest>,
    ) -> Result<Response<PingDataServiceResponse>, Status> {
        if !req.get_ref().ping_live_data_service {
            return Err(Status::invalid_argument(
                "This endpoint only serves live data service pings.",
            ));
        }

        let context = self.service_context.context.clone();
        let known_latest_version = context
            .db
            .get_synced_version()
            .map_err(|e| Status::internal(format!("{e}")))?
            .ok_or_else(|| Status::unavailable("No synced version available yet"))?;
        if known_latest_version == 0 {
            return Err(Status::unavailable(
                "No non-genesis transaction version available yet",
            ));
        }

        let min_servable_version = context
            .db
            .get_first_txn_version()
            .map_err(|e| Status::internal(format!("{e}")))?
            .unwrap_or(0);
        if min_servable_version > known_latest_version {
            return Err(Status::unavailable(format!(
                "Minimum servable version {min_servable_version} is greater than known latest version {known_latest_version}"
            )));
        }

        let stream_info = Some(StreamInfo {
            active_streams: Vec::new(),
        });
        let info = Info::LiveDataServiceInfo(LiveDataServiceInfo {
            chain_id: context.chain_id().id() as u64,
            timestamp: Some(timestamp_now_proto()),
            known_latest_version: Some(known_latest_version),
            stream_info,
            min_servable_version: Some(min_servable_version),
        });

        Ok(Response::new(PingDataServiceResponse { info: Some(info) }))
    }
}
