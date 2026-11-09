#!/usr/bin/env bash
# sender.sh — command-line (gst-launch) version of the video monitoring sender.
#
# One live source, common processing, then a tee with three branches:
#   A: local preview   B: H.264 recording   C: RTP/JPEG over UDP
# The native application build/monitor_sender implements the same pipeline.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    cat <<EOF
Usage: scripts/sender.sh [--headless] [--duration SECONDS] [--output FILE] [--jpeg-quality Q]

  --headless          replace the preview window with fakesink
  --duration SECONDS  stop cleanly (EOS) after SECONDS; 0 = until Ctrl+C
                      (default: RUNTIME from $TEAM_CONFIG_FILE)
  --output FILE       recording file (default: $ARTIFACTS_DIR/sender-recording.<ext>)
  --jpeg-quality Q    network JPEG quality, 1-100 (default: $DEFAULT_JPEG_QUALITY)
  -h, --help          show this help

All other values (pattern, size, frame rate, port, overlay position,
container) come from $TEAM_CONFIG_FILE.
EOF
}

load_team_config

HEADLESS=false
DURATION_SECONDS="$RUNTIME"
RECORDING_FILE="$ARTIFACTS_DIR/sender-recording.$RECORDING_EXTENSION"
JPEG_QUALITY="$DEFAULT_JPEG_QUALITY"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --headless)     HEADLESS=true; shift ;;
        --duration)     DURATION_SECONDS="${2:-}"; shift 2 || fail "--duration needs a value" ;;
        --output)       RECORDING_FILE="${2:-}"; shift 2 || fail "--output needs a value" ;;
        --jpeg-quality) JPEG_QUALITY="${2:-}"; shift 2 || fail "--jpeg-quality needs a value" ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; fail "unknown argument '$1'" ;;
    esac
done

is_unsigned_integer "$DURATION_SECONDS" || fail "--duration must be a non-negative integer (got '$DURATION_SECONDS')"
is_unsigned_integer "$JPEG_QUALITY" && (( JPEG_QUALITY >= 1 && JPEG_QUALITY <= 100 )) \
    || fail "--jpeg-quality must be between 1 and 100 (got '$JPEG_QUALITY')"
[[ "$RECORDING_FILE" == *."$RECORDING_EXTENSION" ]] \
    || fail "--output must end with .$RECORDING_EXTENSION (CONTAINER=$CONTAINER)"
mkdir -p "$(dirname "$RECORDING_FILE")"

if $HEADLESS; then
    PREVIEW_SINK=(fakesink sync=true)
else
    PREVIEW_SINK=(ximagesink handle-events=false)
fi

# Each array element is one gst-launch argument: quotes inside an element
# are kept, which protects the overlay text containing spaces and '|'.
PIPELINE=(
    videotestsrc pattern="$PATTERN" is-live=true
    ! "video/x-raw,format=I420,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1"
    ! videobalance name=video_balance
    ! timeoverlay name=info_overlay "text=\"$OVERLAY_TEXT\""
        halignment="$OVERLAY_HALIGN" valignment="$OVERLAY_VALIGN"
        shaded-background=true "font-desc=\"Sans 14\""
    ! tee name=t
    # Branch A: preview. Leaky queue: a slow display drops old frames
    # instead of growing; it never holds back the other branches.
    t. ! queue name=preview_queue leaky=downstream max-size-buffers=2
       ! videoconvert ! "${PREVIEW_SINK[@]}" name=preview_sink
    # Branch B: recording. Not leaky (no gaps in the recording); a 3 s
    # buffer absorbs encoder bursts so the tee is not blocked.
    t. ! queue name=record_queue max-size-time=3000000000 max-size-buffers=0 max-size-bytes=0
       ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max="$FPS" bitrate=1500
       ! h264parse ! "$RECORDING_MUXER" ! filesink name=rec_sink location="$RECORDING_FILE"
    # Branch C: network. Leaky: a late live frame is useless.
    t. ! queue name=net_queue leaky=downstream
       ! jpegenc quality="$JPEG_QUALITY" ! rtpjpegpay
       ! udpsink name=net_sink host=127.0.0.1 port="$PORT"
)

log "Pattern=$PATTERN ${WIDTH}x${HEIGHT}@${FPS}fps, RTP/JPEG q$JPEG_QUALITY -> 127.0.0.1:$PORT"
log "Recording to $RECORDING_FILE ($CONTAINER), preview: ${PREVIEW_SINK[0]}"
if (( DURATION_SECONDS > 0 )); then
    log "Running for ${DURATION_SECONDS}s, then sending EOS"
    # -e: on SIGINT, send EOS so the muxer finalizes the file.
    # --preserve-status: return gst-launch's own exit code, not 124.
    set +e
    timeout --foreground --preserve-status -s INT "$DURATION_SECONDS" gst-launch-1.0 -e "${PIPELINE[@]}"
    EXIT_CODE=$?
    set -e
else
    log "Running until Ctrl+C (EOS is sent on interrupt)"
    set +e
    gst-launch-1.0 -e "${PIPELINE[@]}"
    EXIT_CODE=$?
    set -e
fi

if (( EXIT_CODE != 0 )); then
    fail "gst-launch-1.0 exited with status $EXIT_CODE"
fi
[[ -s "$RECORDING_FILE" ]] || fail "recording $RECORDING_FILE is missing or empty"
log "Recording finalized: $RECORDING_FILE ($(stat -c %s "$RECORDING_FILE" 2>/dev/null || stat -f %z "$RECORDING_FILE") bytes)"
