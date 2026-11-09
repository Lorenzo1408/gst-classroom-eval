#!/usr/bin/env bash
# build.sh — configures and compiles build/monitor_sender with CMake.
# The full output is also saved in artifacts/build.log.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BUILD_DIR="build"
BINARY="$BUILD_DIR/monitor_sender"
BUILD_LOG="$ARTIFACTS_DIR/build.log"

build() {
    local tool
    for tool in cmake c++ pkg-config; do
        command -v "$tool" >/dev/null || fail "'$tool' not found (run inside the course container)"
    done
    pkg-config --exists gstreamer-1.0 || fail "GStreamer development files (gstreamer-1.0.pc) not found"

    log "Configuring ($BUILD_DIR/, GStreamer $(pkg-config --modversion gstreamer-1.0))"
    cmake -S . -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
    log "Compiling"
    cmake --build "$BUILD_DIR" --parallel

    [[ -x "$BINARY" ]] || fail "$BINARY was not produced"
    log "Build OK: $BINARY"
}

mkdir -p "$ARTIFACTS_DIR"
# pipefail: a failure inside build() is the exit status of the pipeline.
build 2>&1 | tee "$BUILD_LOG"
