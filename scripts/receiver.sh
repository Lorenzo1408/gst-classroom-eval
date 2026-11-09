#!/usr/bin/env bash
# receiver.sh — receives the RTP/JPEG stream sent by the sender on
# 127.0.0.1:PORT and either displays it or decodes it for automated tests.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DEFAULT_TEST_DURATION=30

usage() {
    cat <<EOF
Usage: scripts/receiver.sh display|test [--duration SECONDS] [--log FILE]

  display             show the received video (until Ctrl+C, or --duration)
  test                decode to fakesink without any window, count the
                      decoded frames and check their size
  --duration SECONDS  stop cleanly after SECONDS (test default: $DEFAULT_TEST_DURATION)
  --log FILE          test mode log (default: $ARTIFACTS_DIR/receiver.log)
  -h, --help          show this help

Start the receiver before the sender so that the first frames are not lost.
Test mode prints RECEIVED_FRAMES=<n> and RECEIVED_SIZE=<w>x<h>, and exits
with a non-zero status if no frame was decoded.
EOF
}

load_team_config

RECEIVER_MODE="${1:-}"
case "$RECEIVER_MODE" in
    display|test) shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage >&2; fail "first argument must be 'display' or 'test'" ;;
esac

DURATION_SECONDS=""
RECEIVER_LOG="$ARTIFACTS_DIR/receiver.log"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION_SECONDS="${2:-}"; shift 2 || fail "--duration needs a value" ;;
        --log)      RECEIVER_LOG="${2:-}"; shift 2 || fail "--log needs a value" ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; fail "unknown argument '$1'" ;;
    esac
done
[[ "$RECEIVER_MODE" == test && -z "$DURATION_SECONDS" ]] && DURATION_SECONDS="$DEFAULT_TEST_DURATION"
[[ -z "$DURATION_SECONDS" ]] || is_unsigned_integer "$DURATION_SECONDS" \
    || fail "--duration must be a non-negative integer (got '$DURATION_SECONDS')"

# The default UDP receive buffer is too small for snow frames sent in bursts
# (silent packet loss). Ask for the largest size this kernel allows without
# privileges; requesting more only triggers a warning (see debug-report.md).
UDP_BUFFER_SIZE="$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)"

# RTP/JPEG (RFC 2435) transmits width and height in 8-pixel units, so the
# depayloader rounds them up (540 -> 544). Crop the padding back.
CROP_RIGHT=$(( (WIDTH + 7) / 8 * 8 - WIDTH ))
CROP_BOTTOM=$(( (HEIGHT + 7) / 8 * 8 - HEIGHT ))

if [[ "$RECEIVER_MODE" == display ]]; then
    VIDEO_SINK=(ximagesink handle-events=false)
else
    # silent=false + gst-launch -v prints one "last-message = chain" line
    # per decoded frame: that is what the frame count is based on.
    VIDEO_SINK=(fakesink name=rx_sink silent=false sync=false)
fi

PIPELINE=(
    udpsrc port="$PORT" buffer-size="$UDP_BUFFER_SIZE" caps="$RTP_JPEG_CAPS"
    ! rtpjitterbuffer latency=200
    ! rtpjpegdepay ! jpegdec
    ! videocrop right="$CROP_RIGHT" bottom="$CROP_BOTTOM"
    ! videoconvert ! "${VIDEO_SINK[@]}"
)

run_pipeline() {
    # --foreground: a Ctrl+C typed in the terminal still reaches gst-launch.
    # --preserve-status: return gst-launch's own exit code, not 124.
    if [[ -n "$DURATION_SECONDS" && "$DURATION_SECONDS" -gt 0 ]]; then
        timeout --foreground --preserve-status -s INT "$DURATION_SECONDS" gst-launch-1.0 -e "$@"
    else
        gst-launch-1.0 -e "$@"
    fi
}

log "Listening on UDP port $PORT (RTP/JPEG, receive buffer $UDP_BUFFER_SIZE bytes, crop right=$CROP_RIGHT bottom=$CROP_BOTTOM)"

if [[ "$RECEIVER_MODE" == display ]]; then
    log "Display mode${DURATION_SECONDS:+ for ${DURATION_SECONDS}s} (Ctrl+C to stop)"
    set +e; run_pipeline "${PIPELINE[@]}"; EXIT_CODE=$?; set -e
    (( EXIT_CODE == 0 )) || fail "gst-launch-1.0 exited with status $EXIT_CODE"
    exit 0
fi

mkdir -p "$(dirname "$RECEIVER_LOG")"
log "Test mode for ${DURATION_SECONDS}s, log: $RECEIVER_LOG"
set +e; run_pipeline -v "${PIPELINE[@]}" > "$RECEIVER_LOG" 2>&1; EXIT_CODE=$?; set -e

RECEIVED_FRAMES=$(grep -c "rx_sink: last-message = chain" "$RECEIVER_LOG" || true)
RECEIVED_SIZE=$(grep -oE "videocrop0.GstPad:src: caps = [^;]*" "$RECEIVER_LOG" | head -1 \
    | sed -nE 's/.*width=\(int\)([0-9]+), height=\(int\)([0-9]+).*/\1x\2/p' || true)
SUMMARY="RECEIVED_FRAMES=$RECEIVED_FRAMES
RECEIVED_SIZE=${RECEIVED_SIZE:-none}
RECEIVER_EXIT=$EXIT_CODE"
echo "$SUMMARY" | tee -a "$RECEIVER_LOG"

(( EXIT_CODE == 0 )) || fail "gst-launch-1.0 exited with status $EXIT_CODE (see $RECEIVER_LOG)"
(( RECEIVED_FRAMES > 0 )) || fail "no frame was received on port $PORT"
log "Received and decoded $RECEIVED_FRAMES frames (${RECEIVED_SIZE})"
