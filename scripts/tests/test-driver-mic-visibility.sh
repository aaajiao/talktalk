#!/bin/bash
# Compile/run the real visibility code against a fake HAL host. No installation or audio IO.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/tt-mic-visibility.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sdk="$(xcrun --show-sdk-path)"
aspl="$root/Driver/third_party/libASPL"
xcrun clang++ -std=c++17 -O0 -isysroot "$sdk" \
    -Wno-reorder-init-list -Wno-invalid-offsetof \
    -isystem "$aspl/include" -I "$aspl/src" -I "$root/Driver/Sources" \
    "$aspl"/src/*.cpp "$root/Driver/Sources/MicDevice.cpp" \
    "$root/Driver/Sources/MicVisibility.cpp" \
    "$root/Driver/Tests/MicVisibilityTests.cpp" \
    -framework CoreAudio -framework CoreFoundation -o "$work/mic-visibility-tests"
"$work/mic-visibility-tests"
