#!/bin/bash
# Build llama.cpp as a static library, from the sources whisper.cpp vendors
# for its own "talk-llama" example (examples/talk-llama/), using the ggml
# already built by build-whisper.sh. Run build-whisper.sh first.
#
# Why build from whisper.cpp's vendored copy instead of adding a second
# llama.cpp submodule: both whisper.cpp and llama.cpp vendor their own copy
# of ggml. Building a second, independent llama.cpp would produce a second
# set of ggml static libraries with the same symbol names as whisper.cpp's —
# linking both into one binary fails with duplicate-symbol errors. whisper.cpp
# avoids this for its own talk-llama example by vendoring a llama.cpp source
# snapshot that builds against the *same* ggml instance. This script does the
# same for WhisperDictation's Custom Operations feature.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WHISPER_DIR="$PROJECT_DIR/whisper.cpp"
TALK_LLAMA_DIR="$WHISPER_DIR/examples/talk-llama"
LLAMA_CMAKE_DIR="$SCRIPT_DIR/llama-cmake"
BUILD_DIR="$LLAMA_CMAKE_DIR/build"
LIB_OUTPUT_DIR="$PROJECT_DIR/lib"

echo "==> Building llama.cpp static library (from whisper.cpp's vendored talk-llama sources)..."

if [ ! -f "$TALK_LLAMA_DIR/llama.cpp" ]; then
    echo "Error: $TALK_LLAMA_DIR/llama.cpp not found."
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

if [ ! -f "$WHISPER_DIR/build/ggml/src/libggml.a" ]; then
    echo "Error: whisper.cpp hasn't been built yet (no $WHISPER_DIR/build/ggml/src/libggml.a)."
    echo "Run ./scripts/build-whisper.sh first — this script links against its ggml build."
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$LIB_OUTPUT_DIR"

MIN_MACOS="14.0"

cmake -B "$BUILD_DIR" -S "$LLAMA_CMAKE_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DTALK_LLAMA_DIR="$TALK_LLAMA_DIR" \
  -DWHISPER_CPP_DIR="$WHISPER_DIR"

cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)" --config Release

echo "==> Copying static library..."
cp "$BUILD_DIR/libwhisperdictation_llama.a" "$LIB_OUTPUT_DIR/"

echo "==> Copying headers..."
cp "$TALK_LLAMA_DIR/llama.h" "$LIB_OUTPUT_DIR/"

echo ""
echo "==> Built library:"
ls -lh "$LIB_OUTPUT_DIR/libwhisperdictation_llama.a"

echo ""
echo "==> Done! Library is in $LIB_OUTPUT_DIR/"
