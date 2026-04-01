# Copyright © Aptos Foundation
# SPDX-License-Identifier: Apache-2.0

###########################################
# Build and package a release for the CLI #
###########################################
# Example:
#   build_cli_release.ps1 -ReleaseVersion 1.0.0
#
# To skip checks:
#   build_cli_release.ps1 -ReleaseVersion 1.0.0 -SkipChecks true

# Note: This must be run from the root of the aptos-core repository.

param(
    [Parameter(Mandatory=$true)]
    [string]$ReleaseVersion,
    [string]$SkipChecks = "false"
)

# Set up basic variables.
$NAME="aptos-cli"
$CRATE_NAME="aptos"
$CARGO_PATH="crates\$CRATE_NAME\Cargo.toml"
$Env:VCPKG_ROOT = 'C:\vcpkg\'

# Get the version of the CLI from its Cargo.toml.
$VERSION = Get-Content $CARGO_PATH | Select-String -Pattern '^\w*version = "(\d*\.\d*.\d*)"' | % {"$($_.matches.groups[1])"}

if ($SkipChecks -ne "true") {
    # Check that the version is well-formed.
    if ($ReleaseVersion -notmatch '^\d+\.\d+\.\d+$') {
        Write-Error "$ReleaseVersion is malformed, must be of the form '^[0-9]+\.[0-9]+\.[0-9]+$'"
        exit 1
    }

    # Check that the version matches the Cargo.toml.
    if ($ReleaseVersion -ne $VERSION) {
        Write-Error "Wanted to release for $ReleaseVersion, but Cargo.toml says the version is $VERSION"
        exit 2
    }
} else {
    Write-Host "WARNING: Skipping version checks!"
}

# Use the validated/matched version.
$VERSION = $ReleaseVersion

# Install the developer tools
echo "Installing developer tools"
PowerShell -ExecutionPolicy Bypass -File scripts/windows_dev_setup.ps1

# Note: This is required to bypass openssl isssue on Windows.
echo "Installing OpenSSL"
vcpkg install openssl:x64-windows-static-md --clean-after-build

# Build the CLI.
echo "Building release $VERSION of $NAME for Windows"
cargo build -p $CRATE_NAME --profile cli

# Compress the CLI.
$ZIP_NAME="$NAME-$VERSION-Windows-x86_64.zip"
echo "Compressing CLI to $ZIP_NAME"
Compress-Archive -Path target\cli\$CRATE_NAME.exe -DestinationPath $ZIP_NAME

