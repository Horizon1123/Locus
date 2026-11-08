#!/bin/bash
set -euo pipefail

# Rebuild the native library because cancelling a Swift task cannot cancel an
# in-flight Rust future. Native deadlines must drop that future before returning.
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
revision=89702099f4d7552f704f93b4526756abda319ceb
features='ring dvt location_simulation remote_pairing tunnel_tcp_stack obfuscate'
mkdir -p "$project_dir/Vendor/idevice-build"
source_dir="$(mktemp -d "$project_dir/Vendor/idevice-build/locus.XXXXXX")"
git -C "$source_dir" init -q
git -C "$source_dir" remote add origin https://github.com/jkcoxson/idevice.git
git -C "$source_dir" fetch --depth 1 origin "$revision"
git -C "$source_dir" checkout --detach FETCH_HEAD
git -C "$source_dir" apply --check "$project_dir/Vendor/idevice/locus-timeout.patch"
git -C "$source_dir" apply "$project_dir/Vendor/idevice/locus-timeout.patch"

cd "$source_dir"
cargo test -p idevice-ffi --locked --no-default-features --features "$features" --lib locus_ -- --nocapture
rustup target add aarch64-apple-ios
ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
SDKROOT="$ios_sdk" BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$ios_sdk" IPHONEOS_DEPLOYMENT_TARGET=18.0 \
  cargo build -p idevice-ffi --release --locked --target aarch64-apple-ios \
    --no-default-features --features "$features"
cp target/aarch64-apple-ios/release/libidevice_ffi.a "$project_dir/Vendor/idevice/libidevice_ffi.a"
cp ffi/idevice.h "$project_dir/Vendor/idevice/idevice.h"
echo "Installed native deadline patch from $revision"
