#!/bin/sh
set -eu

NDK_PATH=${NDK_PATH:-/home/wwb/Android/Sdk/ndk/25.0.8775105}
TOOLCHAIN=$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64
CXX=$TOOLCHAIN/bin/aarch64-linux-android23-clang++

mkdir -p zygisk
"$CXX" -std=c++17 -fPIC -shared -Oz -Wall -Wextra \
  -fvisibility=hidden -ffunction-sections -fdata-sections -nostdlib++ \
  -fno-rtti -fno-exceptions -fno-threadsafe-statics \
  -Wl,--gc-sections -Wl,--exclude-libs,ALL \
  zygisk/src/main.cpp -llog -o zygisk/arm64-v8a.so
chmod 644 zygisk/arm64-v8a.so
