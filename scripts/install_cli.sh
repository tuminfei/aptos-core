#!/bin/bash

set -e

# Default version (can be overridden by argument)
DEFAULT_VERSION="0.10.0"
VERSION=""

# Show help function
show_help() {
    echo "Usage: $0 [OPTIONS] [VERSION]"
    echo ""
    echo "Installs the Aptos CLI"
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  -v, --version   Show script version"
    echo ""
    echo "VERSION:"
    echo "  Specify the Aptos CLI version to install (e.g., 0.10.0)"
    echo "  If not specified, the default version will be used"
    echo ""
    echo "Example:"
    echo "  $0 0.10.0     # Install version 0.10.0"
    echo "  $0            # Install default version ($DEFAULT_VERSION)"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "install_cli.sh version 1.0.0"
            exit 0
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$1"
            else
                echo "Error: Too many arguments"
                show_help
                exit 1
            fi
            ;;
    esac
    shift
done

if [ -z "$VERSION" ]; then
    VERSION="$DEFAULT_VERSION"
    echo "No version specified, using default version: $VERSION"
fi

# Check if version matches expected format
if ! echo "$VERSION" | grep -q "^[0-9]\+\.[0-9]\+\.[0-9]\+"; then
    echo "Error: Version must be in format X.X.X"
    show_help
    exit 1
fi

# Determine OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Linux*)
        OS="Linux"
        ;;    Darwin*)
        OS="macOS"
        ;;    CYGWIN*|MINGW*|MSYS*|Windows*)
        OS="Windows"
        ;;    *)
        echo "Error: Unsupported OS: $OS"
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64|amd64)
        ARCH="x86_64"
        ;;
    arm64|aarch64)
        ARCH="arm64"
        ;;
    *)
        echo "Error: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Set download URL and binary name
RELEASE_TAG="aptos-cli-v$VERSION"
DOWNLOAD_URL="https://github.com/tuminfei/aptos-core/releases/download/$RELEASE_TAG/aptos-cli-$VERSION-$OS-$ARCH.zip"
BINARY_NAME="aptos"

if [ "$OS" = "Windows" ]; then
    BINARY_NAME="aptos.exe"
fi

# Set installation directory
if [ "$OS" = "Windows" ]; then
    INSTALL_DIR="$HOME\.aptoscli\bin"
    mkdir -p "$INSTALL_DIR"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

# Download and install
echo "Downloading Aptos CLI v$VERSION for $OS-$ARCH..."
tmp_dir=$(mktemp -d)
cd "$tmp_dir"
curl -s -L -o aptos-cli.zip "$DOWNLOAD_URL"

if [ "$OS" = "Windows" ]; then
    powershell -Command "Expand-Archive -Path aptos-cli.zip -DestinationPath ."
else
    unzip -q aptos-cli.zip
fi

chmod +x "$BINARY_NAME"
mv "$BINARY_NAME" "$INSTALL_DIR/"

# Clean up
cd /
rm -rf "$tmp_dir"

# Add to PATH if not already there
if [ "$OS" != "Windows" ]; then
    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        echo "Adding $INSTALL_DIR to PATH..."
        if [ -f "$HOME/.bashrc" ]; then
            echo "export PATH=\"$INSTALL_DIR:$PATH\"" >> "$HOME/.bashrc"
        fi
        if [ -f "$HOME/.zshrc" ]; then
            echo "export PATH=\"$INSTALL_DIR:$PATH\"" >> "$HOME/.zshrc"
        fi
        echo "Please restart your terminal or run 'source ~/.bashrc' or 'source ~/.zshrc' to update PATH"
    fi
fi

echo "Aptos CLI v$VERSION has been installed to $INSTALL_DIR"
echo "You can now run 'aptos --version' to verify the installation"
