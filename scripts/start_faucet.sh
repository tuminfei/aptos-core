#!/usr/bin/env bash

set -e

BIN="./aptos-faucet-service"
LOG="./aptos-faucet.log"

nohup $BIN run-simple \
  --key-file-path "/root/chain/root_key" \
  --node-url http://127.0.0.1:8080 \
  --chain-id TESTING \
  > "$LOG" 2>&1 &

echo "aptos faucet started"
echo "pid: $!"
echo "log: $LOG"
