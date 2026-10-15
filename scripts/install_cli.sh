#!/bin/bash
# Copyright © Aptos Foundation
# SPDX-License-Identifier: Apache-2.0

# Install the Aptos CLI built from Topo-Labs/topo-chain.
# Usage: bash install_cli.sh [--version X.Y.Z] [--bin-dir PATH]
set -euo pipefail

DEFAULT_VERSION="9.5.1"
VERSION="$DEFAULT_VERSION"
BIN_DIR="$HOME/.local/bin"
REPOSITORY="Topo-Labs/topo-chain"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--bin-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      if [[ "$1" == "--version" ]]; then
        VERSION="$2"
      else
        BIN_DIR="$2"
      fi
      shift 2
      ;;
    -h|--help)
      echo "Usage: bash install_cli.sh [--version X.Y.Z] [--bin-dir PATH]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version must be of the form MAJOR.MINOR.PATCH" >&2
  exit 1
fi

OS=$(uname -s)
ARCH=$(uname -m)
case "$OS-$ARCH" in
  Linux-x86_64|Linux-aarch64)
    PLATFORM="Linux"
    ;;
  Darwin-x86_64|Darwin-arm64)
    PLATFORM="macOS"
    ;;
  *)
    echo "Unsupported platform: $OS-$ARCH" >&2
    exit 1
    ;;
esac

for tool in curl unzip; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required command not found: $tool" >&2
    exit 1
  fi
done

ARCHIVE="topo-cli-$VERSION-$PLATFORM-$ARCH.zip"
URL="https://github.com/$REPOSITORY/releases/download/topo-cli-v$VERSION/$ARCHIVE"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fLsS "$URL" -o "$TMP_DIR/$ARCHIVE"
# The release builds crate `aptos`, so the executable retains its original name.
unzip -q "$TMP_DIR/$ARCHIVE" aptos -d "$TMP_DIR"
mkdir -p "$BIN_DIR"
install -m 755 "$TMP_DIR/aptos" "$BIN_DIR/aptos"
echo "Installed Topo CLI $VERSION to $BIN_DIR/aptos"
echo "Run '$BIN_DIR/aptos --version' to verify the installation."
