#!/usr/bin/env bash
# run-experiment.sh — controlled comparison: network JPEG quality 30 vs 85.
#
# Only --jpeg-quality changes. Everything else is fixed: team configuration,
# headless native sender, receiver with buffer-size = rmem_max, run length.
# Configurations alternate (30, 85, 30, 85, ...) so that a slow drift of the
# machine load affects both the same way.
#
# Measured for each run (one CSV line):
#   frames produced (decoded from the recording) / frames received
#   kernel UDP drops (RcvbufErrors), network bytes sent and data rate
#   sender and receiver CPU (pidstat), recording size, warnings
#   image quality: mean SSIM of JPEG-coded frames vs. the original frames

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

QUALITIES=(30 85)
BINARY="build/monitor_sender"
EXPERIMENT_DIR="$ARTIFACTS_DIR/experiment"
SSIM_FRAMES=150

usage() {
    cat <<EOF
Usage: scripts/run-experiment.sh [--duration SECONDS] [--repeats N] [--output FILE]

  --duration SECONDS  length of each run, at least 45 (default: 60)
  --repeats N         runs per configuration (default: 3)
  --output FILE       CSV file (default: $ARTIFACTS_DIR/measurements.csv)
  -h, --help          show this help

Total time is about repeats x 2 x (duration + 15) seconds.
The committed results are in evidence/measurements.csv (see experiment.md).
EOF
}

DURATION=60
REPEATS=3
CSV_FILE="$ARTIFACTS_DIR/measurements.csv"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="${2:-}"; shift 2 || fail "--duration needs a value" ;;
        --repeats)  REPEATS="${2:-}"; shift 2 || fail "--repeats needs a value" ;;
        --output)   CSV_FILE="${2:-}"; shift 2 || fail "--output needs a value" ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; fail "unknown argument '$1'" ;;
    esac
done
is_unsigned_integer "$DURATION" && (( DURATION >= 45 )) || fail "--duration must be an integer >= 45 (got '$DURATION')"
is_unsigned_integer "$REPEATS" && (( REPEATS >= 1 )) || fail "--repeats must be an integer >= 1 (got '$REPEATS')"

load_team_config
command -v pidstat >/dev/null || fail "pidstat not found (package sysstat)"
[[ -x "$BINARY" ]] || scripts/build.sh >/dev/null || fail "build failed"
mkdir -p "$EXPERIMENT_DIR" "$(dirname "$CSV_FILE")"

