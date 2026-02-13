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

# start specific node
start_node() {
    local node_id=$1
    local NODE_DIR="$CHAIN_DIR/$node_id"
    local CONFIG_FILE="$NODE_DIR/node.yaml"
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "Starting validator $node_id..."
        cd "$NODE_DIR"
        nohup $APTOS_NODE_BIN --config "$CONFIG_FILE" > validator.log 2>&1 &
        PID=$!
        echo "Validator $node_id started with PID $PID"
        # save PID to file
        echo $PID > validator.pid
    else
        echo "Error: Config file not found for validator $node_id"
        exit 1
    fi
}

# stop specific node
stop_node() {
    local node_id=$1
    local NODE_DIR="$CHAIN_DIR/$node_id"
    local PID_FILE="$NODE_DIR/validator.pid"
    
    if [ -f "$PID_FILE" ]; then
        local PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo "Stopping validator $node_id with PID $PID..."
            kill $PID
            rm "$PID_FILE"
            echo "Validator $node_id stopped"
        else
            echo "Validator $node_id (PID $PID) is not running"
            rm "$PID_FILE"
        fi
    else
        echo "Error: PID file not found for validator $node_id"
    fi
}

# restart specific node
restart_node() {
    local node_id=$1
    echo "Restarting validator $node_id..."
    stop_node $node_id
    sleep 2
    start_node $node_id
    echo "Validator $node_id restarted"
}

# check status of specific node
status_node() {
    local node_id=$1
    local NODE_DIR="$CHAIN_DIR/$node_id"
    local PID_FILE="$NODE_DIR/validator.pid"
    
    echo "Checking status of validator $node_id..."
    
    if [ -f "$PID_FILE" ]; then
        local PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo "Validator $node_id: RUNNING"
            echo "PID: $PID"
            echo "Log file: $NODE_DIR/validator.log"
            
            # Try to check health status via HTTP
            local health_url="http://localhost:808$node_id/v1/health"
            if curl -s -o /dev/null -w "%{http_code}" $health_url | grep -q "200"; then
                echo "Health status: HEALTHY"
            else
                echo "Health status: UNKNOWN (HTTP check failed)"
            fi
        else
            echo "Validator $node_id: STOPPED"
            echo "Note: PID file exists but process is not running"
            rm "$PID_FILE"
        fi
    else
        echo "Validator $node_id: STOPPED"
        echo "Note: No PID file found"
    fi
    echo
}

# check status of all nodes
status_nodes() {
    echo "Checking status of all validators..."
    echo "----------------------------------"
    
    for i in $(ls -d "$CHAIN_DIR"/*/ 2>/dev/null | grep -E "[0-9]+/$" | sort -n); do
        i=$(basename "$i")
        status_node $i
    done
    
    echo "----------------------------------"
    echo "Status check completed"
}

# stop all nodes
stop_validators() {
    echo "Stopping all validators..."
    for i in $(ls -d "$CHAIN_DIR"/*/ 2>/dev/null | grep -E "[0-9]+/$" | sort -n); do
        i=$(basename "$i")
        NODE_DIR="$CHAIN_DIR/$i"
        PID_FILE="$NODE_DIR/validator.pid"
        
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "Stopping validator $i with PID $PID..."
                kill $PID
                rm "$PID_FILE"
            else
                echo "Validator $i (PID $PID) is not running"
                rm "$PID_FILE"
            fi
        fi
    done
    echo "All validators stopped"
}

# start all nodes
start_all_nodes() {
    for i in $(ls -d "$CHAIN_DIR"/*/ 2>/dev/null | grep -E "[0-9]+/$" | sort -n); do
        i=$(basename "$i")
        NODE_DIR="$CHAIN_DIR/$i"
        CONFIG_FILE="$NODE_DIR/node.yaml"
        
        if [ -f "$CONFIG_FILE" ]; then
            echo "Starting validator $i..."
            cd "$NODE_DIR"
            nohup $APTOS_NODE_BIN --config "$CONFIG_FILE" > validator.log 2>&1 &
            PID=$!
            echo "Validator $i started with PID $PID"
            # save PID to file
            echo $PID > validator.pid
        else
            echo "Warning: Config file not found for validator $i"
        fi
    done
    
    echo "All validators started. Check logs for details."
echo "To check node health: curl http://localhost:8080/v1/health"
echo "To view logs: tail -f $CHAIN_DIR/{0,1,2,3}/validator.log"
echo "To stop all validators: pkill -f 'aptos-node --config'"
echo "To stop specific validator: ./scripts/start_nodes.sh stop-node <node_id>"
echo "To restart specific validator: ./scripts/start_nodes.sh restart-node <node_id>"
echo "To check status of specific validator: ./scripts/start_nodes.sh status-node <node_id>"
echo "To check status of all validators: ./scripts/start_nodes.sh status"
}

# stop_validators 
if [ "$1" == "stop" ]; then
    stop_validators
    exit 0
elif [ "$1" == "stop-node" ] && [ -n "$2" ]; then
    stop_node $2
    exit 0
elif [ "$1" == "restart-node" ] && [ -n "$2" ]; then
    restart_node $2
    exit 0
elif [ "$1" == "status" ]; then
    status_nodes
    exit 0
elif [ "$1" == "status-node" ] && [ -n "$2" ]; then
    status_node $2
    exit 0
else
    start_all_nodes
fi
