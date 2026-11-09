#!/usr/bin/env bash
# Container entry point: starts the browser-accessible virtual desktop and
# keeps the container alive. Trimmed from the course version (no audio,
# no MediaMTX, no classroom web app).

set -Eeuo pipefail

exec > >(tee -a /tmp/start-classroom-trace.log) 2>&1

export DISPLAY="${DISPLAY:-:99}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-classroom}"

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

if ! pgrep -x Xvfb >/dev/null 2>&1; then
    echo "Starting virtual desktop..."
    nohup /usr/local/bin/start-desktop.sh >/tmp/desktop.log 2>&1 &
fi

cleanup() {
    echo "Stopping environment..."
    jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Environment started (virtual desktop on port 6080)."

# The container stays alive while the desktop runs.
wait
