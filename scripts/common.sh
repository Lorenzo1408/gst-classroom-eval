#!/usr/bin/env bash
# common.sh — shared helpers sourced by the other scripts (not run directly).
#
# Provides:
#   - REPO_ROOT and a cd to it (scripts work from any directory)
#   - log / fail helpers
#   - load_team_config: reads and validates config/team.conf, then derives
#     the GStreamer-specific values used by the pipelines.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SCRIPT_NAME="$(basename "$0")"
TEAM_CONFIG_FILE="config/team.conf"
ARTIFACTS_DIR="artifacts"

# Shown in the video overlay (team member identifiers).
TEAM_MEMBERS="Lorenzo Bravard"

# Network JPEG quality: snow is almost incompressible; 30 keeps every frame
# within the UDP receive buffer (measured threshold ~60-70, see debug-report.md).
DEFAULT_JPEG_QUALITY=30

# RTP/JPEG uses the static payload type 26 (RFC 3551) and a 90 kHz clock.
RTP_JPEG_CAPS="application/x-rtp,media=video,clock-rate=90000,encoding-name=JPEG,payload=26"

log()  { echo "[$SCRIPT_NAME] $*"; }
fail() { echo "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }

is_unsigned_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

load_team_config() {
    [[ -r "$TEAM_CONFIG_FILE" ]] || fail "$TEAM_CONFIG_FILE not found or not readable"
    # shellcheck source=/dev/null
    source "$TEAM_CONFIG_FILE"

    local key
    for key in PATTERN WIDTH HEIGHT FPS PORT OVERLAY_POSITION CONTAINER NETWORK_CODEC RUNTIME; do
        [[ -n "${!key:-}" ]] || fail "$TEAM_CONFIG_FILE: missing value for $key"
    done
    for key in WIDTH HEIGHT FPS PORT RUNTIME; do
        is_unsigned_integer "${!key}" || fail "$TEAM_CONFIG_FILE: $key must be an unsigned integer (got '${!key}')"
    done

    case "$OVERLAY_POSITION" in
        top-left)     OVERLAY_HALIGN=left;   OVERLAY_VALIGN=top ;;
        top-center)   OVERLAY_HALIGN=center; OVERLAY_VALIGN=top ;;
        bottom-right) OVERLAY_HALIGN=right;  OVERLAY_VALIGN=bottom ;;
        *) fail "$TEAM_CONFIG_FILE: unsupported OVERLAY_POSITION '$OVERLAY_POSITION'" ;;
    esac

    case "$CONTAINER" in
        matroska) RECORDING_EXTENSION=mkv; RECORDING_MUXER=matroskamux; RECORDING_DEMUXER=matroskademux ;;
        mpegts)   RECORDING_EXTENSION=ts;  RECORDING_MUXER=mpegtsmux;   RECORDING_DEMUXER=tsdemux ;;
        *) fail "$TEAM_CONFIG_FILE: unsupported CONTAINER '$CONTAINER'" ;;
    esac

    [[ "$NETWORK_CODEC" == "jpeg" ]] || fail "$TEAM_CONFIG_FILE: only NETWORK_CODEC=jpeg is implemented (got '$NETWORK_CODEC')"

    OVERLAY_TEXT="$TEAM_MEMBERS | ${WIDTH}x${HEIGHT} @ ${FPS} fps |"
}