SENDER_PID=""
RECEIVER_PID=""
cleanup() {
    local pid
    for pid in $SENDER_PID $RECEIVER_PID; do kill -INT "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

# Kernel counter of UDP datagrams dropped because a socket buffer was full.
udp_rcvbuf_errors() { awk '/^Udp:/ && ++n == 2 { print $6 }' /proc/net/snmp; }

# Average %CPU from a pidstat log (column located by its header).
pidstat_average() {
    awk '/%CPU/ { for (i = 1; i <= NF; i++) if ($i == "%CPU") c = i }
         /^Average/ && c { print $c; exit }' "$1"   # "Average:" sits in the time column
}

# Mean SSIM between the original frames and the same frames after JPEG
# encode/decode at quality $1 (compare element, 1.0 = identical).
measure_ssim() {
    gst-launch-1.0 -m videotestsrc pattern="$PATTERN" num-buffers="$SSIM_FRAMES" \
        ! "video/x-raw,format=I420,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1" ! tee name=t \
        t. ! queue ! c.sink \
        t. ! queue ! jpegenc quality="$1" ! jpegdec ! c.check \
        compare name=c method=ssim threshold=0 upper=true ! fakesink 2>&1 \
        | grep -oE 'content=\(double\)[0-9.e+-]+' | sed 's/.*)//' \
        | awk '{ s += $1; n++ } END { if (n) printf "%.4f", s / n; else print "NA" }'
}

run_trial() {
    local quality="$1" run="$2"
    local name="q${quality}_run${run}"
    local sender_log="$EXPERIMENT_DIR/$name.sender.log"
    local receiver_log="$EXPERIMENT_DIR/$name.receiver.log"
    local recording="$EXPERIMENT_DIR/$name.$RECORDING_EXTENSION"
    local drops_before receiver_gst_pid sender_exit receiver_exit
    log "Run $run, quality $quality (${DURATION}s)"

    drops_before=$(udp_rcvbuf_errors)
    scripts/receiver.sh test --duration $(( DURATION + 6 )) --log "$receiver_log" >/dev/null 2>&1 &
    RECEIVER_PID=$!
    sleep 1
    receiver_gst_pid=$(pgrep -n -f "^gst-launch-1.0 .*udpsrc port=$PORT " || true)

    "$BINARY" --pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" --fps "$FPS" --port "$PORT" \
        --overlay-position "$OVERLAY_POSITION" --output "$recording" --duration "$DURATION" \
        --headless --jpeg-quality "$quality" > "$sender_log" 2>&1 &
    SENDER_PID=$!
    LC_ALL=C pidstat -p "$SENDER_PID" 1 "$DURATION" > "$EXPERIMENT_DIR/$name.sender.pidstat" 2>&1 &
    [[ -z "$receiver_gst_pid" ]] \
        || LC_ALL=C pidstat -p "$receiver_gst_pid" 1 "$DURATION" > "$EXPERIMENT_DIR/$name.receiver.pidstat" 2>&1 &

    set +e
    wait "$SENDER_PID"; sender_exit=$?
    wait "$RECEIVER_PID"; receiver_exit=$?
    set -e
    SENDER_PID=""; RECEIVER_PID=""
    wait   # pidstat

    local frames_produced frames_received loss drops bytes rate cpu_tx cpu_rx size warn_tx warn_rx ssim
    frames_produced=$(scripts/play-recording.sh "$recording" --headless 2>/dev/null | sed -n 's/^DECODED_FRAMES=//p')
    frames_received=$(sed -n 's/^RECEIVED_FRAMES=//p' "$receiver_log" | tail -1)
    frames_produced=${frames_produced:-0}; frames_received=${frames_received:-0}
    loss=$(awk -v p="$frames_produced" -v r="$frames_received" 'BEGIN { printf "%.1f", p ? 100 * (p - r) / p : 100 }')
    drops=$(( $(udp_rcvbuf_errors) - drops_before ))
    bytes=$(sed -n 's/^NETWORK_BYTES_SENT=//p' "$sender_log")
    rate=$(awk -v b="${bytes:-0}" -v d="$DURATION" 'BEGIN { printf "%.1f", b * 8 / d / 1e6 }')
    cpu_tx=$(pidstat_average "$EXPERIMENT_DIR/$name.sender.pidstat")
    cpu_rx=$(pidstat_average "$EXPERIMENT_DIR/$name.receiver.pidstat" 2>/dev/null || true)
    size=$(stat -c %s "$recording" 2>/dev/null || echo 0)
    warn_tx=$(grep -c "WARNING" "$sender_log" || true)
    warn_rx=$(grep -c "WARNING" "$receiver_log" || true)
    ssim=$(measure_ssim "$quality")

    echo "$run,q$quality,$quality,$DURATION,$frames_produced,$frames_received,$loss,$drops,${bytes:-0},$rate,${cpu_tx:-NA},${cpu_rx:-NA},$size,$warn_tx,$warn_rx,$ssim,$sender_exit,$receiver_exit" >> "$CSV_FILE"
    log "  received $frames_received/$frames_produced (loss $loss %), kernel drops $drops, $rate Mbit/s, CPU sender ${cpu_tx:-NA} %, SSIM $ssim"
    rm -f "$recording"   # ~10 MB per run; only the measurements are kept
}

echo "run,config,jpeg_quality,duration_s,frames_produced,frames_received,frame_loss_pct,udp_rcvbuf_drops,network_bytes_sent,network_mbit_s,sender_cpu_pct,receiver_cpu_pct,recording_bytes,sender_warnings,receiver_warnings,ssim_mean,sender_exit,receiver_exit" > "$CSV_FILE"
log "Experiment: JPEG quality ${QUALITIES[*]}, $REPEATS run(s) x ${DURATION}s each, $PATTERN ${WIDTH}x${HEIGHT}@${FPS}, receive buffer $(cat /proc/sys/net/core/rmem_max) bytes"
for run in $(seq 1 "$REPEATS"); do
    for quality in "${QUALITIES[@]}"; do
        run_trial "$quality" "$run"
    done
done

log "Results: $CSV_FILE"
# Per-configuration means (columns: loss 7, drops 8, Mbit/s 10, CPU 11 and 12, SSIM 16)
awk -F, 'NR > 1 { n[$2]++; l[$2] += $7; d[$2] += $8; r[$2] += $10; c[$2] += $11; x[$2] += $12; s[$2] += $16 }
         END { printf "%-6s %5s %10s %12s %9s %10s %10s %7s\n", "config", "runs", "loss_%", "kernel_drops", "Mbit/s", "cpu_tx_%", "cpu_rx_%", "SSIM"
               for (k in n) printf "%-6s %5d %10.1f %12.0f %9.1f %10.1f %10.1f %7.4f\n", k, n[k], l[k]/n[k], d[k]/n[k], r[k]/n[k], c[k]/n[k], x[k]/n[k], s[k]/n[k] }' "$CSV_FILE"
