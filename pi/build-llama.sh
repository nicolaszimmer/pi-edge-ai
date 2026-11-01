#!/usr/bin/env bash
# Build (or update) llama.cpp natively on the Raspberry Pi 5.
#
#   ./build-llama.sh                 # build the pinned release (see LLAMA_REF)
#   LLAMA_REF=b12100 ./build-llama.sh  # build a newer release tag
#   LLAMA_REF=master ./build-llama.sh  # bleeding edge
#   KLEIDIAI=ON ./build-llama.sh     # also compile Arm KleidiAI micro-kernels (benchmark it!)
#
# A native build (-DGGML_NATIVE=ON, the default) compiles for the Pi 5's
# Cortex-A76: NEON + dotprod + fp16. llama.cpp then repacks Q4_0 weights at
# load time into the dotprod-friendly 4x4 layout, which is the fastest path
# on this CPU.
set -euo pipefail

PREFIX="${PREFIX:-/opt/pi-llm}"
LLAMA_DIR="${LLAMA_DIR:-$PREFIX/llama.cpp}"
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp.git}"
# Release tag these scripts were written and tested against. Newer tags
# usually work; if something breaks after an upgrade, go back to this one.
LLAMA_REF="${LLAMA_REF:-b12032}"
KLEIDIAI="${KLEIDIAI:-OFF}"
JOBS="${JOBS:-$(nproc)}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    log "Cloning llama.cpp ($LLAMA_REF) into $LLAMA_DIR"
    git clone --depth 1 --branch "$LLAMA_REF" "$LLAMA_REPO" "$LLAMA_DIR"
else
    log "Updating llama.cpp in $LLAMA_DIR to $LLAMA_REF"
    git -C "$LLAMA_DIR" fetch --depth 1 origin "$LLAMA_REF"
    git -C "$LLAMA_DIR" checkout --detach FETCH_HEAD
fi

cd "$LLAMA_DIR"

# A shallow clone can't count commits, so tell CMake the build number
# explicitly. This makes `--version` correct and makes the build download the
# web UI that matches this server version (instead of falling back to "latest").
build_number_flag=()
if [[ "$LLAMA_REF" =~ ^b([0-9]+)$ ]]; then
    build_number_flag=(-DLLAMA_BUILD_NUMBER="${BASH_REMATCH[1]}")
fi

log "Configuring (native Cortex-A76 build, KleidiAI=$KLEIDIAI)"
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_CPU_KLEIDIAI="$KLEIDIAI" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    "${build_number_flag[@]}"

log "Compiling with $JOBS jobs (first build takes ~15-25 min on a Pi 5)"
cmake --build build --config Release -j "$JOBS" --target llama-server llama-bench

log "Done:"
./build/bin/llama-server --version
