#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$SCRIPT_DIR/propctl-src/target}"
export CARGO_TARGET_DIR
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER:-/home/wwb/Android/Sdk/ndk/25.0.8775105/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android33-clang}"

cargo build \
  --manifest-path "$SCRIPT_DIR/propctl-src/Cargo.toml" \
  --target aarch64-linux-android \
  --release

install -m 0755 \
  "$CARGO_TARGET_DIR/aarch64-linux-android/release/propctl" \
  "$SCRIPT_DIR/bin/propctl"

install -m 0755 \
  "$CARGO_TARGET_DIR/aarch64-linux-android/release/patchctl" \
  "$SCRIPT_DIR/bin/patchctl"
