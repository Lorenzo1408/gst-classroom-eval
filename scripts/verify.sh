#!/usr/bin/env bash
# verify.sh — automated end-to-end verification of the submission.
#
# Runs the real receiver (test mode) and the real native sender (headless)
# for a short duration, then checks the network reception, the recording and
# the clean EOS-based shutdown. Every check reads real evidence (logs, the
# recording itself); nothing is assumed.
#
# Outputs (artifacts/): build.log (from build.sh), sender.log, receiver.log,
# verification.log, verification-summary.txt, test-recording.<ext>, pipeline.png
# Exit status: 0 only if every check passes.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VERIFY_DURATION=15        # sender run time (subject recommends 10-20 s)
RECEIVER_EXTRA=6          # receiver keeps listening a bit longer than the sender
STEP_TIMEOUT=30           # upper bound for any single short command
BINARY="build/monitor_sender"

BUILD_LOG="$ARTIFACTS_DIR/build.log"
SENDER_LOG="$ARTIFACTS_DIR/sender.log"
RECEIVER_LOG="$ARTIFACTS_DIR/receiver.log"
VERIFICATION_LOG="$ARTIFACTS_DIR/verification.log"
SUMMARY_FILE="$ARTIFACTS_DIR/verification-summary.txt"

# The 10 keys required by the subject, in order, then the extra checks.
SUMMARY_KEYS=(BUILD HELP_OPTION INVALID_ARGUMENTS SENDER_START RECEIVER_START
              RTP_RECEPTION EOS_HANDLING RECORDING_CREATED RECORDING_DECODABLE
              CLEAN_TERMINATION DEPENDENCIES CONFIG REQUIRED_FILES DYNAMIC_PROPERTY)
declare -A RESULT
for key in "${SUMMARY_KEYS[@]}"; do RESULT[$key]=FAIL; done   # not run = FAIL

SENDER_PID=""
RECEIVER_PID=""
TEE_PID=""

pass()   { RESULT[$1]=PASS; log "PASS $1${2:+ - $2}"; }
failed() { RESULT[$1]=FAIL; log "FAIL $1${2:+ - $2}"; }

# Stop a background job politely: SIGINT (EOS), then SIGTERM. Never SIGKILL.
stop_job() {
    local pid="$1" name="$2" i
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 0
    log "Stopping $name (pid $pid)"
    kill -INT "$pid" 2>/dev/null || true
    for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
    kill -TERM "$pid" 2>/dev/null || true
}

write_summary() {
    local key overall=PASS
    : > "$SUMMARY_FILE"
    for key in "${SUMMARY_KEYS[@]}"; do
        echo "$key=${RESULT[$key]}" >> "$SUMMARY_FILE"
        [[ "${RESULT[$key]}" == PASS ]] || overall=FAIL
    done
    echo "OVERALL=$overall" >> "$SUMMARY_FILE"
    echo
    echo "===== $SUMMARY_FILE ====="
    cat "$SUMMARY_FILE"
    [[ "$overall" == PASS ]]
}

# Always runs: kill what we started, write the summary, set the exit status.
on_exit() {
    local status=$?
    trap - EXIT INT TERM
    stop_job "$SENDER_PID" "sender"
    stop_job "$RECEIVER_PID" "receiver"
    (( status == 0 )) || log "ERROR: verification aborted (status $status)"
    local code=1
    if write_summary && (( status == 0 )); then code=0; fi
    # Close our end of the pipe and let tee finish writing, so the whole
    # output is on screen and in verification.log before we return.
    if [[ -n "$TEE_PID" ]]; then
        exec >&- 2>&-
        wait "$TEE_PID" 2>/dev/null || true
    fi
    exit "$code"
}
trap on_exit EXIT
trap 'log "ERROR: interrupted"; exit 130' INT TERM

