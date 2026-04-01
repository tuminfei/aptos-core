#!/bin/bash
# Copyright © Topo Foundation
# SPDX-License-Identifier: Apache-2.0

###########################################
# Build and package a release for the CLI #
###########################################
# Example:
# build_topo_cli_release.sh macOS 1.0.0
#
# To skip checks:
# build_topo_cli_release.sh macOS 1.0.0 true
#

# Note: This must be run from the root of the topo-chain repository

set -e

NAME='topo-cli'
CRATE_NAME='topo' # [注意]: 请确保在这个库下，实际存在的对应的Cargo crate名称为 "topo" 或修改此处为准确的目录名
CARGO_PATH="crates/$CRATE_NAME/Cargo.toml"
PLATFORM_NAME="$1"
EXPECTED_VERSION="$2"
SKIP_CHECKS="$3"
COMPATIBILITY_MODE="$4"

# Grab system information
ARCH=$(uname -m)
OS=$(uname -s)
VERSION=$(sed -n '/^\w*version = /p' "$CARGO_PATH" | sed 's/^.*=[ ]*"//g' | sed 's/".*$//g')

if [[ "$SKIP_CHECKS" != "true" ]]; then
  # Check that the version is well-formed, note that it should already be correct, but this double checks it
  if ! [[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$EXPECTED_VERSION is malformed, must be of the form '^[0-9]+\.[0-9]+\.[0-9]+$'"
    exit 1
  fi

  # Check that the release doesn't already exist in the target repo
  if curl -s --stderr /dev/null --output /dev/null --head -f "https://github.com/Topo-Labs/topo-chain/releases/download/topo-cli-v$EXPECTED_VERSION/topo-cli-$EXPECTED_VERSION-Ubuntu-22.04-x86_64.zip"; then
    echo "$EXPECTED_VERSION already released in Topo-Labs/topo-chain"
    exit 3
  fi
else
  echo "WARNING: Skipping version checks!"
fi

echo "Building release $VERSION of $NAME for $OS-$PLATFORM_NAME on $ARCH"
if [[ "$COMPATIBILITY_MODE" == "true" ]]; then
  RUSTFLAGS="-C target-cpu=generic --cfg tokio_unstable -C target-feature=-sse4.2,-avx" cargo build -p "$CRATE_NAME" --profile cli
else
  cargo build -p "$CRATE_NAME" --profile cli
fi
cd target/cli/

# Compress the CLI
ZIP_NAME="$NAME-$VERSION-$PLATFORM_NAME-$ARCH.zip"

echo "Zipping release: $ZIP_NAME"
zip "$ZIP_NAME" "$CRATE_NAME"
mv "$ZIP_NAME" ../..
