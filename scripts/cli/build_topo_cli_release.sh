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
# Auto-detect crate folder depending on whether the codebase has been renamed
if [ -f "crates/topo/Cargo.toml" ]; then
  CRATE_NAME='topo'
else
  CRATE_NAME='aptos'
fi
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

# Rename the compiled binary to 'topo' if it was built from the 'aptos' crate
if [ "$CRATE_NAME" != "topo" ]; then
  if [ -f "$CRATE_NAME" ]; then
    mv "$CRATE_NAME" topo
  fi
  if [ -f "$CRATE_NAME.exe" ]; then
    mv "$CRATE_NAME.exe" topo.exe
  fi
fi

# Compress the CLI
ZIP_NAME="$NAME-$VERSION-$PLATFORM_NAME-$ARCH.zip"

echo "Zipping release: $ZIP_NAME"
# Depending on target platform, the executable might have .exe
if [ -f "topo.exe" ]; then
  zip "$ZIP_NAME" "topo.exe"
else
  zip "$ZIP_NAME" "topo"
fi
mv "$ZIP_NAME" ../..
