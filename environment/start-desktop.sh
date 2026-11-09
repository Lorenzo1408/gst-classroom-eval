#!/usr/bin/env bash

set -Eeuo pipefail

exec > >(tee -a /tmp/start-desktop-trace.log) 2>&1

export DISPLAY="${DISPLAY:-:99}"

echo "Starting desktop on ${DISPLAY}..."

# --------------------------------------------------------------------
# Xvfb
# --------------------------------------------------------------------

if pgrep -x Xvfb >/dev/null 2>&1; then
    echo "Xvfb is already running."
else
    echo "Starting Xvfb..."

    # A container restart keeps /tmp: remove a stale lock left by a previous
    # Xvfb, otherwise it refuses to start ("Server is already active").
    DISPLAY_NUMBER="${DISPLAY#:}"
    rm -f "/tmp/.X${DISPLAY_NUMBER}-lock" "/tmp/.X11-unix/X${DISPLAY_NUMBER}"

    # Disable X11 access control to avoid Xauthority issues in Codespaces.
    # Suitable for this isolated teaching environment.
    Xvfb "${DISPLAY}" \
        -screen 0 1920x1080x24 \
        -ac \
        +extension GLX \
        +render \
        -noreset \
        >/tmp/xvfb.log 2>&1 &
fi

# Wait until the X server accepts connections.
for _ in $(seq 1 30); do
    if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    echo "Xvfb failed to start:"
    cat /tmp/xvfb.log || true
    exit 1
fi

# --------------------------------------------------------------------
# Window manager
# --------------------------------------------------------------------

# Configure a plain background without requiring feh, nitrogen, or another
# wallpaper application.
mkdir -p "${HOME}/.fluxbox"

cat > "${HOME}/.fluxbox/init" <<'EOF'
session.screen0.rootCommand: fbsetroot -solid '#202020'
EOF

if pgrep -x fluxbox >/dev/null 2>&1; then
    echo "Fluxbox is already running."
else
    echo "Starting Fluxbox..."

    fluxbox \
        >/tmp/fluxbox.log 2>&1 &
fi

# --------------------------------------------------------------------
# VNC server
# --------------------------------------------------------------------

if pgrep -x x11vnc >/dev/null 2>&1; then
    echo "x11vnc is already running."
else
    echo "Starting x11vnc..."

    x11vnc \
        -display "${DISPLAY}" \
        -forever \
        -shared \
        -nopw \
        -localhost \
        -rfbport 5900 \
        -noxrecord \
        -noxfixes \
        -noxdamage \
        -repeat \
        >/tmp/x11vnc.log 2>&1 &
fi

# Wait for the VNC server to listen.
for _ in $(seq 1 30); do
    if (echo >/dev/tcp/127.0.0.1/5900) >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! (echo >/dev/tcp/127.0.0.1/5900) >/dev/null 2>&1; then
    echo "x11vnc failed to listen on port 5900:"
    cat /tmp/x11vnc.log || true
    exit 1
fi

# --------------------------------------------------------------------
# noVNC / websockify
# --------------------------------------------------------------------

if pgrep -f '[w]ebsockify.*6080' >/dev/null 2>&1; then
    echo "websockify is already running."
    exit 0
fi

echo "Starting noVNC on port 6080..."

exec websockify \
    --web=/usr/share/novnc \
    --heartbeat=30 \
    0.0.0.0:6080 \
    127.0.0.1:5900

