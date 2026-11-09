#!/usr/bin/env bash
# play-recording.sh — plays back a recording made by the sender, or decodes
# it without any window to prove that it is a valid, decodable file.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/play-recording.sh [FILE] [--headless]

  FILE        recording to play (default: recordings/sample.<ext> from $TEAM_CONFIG_FILE)
  --headless  decode to fakesink as fast as possible, print DECODED_FRAMES=<n>
              and exit with a non-zero status if no frame was decoded
  -h, --help  show this help
EOF
}

load_team_config

RECORDING_FILE="recordings/sample.$RECORDING_EXTENSION"
HEADLESS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless) HEADLESS=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         usage >&2; fail "unknown argument '$1'" ;;
        *)          RECORDING_FILE="$1"; shift ;;
    esac
done

[[ -s "$RECORDING_FILE" ]] || fail "recording $RECORDING_FILE is missing or empty"

# Explicit chain rather than playbin: each step (demux, parse, decode) is
# visible, and the demuxer follows CONTAINER from the team config.
DECODE_CHAIN=(
    filesrc location="$RECORDING_FILE"
    ! "$RECORDING_DEMUXER" ! h264parse ! avdec_h264 ! videoconvert
)

if ! $HEADLESS; then
    log "Playing $RECORDING_FILE (Ctrl+C to stop)"
    set +e; gst-launch-1.0 -e "${DECODE_CHAIN[@]}" ! ximagesink handle-events=false; EXIT_CODE=$?; set -e
    (( EXIT_CODE == 0 )) || fail "gst-launch-1.0 exited with status $EXIT_CODE"
    exit 0
fi

# sync=false: decode as fast as possible. silent=false + -v prints one
# "last-message = chain" line per decoded frame.
log "Decoding $RECORDING_FILE without display"
set +e
DECODE_LOG="$(gst-launch-1.0 -v "${DECODE_CHAIN[@]}" ! fakesink name=play_sink silent=false sync=false 2>&1)"
EXIT_CODE=$?
set -e
DECODED_FRAMES=$(grep -c "play_sink: last-message = chain" <<<"$DECODE_LOG" || true)
echo "DECODED_FRAMES=$DECODED_FRAMES"

(( EXIT_CODE == 0 )) || { echo "$DECODE_LOG" | tail -n 20 >&2; fail "gst-launch-1.0 exited with status $EXIT_CODE"; }
(( DECODED_FRAMES > 0 )) || fail "no frame could be decoded from $RECORDING_FILE"
log "Decoded $DECODED_FRAMES frames from $RECORDING_FILE"
