#!/bin/bash

CHAIN_DIR="/root/chain"
APTOS_NODE_BIN="$(dirname "$(realpath "$0")")/../target/release/aptos-node"

# check aptos-node
if [ ! -f "$APTOS_NODE_BIN" ]; then
    echo "Error: Could not find aptos-node binary at $APTOS_NODE_BIN"
    echo "Please compile the binary first: cd $(dirname "$(realpath "$0")")/.. && cargo build --release"
    exit 1
fi

# check CHAIN_DIR
if [ ! -d "$CHAIN_DIR" ]; then
    echo "Error: Chain directory $CHAIN_DIR does not exist"
    echo "Please run forge to create the chain first"
    exit 1
fi

echo "Using aptos-node binary: $APTOS_NODE_BIN"
echo "Using chain directory: $CHAIN_DIR"

# start nodes
for i in $(ls -d "$CHAIN_DIR"/*/ 2>/dev/null | grep -E "[0-9]+/$" | sort -n); do
    i=$(basename "$i")
    NODE_DIR="$CHAIN_DIR/$i"
    CONFIG_FILE="$NODE_DIR/node.yaml"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "Starting validator $i..."
        cd "$NODE_DIR"
        $APTOS_NODE_BIN --config "$CONFIG_FILE" > validator.log 2>&1 &
        echo "Validator $i started with PID $!"
    else
        echo "Warning: Config file not found for validator $i"
    fi
done

echo "All validators started. Check logs for details."
echo "To check node health: curl http://localhost:8080/v1/health"
echo "To view logs: tail -f $CHAIN_DIR/{0,1,2,3}/validator.log"
