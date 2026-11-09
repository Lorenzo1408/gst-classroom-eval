# GStreamer Video Monitoring System

## Quick evaluation

Run inside the course GStreamer environment (see [Environment](#environment):
GitHub Codespaces, or the provided Docker container):

```bash
git clone https://github.com/Lorenzo1408/gst-classroom-eval.git
cd gst-classroom-eval
./scripts/clean.sh
./scripts/build.sh
./scripts/verify.sh
```

Expected result: the last line printed is `OVERALL=PASS`, and the exit status
is 0. The detailed results are in `artifacts/verification-summary.txt`.
`verify.sh` runs the real receiver and the real native sender for 15 s, then
checks:

- the RTP reception;
- the recording (decoded frame by frame);
- the EOS finalization;
- the clean termination.

It stops every process it started, and it can be run again immediately.

## Team

| Member | Role |
|---|---|
| **Lorenzo Bravard** | Solo team: all parts (see [CONTRIBUTIONS.md](CONTRIBUTIONS.md)) |

## Assigned configuration

Team 3, in [`config/team.conf`](config/team.conf). All scripts read this file:
no value is hard-coded elsewhere.

| Key | Value |
|---|---|
| `PATTERN` | `snow` |
| `WIDTH` × `HEIGHT` | 960 × 540 |
| `FPS` | 15 |
| `PORT` | 5103 (UDP, 127.0.0.1) |
| `OVERLAY_POSITION` | `bottom-right` |
| `CONTAINER` | `matroska` (`.mkv`) |
| `NETWORK_CODEC` | `jpeg` (RTP/JPEG, payload type 26) |
| `RUNTIME` | 90 s (normal run; `verify.sh` uses 15 s) |

## Environment

Everything runs in the course image (GStreamer with the base, good, bad,
ugly and libav plugins, plus a virtual desktop). It is defined in
[`environment/Dockerfile`](environment/Dockerfile).

- **GitHub Codespaces** (recommended): *Code → Codespaces → Create codespace
  on main*. The container is built from `.devcontainer/devcontainer.json`, and
  the terminal opens in the repository. The virtual desktop is forwarded on
  port **6080** ("Ports" tab, then open in browser).
- **Local Docker** (Linux, macOS or Windows with Docker Desktop):
  ```bash
  docker compose -f environment/docker-compose.yml up -d --build
  docker compose -f environment/docker-compose.yml exec classroom bash
  cd /workspace        # the repository, mounted in the container
  ```
  Virtual desktop: <http://localhost:6080>.

**Dependencies** (all provided by the image; `verify.sh` checks them first):

- tools: `cmake`, a C++17 compiler, `pkg-config`, the GStreamer 1.x
  development files (`gstreamer-1.0`), `gst-launch-1.0`, `gst-inspect-1.0`,
  `gst-discoverer-1.0` and `timeout`;
- GStreamer elements: `videotestsrc`, `videobalance`, `timeoverlay`, `tee`,
  `queue`, `x264enc`, `h264parse`, `matroskamux`/`matroskademux`, `jpegenc`/`jpegdec`,
  `rtpjpegpay`/`rtpjpegdepay`, `rtpjitterbuffer`, `udpsink`/`udpsrc`,
  `videocrop`, `avdec_h264`, `ximagesink`;
- optional: `dot` (Graphviz) to convert the pipeline graph, and `pidstat`
  (sysstat) for the experiment.

## Expected times

| Step | Time |
|---|---|
| First build of the container image (Codespaces or Docker) | about 3 min |
| `./scripts/build.sh` (CMake, a single source file) | under 10 s (0.6 s measured) |
| `./scripts/verify.sh` | about 25 s (22 s measured) |
| `./scripts/run-experiment.sh` (3 × 60 s per configuration) | about 8 min |

## Generated artifacts

Only `build/` and `artifacts/` receive generated files. Both are ignored by
git and removed by `./scripts/clean.sh`.

| Path | Content |
|---|---|
| `build/monitor_sender` | native sender |
| `artifacts/build.log` | build output |
| `artifacts/sender.log`, `artifacts/receiver.log` | logs of the verification run |
| `artifacts/verification.log`, `artifacts/verification-summary.txt` | verification output and `KEY=PASS/FAIL` summary |
| `artifacts/test-recording.mkv` | recording made during the verification |
| `artifacts/pipeline.png` | graph of the running pipeline (from `GST_DEBUG_DUMP_DOT_DIR`) |
| `artifacts/measurements.csv`, `artifacts/experiment/` | output of `run-experiment.sh` |

The committed evidence is in `evidence/`: the pipeline graph and the
experiment measurements. The 90 s sample recording is
`recordings/sample.mkv`.

## Graphical preview (sender)

Open the virtual desktop (port 6080), then run either version of the sender:

```bash
./build/monitor_sender --pattern snow --width 960 --height 540 --fps 15 --port 5103 \
    --output artifacts/run.mkv --duration 90        # native application
./scripts/sender.sh                                  # gst-launch version (values from team.conf)
```

The preview window shows the snow pattern with the overlay
`Lorenzo Bravard | 960x540 @ 15 fps | <time>` in the bottom-right corner. Both
stop cleanly (EOS) after the duration or on Ctrl+C. Add `--headless` to replace
the window with `fakesink`.

## Graphical network receiver

Start the receiver first, then the sender in a second terminal:

```bash
./scripts/receiver.sh display                     # window with the received stream (Ctrl+C to stop)
./scripts/sender.sh --headless --duration 30      # second terminal
```

`./scripts/receiver.sh test --duration 30` decodes without a window. It prints
`RECEIVED_FRAMES=<n>` and `RECEIVED_SIZE=960x540`.

## Playing the recording

```bash
./scripts/play-recording.sh                       # recordings/sample.mkv in a window
./scripts/play-recording.sh artifacts/test-recording.mkv
./scripts/play-recording.sh --headless            # decode only, prints DECODED_FRAMES=<n>
```

Pipeline: `filesrc ! matroskademux ! h264parse ! avdec_h264 ! videoconvert ! ximagesink`.
Equivalent one-liner: `gst-play-1.0 recordings/sample.mkv`.

## Native application

```
build/monitor_sender --pattern NAME --width W --height H --fps FPS --port PORT
                     --output FILE.mkv|.ts --duration SECONDS
                     [--headless] [--jpeg-quality 1-100] [--overlay-position POS] [--help]
```

- All options except the last three are required. Invalid, missing or
  unsupported values are rejected with exit status **2**. A runtime error
  (for example a bus ERROR, reported with the element name and the debug
  information) gives status **1**. Success gives **0**.
- `--duration 0` runs until Ctrl+C. In every case the application sends EOS,
  waits for it on the bus, sets the pipeline to NULL and releases everything.
- **Dynamic property**: every 5 s, the `brightness` property of the element
  named **`video_balance`** (`videobalance`) cycles through 0.20, 0.00, −0.20
  and 0.00, while the pipeline keeps playing. Each change is logged, also in
  headless mode:
  ```
  DYNAMIC_PROPERTY element=video_balance property=brightness value=0.20
  ```
- Other log lines: `CONFIG ...`, `STATE_CHANGED`, `EOS_SENT reason=...`,
  `EOS_RECEIVED`, `NETWORK_BYTES_SENT=<n>`, `EXIT status=...`.

## Documentation

| File | Content |
|---|---|
| [architecture.md](architecture.md) | pipeline diagram, caps, queues, receiver, EOS finalization, normal vs test mode, `gst_parse_launch` choice |
| [debug-report.md](debug-report.md) | investigation of a silent RTP/UDP loss (root cause, evidence, reproduction) |
| [experiment.md](experiment.md) | controlled comparison: network JPEG quality 30 vs 85 |
| [CONTRIBUTIONS.md](CONTRIBUTIONS.md) | work done and self-review (solo team) |
| [AI_USAGE.md](AI_USAGE.md) | AI tools, prompts, corrected errors, validation |

## Known limitations

- **UDP receive buffer**: without privileges the receiver cannot use more
  than `net.core.rmem_max` (212 992 bytes in the course container). Snow
  frames are large, so the network JPEG quality is 30 by default. At quality
  85, about a third of the frames are lost (see `experiment.md`).
  `--jpeg-quality` lets you raise it when the receive path allows.
- **Loss tolerance in `verify.sh`**: `RTP_RECEPTION` passes from 50 % of the
  expected frames, so that a heavily loaded machine does not fail
  needlessly. On our machine 100 % are received.
- **Image quality**: JPEG at quality 30 loses fine detail (SSIM 0.95 on snow).
- **RTP/JPEG sizes** are transmitted in units of 8 pixels. The receiver crops
  the padding (540 → 544 → 540). This crop is computed from `team.conf`.
- **Local only**: the stream is sent to 127.0.0.1. The receiver has no
  security, and RTP over UDP has no retransmission.
- **Display**: the preview and the receiver window use `ximagesink`, which
  needs an X display (the virtual desktop). Without one, use `--headless` or
  `receiver.sh test`.
- **Test environment**: developed and verified in the course image on Apple
  Silicon (aarch64, GStreamer 1.24.2). Codespaces runs on x86_64 with the same
  image definition.
