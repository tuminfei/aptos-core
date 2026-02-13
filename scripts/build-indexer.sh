#!/bin/bash
# Copyright (c) Aptos
# SPDX-License-Identifier: Apache-2.0
set -e

PROFILE=${PROFILE:-release}

echo "Building indexer and related binaries"
echo "PROFILE: $PROFILE"

echo "CARGO_TARGET_DIR: $CARGO_TARGET_DIR"

if [[ "$PROFILE" == "performance" ]]; then
  EXTRA_CONFIGS=(--config 'build.rustflags=["-C", "linker-plugin-lto"]')
fi

# Build all the rust binaries
cargo build "${EXTRA_CONFIGS[@]}" --locked --profile=$PROFILE \
    -p aptos-indexer-grpc-cache-worker \
    -p aptos-indexer-grpc-file-store \
    -p aptos-indexer-grpc-data-service \
    -p aptos-indexer-grpc-data-service-v2 \
    "$@"

# After building, copy the binaries we need to project root bin directory
BINS=(
    aptos-indexer-grpc-cache-worker
    aptos-indexer-grpc-file-store
    aptos-indexer-grpc-data-service
    aptos-indexer-grpc-data-service-v2
)

# Create bin directory if it doesn't exist
BIN_DIR="$(dirname "$(dirname "$(dirname "$0")")")/bin"
mkdir -p "$BIN_DIR"

# Use target directory with fallback to CARGO_TARGET_DIR
TARGET_DIR="${CARGO_TARGET_DIR:-target}"

for BIN in "${BINS[@]}"; do
    if [ -f "$TARGET_DIR/$PROFILE/$BIN" ]; then
        cp "$TARGET_DIR/$PROFILE/$BIN" "$BIN_DIR/"
    else
        echo "Warning: $TARGET_DIR/$PROFILE/$BIN not found, skipping"
    fi
done

echo "Build completed successfully! Binaries copied to: $BIN_DIR"
