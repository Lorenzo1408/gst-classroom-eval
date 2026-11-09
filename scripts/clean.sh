#!/usr/bin/env bash
# clean.sh — removes everything generated (build/ and artifacts/).
# The committed evidence/ and recordings/ folders are never touched.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

for dir in build "$ARTIFACTS_DIR"; do
    if [[ -e "$dir" ]]; then
        rm -rf -- "$dir"
        log "Removed $dir/"
    fi
done
log "Clean OK"