# Wait until PATTERN appears in FILE, at most SECONDS.
wait_for_line() {
    local file="$1" pattern="$2" deadline=$((SECONDS + $3))
    while (( SECONDS < deadline )); do
        grep -qE -- "$pattern" "$file" 2>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

# Remove the previous run's outputs (build.log belongs to build.sh: kept).
mkdir -p "$ARTIFACTS_DIR"
rm -f "$SENDER_LOG" "$RECEIVER_LOG" "$VERIFICATION_LOG" "$SUMMARY_FILE" \
      "$ARTIFACTS_DIR"/test-recording.* "$ARTIFACTS_DIR"/*.dot "$ARTIFACTS_DIR/pipeline.png"
# tee ignores Ctrl+C so that the summary is still printed and logged.
exec > >(trap "" INT; exec tee -a "$VERIFICATION_LOG") 2>&1
TEE_PID=$!
log "Verification started $(date '+%Y-%m-%d %H:%M:%S'), GStreamer $(gst-launch-1.0 --version 2>/dev/null | sed -n 's/.*version //p' | head -1)"

# ---------------------------------------------------------------- CONFIG
if CONFIG_ERROR=$( (load_team_config) 2>&1 ); then
    load_team_config
    pass CONFIG "$TEAM_CONFIG_FILE: $PATTERN ${WIDTH}x${HEIGHT}@${FPS} port $PORT $CONTAINER"
else
    failed CONFIG "$CONFIG_ERROR"
    exit 1   # every later step needs the configuration
fi
RECORDING_FILE="$ARTIFACTS_DIR/test-recording.$RECORDING_EXTENSION"
EXPECTED_FRAMES=$(( VERIFY_DURATION * FPS ))

# ---------------------------------------------------------------- DEPENDENCIES
MISSING=()
for cmd in gst-launch-1.0 gst-inspect-1.0 gst-discoverer-1.0 timeout cmake pkg-config; do
    command -v "$cmd" >/dev/null || MISSING+=("$cmd")
done
for element in videotestsrc videobalance timeoverlay tee queue videoconvert fakesink ximagesink \
               x264enc h264parse "$RECORDING_MUXER" filesink jpegenc rtpjpegpay udpsink \
               udpsrc rtpjitterbuffer rtpjpegdepay jpegdec videocrop \
               filesrc "$RECORDING_DEMUXER" avdec_h264; do
    gst-inspect-1.0 --exists "$element" 2>/dev/null || MISSING+=("$element")
done
if (( ${#MISSING[@]} == 0 )); then
    pass DEPENDENCIES "all commands and GStreamer elements found"
else
    failed DEPENDENCIES "missing: ${MISSING[*]}"
fi

# ---------------------------------------------------------------- REQUIRED_FILES
MISSING=()
for file in README.md architecture.md AI_USAGE.md CONTRIBUTIONS.md debug-report.md experiment.md \
            CMakeLists.txt "$TEAM_CONFIG_FILE" src/monitor_sender.cpp \
            scripts/build.sh scripts/clean.sh scripts/sender.sh scripts/receiver.sh \
            scripts/play-recording.sh scripts/run-experiment.sh scripts/verify.sh \
            evidence/pipeline.png evidence/measurements.csv "recordings/sample.$RECORDING_EXTENSION"; do
    [[ -s "$file" ]] || MISSING+=("$file")
done
if (( ${#MISSING[@]} == 0 )); then
    pass REQUIRED_FILES "all source and documentation files present"
else
    failed REQUIRED_FILES "missing or empty: ${MISSING[*]}"
fi

# ---------------------------------------------------------------- BUILD
# Normally built just before by scripts/build.sh; otherwise build it now
# (incremental, so cheap when the binary is already up to date).
if [[ ! -x "$BINARY" ]] || ! grep -q "Build OK" "$BUILD_LOG" 2>/dev/null; then
    log "No successful build found: running scripts/build.sh"
    timeout 300 scripts/build.sh >/dev/null 2>&1 || true
fi
if [[ -x "$BINARY" ]] && grep -q "Build OK" "$BUILD_LOG" 2>/dev/null; then
    pass BUILD "$BINARY built (see $BUILD_LOG)"
else
    failed BUILD "$BINARY missing or build failed (see $BUILD_LOG)"
    exit 1   # nothing else can run without the binary
fi

# ---------------------------------------------------------------- HELP_OPTION
set +e; HELP_TEXT=$(timeout "$STEP_TIMEOUT" "$BINARY" --help 2>&1); HELP_EXIT=$?; set -e
if (( HELP_EXIT == 0 )) && grep -q -- "--duration" <<<"$HELP_TEXT"; then
    pass HELP_OPTION "--help exits 0 and lists the options"
else
    failed HELP_OPTION "--help exit status $HELP_EXIT"
fi

# ---------------------------------------------------------------- INVALID_ARGUMENTS
# Each case changes one thing in an otherwise valid command (GOption keeps the
# last value of a repeated option). The documented status is 2.
SENDER_ARGS=(--pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" --fps "$FPS"
             --port "$PORT" --output "$RECORDING_FILE" --duration "$VERIFY_DURATION"
             --headless --overlay-position "$OVERLAY_POSITION")
REJECT_FAILURES=0
expect_rejected() {
    local label="$1" status
    shift
    set +e; timeout "$STEP_TIMEOUT" "$BINARY" "$@" >/dev/null 2>&1; status=$?; set -e
    if (( status == 2 )); then
        log "  rejected (status 2): $label"
    else
        log "  NOT rejected (status $status): $label"
        REJECT_FAILURES=$((REJECT_FAILURES + 1))
    fi
}
expect_rejected "no arguments"
expect_rejected "missing --output" --pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" \
                                   --fps "$FPS" --port "$PORT" --duration 1 --headless
expect_rejected "non-numeric --width"   "${SENDER_ARGS[@]}" --width abc
expect_rejected "unsupported --pattern" "${SENDER_ARGS[@]}" --pattern not-a-pattern
expect_rejected "--fps 0"               "${SENDER_ARGS[@]}" --fps 0
expect_rejected "unknown option"        "${SENDER_ARGS[@]}" --no-such-option
expect_rejected "unsupported --output format" "${SENDER_ARGS[@]}" --output "$ARTIFACTS_DIR/rejected.mp4"
expect_rejected "negative --duration"   "${SENDER_ARGS[@]}" --duration -1
rm -f "$RECORDING_FILE" "$ARTIFACTS_DIR/rejected.mp4"   # a rejected run must not create files, but be sure
if (( REJECT_FAILURES == 0 )); then
    pass INVALID_ARGUMENTS "8 invalid command lines rejected with status 2"
else
    failed INVALID_ARGUMENTS "$REJECT_FAILURES invalid command line(s) accepted"
fi

# ---------------------------------------------------------------- RECEIVER_START
RECEIVER_DURATION=$(( VERIFY_DURATION + RECEIVER_EXTRA ))
log "Starting receiver (test mode, ${RECEIVER_DURATION}s)"
timeout -s INT -k 10 $(( RECEIVER_DURATION + 15 )) \
    scripts/receiver.sh test --duration "$RECEIVER_DURATION" --log "$RECEIVER_LOG" &
RECEIVER_PID=$!
if wait_for_line "$RECEIVER_LOG" "Setting pipeline to PLAYING" 10 && kill -0 "$RECEIVER_PID" 2>/dev/null; then
    pass RECEIVER_START "receiver pipeline PLAYING on UDP port $PORT"
else
    failed RECEIVER_START "receiver did not reach PLAYING (see $RECEIVER_LOG)"
fi

# ---------------------------------------------------------------- SENDER_START
log "Starting sender: $BINARY ${SENDER_ARGS[*]}"
GST_DEBUG_DUMP_DOT_DIR="$ARTIFACTS_DIR" \
    timeout -s INT -k 10 $(( VERIFY_DURATION + 15 )) "$BINARY" "${SENDER_ARGS[@]}" > "$SENDER_LOG" 2>&1 &
SENDER_PID=$!
if wait_for_line "$SENDER_LOG" "^STATE_CHANGED PAUSED -> PLAYING" 10; then
    pass SENDER_START "native sender reached PLAYING"
else
    failed SENDER_START "sender did not reach PLAYING (see $SENDER_LOG)"
fi

# ---------------------------------------------------------------- wait for both
log "Waiting for the sender to stop by itself after ${VERIFY_DURATION}s (EOS)"
set +e; wait "$SENDER_PID"; SENDER_EXIT=$?; set -e
SENDER_PID=""
(( SENDER_EXIT != 124 )) || log "ERROR: sender timed out and had to be stopped"
set +e; wait "$RECEIVER_PID"; RECEIVER_EXIT=$?; set -e
RECEIVER_PID=""
(( RECEIVER_EXIT != 124 )) || log "ERROR: receiver timed out and had to be stopped"
log "Sender exit status $SENDER_EXIT, receiver exit status $RECEIVER_EXIT"

# ---------------------------------------------------------------- RTP_RECEPTION
RECEIVED_FRAMES=$(sed -n 's/^RECEIVED_FRAMES=\([0-9]*\)$/\1/p' "$RECEIVER_LOG" | tail -1)
RECEIVED_SIZE=$(sed -n 's/^RECEIVED_SIZE=//p' "$RECEIVER_LOG" | tail -1)
RECEIVED_FRAMES=${RECEIVED_FRAMES:-0}
# 50 %: tolerates some UDP loss on a loaded machine, but a broken stream gives 0.
if (( RECEIVED_FRAMES * 2 >= EXPECTED_FRAMES )) && [[ "$RECEIVED_SIZE" == "${WIDTH}x${HEIGHT}" ]]; then
    pass RTP_RECEPTION "$RECEIVED_FRAMES/$EXPECTED_FRAMES frames decoded at $RECEIVED_SIZE"
else
    failed RTP_RECEPTION "$RECEIVED_FRAMES/$EXPECTED_FRAMES frames at '${RECEIVED_SIZE:-none}' (need >= 50 % at ${WIDTH}x${HEIGHT})"
fi

# ---------------------------------------------------------------- RECORDING_CREATED
if [[ -s "$RECORDING_FILE" ]]; then
    pass RECORDING_CREATED "$RECORDING_FILE ($(stat -c %s "$RECORDING_FILE") bytes)"
else
    failed RECORDING_CREATED "$RECORDING_FILE missing or empty"
fi

# ---------------------------------------------------------------- RECORDING_DECODABLE
set +e
DISCOVERER_OUTPUT=$(timeout "$STEP_TIMEOUT" gst-discoverer-1.0 "$RECORDING_FILE" 2>&1); DISCOVERER_EXIT=$?
DECODE_OUTPUT=$(timeout 60 scripts/play-recording.sh "$RECORDING_FILE" --headless 2>&1); DECODE_EXIT=$?
set -e
echo "$DISCOVERER_OUTPUT"
DECODED_FRAMES=$(sed -n 's/^DECODED_FRAMES=//p' <<<"$DECODE_OUTPUT")
DECODED_FRAMES=${DECODED_FRAMES:-0}
# gst-discoverer exits 0 even on garbage (measured): require a video stream.
# Every source frame is recorded and a partial file decodes too, so the
# decoded count must be close to duration x fps, not just > 0.
if (( DISCOVERER_EXIT == 0 && DECODE_EXIT == 0 && DECODED_FRAMES * 10 >= EXPECTED_FRAMES * 9 )) \
   && grep -q "video #" <<<"$DISCOVERER_OUTPUT"; then
    pass RECORDING_DECODABLE "gst-discoverer OK, $DECODED_FRAMES/$EXPECTED_FRAMES frames decoded"
else
    failed RECORDING_DECODABLE "discoverer status $DISCOVERER_EXIT, decode status $DECODE_EXIT, $DECODED_FRAMES/$EXPECTED_FRAMES frames (need >= 90 %)"
fi

# ---------------------------------------------------------------- EOS_HANDLING
# EOS must have gone through the pipeline AND finalized the file. A recording
# stopped without EOS still decodes, but its duration is only estimated and
# Matroska has no Cues index at the end (measured, see debug-report.md).
RECORDED_DURATION=$(sed -n 's/^ *Duration: //p' <<<"$DISCOVERER_OUTPUT" | head -1 \
                    | awk -F: '{ printf "%.3f", $1 * 3600 + $2 * 60 + $3 }')
DURATION_OK=$(awk -v d="${RECORDED_DURATION:-0}" -v e="$VERIFY_DURATION" \
              'BEGIN { print (d - e <= 0.5 && e - d <= 0.5) ? "yes" : "no" }')
INDEX_OK=yes
if [[ "$CONTAINER" == matroska ]]; then
    tail -c 65536 "$RECORDING_FILE" 2>/dev/null | LC_ALL=C grep -qaP '\x1C\x53\xBB\x6B' || INDEX_OK=no
fi
if grep -q "^EOS_SENT" "$SENDER_LOG" && grep -q "^EOS_RECEIVED" "$SENDER_LOG" \
   && [[ "$DURATION_OK" == yes && "$INDEX_OK" == yes ]]; then
    pass EOS_HANDLING "EOS sent and received, file finalized (${RECORDED_DURATION}s, index present)"
else
    failed EOS_HANDLING "EOS_SENT/EOS_RECEIVED in log: $(grep -cE '^EOS_(SENT|RECEIVED)' "$SENDER_LOG")/2, duration ${RECORDED_DURATION:-?}s (expected ${VERIFY_DURATION}±0.5), index: $INDEX_OK"
fi

# ---------------------------------------------------------------- CLEAN_TERMINATION
# Anchored on the start of the real command lines, so that an editor or a
# shell whose command line merely mentions these words is not counted.
LEFTOVER=$(pgrep -f "^$BINARY |^gst-launch-1.0 .*udpsrc port=$PORT " || true)
if (( SENDER_EXIT == 0 && RECEIVER_EXIT == 0 )) && grep -q "^EXIT status=success" "$SENDER_LOG" \
   && [[ -z "$LEFTOVER" ]]; then
    pass CLEAN_TERMINATION "sender and receiver exited 0 on their own, no process left"
else
    failed CLEAN_TERMINATION "sender status $SENDER_EXIT, receiver status $RECEIVER_EXIT, leftover pids: ${LEFTOVER:-none}"
fi

# ---------------------------------------------------------------- DYNAMIC_PROPERTY
DYNAMIC_COUNT=$(grep -cE '^DYNAMIC_PROPERTY element=[^ ]+ property=[^ ]+ value=[^ ]+$' "$SENDER_LOG" || true)
if (( DYNAMIC_COUNT >= 2 )); then
    pass DYNAMIC_PROPERTY "$DYNAMIC_COUNT changes logged ($(grep -m1 '^DYNAMIC_PROPERTY' "$SENDER_LOG"))"
else
    failed DYNAMIC_PROPERTY "$DYNAMIC_COUNT DYNAMIC_PROPERTY line(s) in $SENDER_LOG (need >= 2)"
fi

# ---------------------------------------------------------------- pipeline graph
DOT_FILE="$ARTIFACTS_DIR/monitor_sender_playing.dot"
if [[ -s "$DOT_FILE" ]] && command -v dot >/dev/null; then
    dot -Tpng "$DOT_FILE" -o "$ARTIFACTS_DIR/pipeline.png" && log "Pipeline graph: $ARTIFACTS_DIR/pipeline.png"
else
    log "Pipeline graph not generated (DOT file or 'dot' command missing)"
fi

log "Verification finished"
