# Contributions

## Team members

| Name | Role |
|---|---|
| **Lorenzo Bravard** | Solo team: all parts of the assignment |

This team has **one member**. All the work below (design, code, tests,
measurements, documentation) was done by Lorenzo Bravard. An AI assistant
(Claude Code) was used throughout; what it did, and what was checked or
corrected, is described in [AI_USAGE.md](AI_USAGE.md).

## Contributions

| Part | Work | Main files |
|---|---|---|
| Environment | Trimmed version of the course image, a Codespaces devcontainer and a Docker Compose alternative; fix for a stale X lock that blocked the virtual desktop after a restart | `environment/`, `.devcontainer/` |
| Pipeline architecture | Three-branch pipeline validated element by element with `gst-launch-1.0`: caps before the tee (I420), placement and settings of the queues, overlay | `scripts/sender.sh`, `architecture.md` |
| Network and receiver | RTP/JPEG sender branch; receiver with display and test modes; crop of the RFC 2435 8-pixel padding; UDP receive buffer | `scripts/receiver.sh` |
| Recording and playback | H.264/Matroska branch, EOS finalization, playback and headless decoding | `scripts/play-recording.sh`, `recordings/sample.mkv` |
| Native application | `monitor_sender` in C++: option parsing and validation, `gst_parse_launch`, bus watch, EOS on duration/SIGINT/SIGTERM with a watchdog, dynamic brightness, byte counter, DOT graph | `src/monitor_sender.cpp`, `CMakeLists.txt` |
| Automated verification | Build and clean scripts; `verify.sh` with real checks, timeouts and cleanup trap | `scripts/build.sh`, `scripts/clean.sh`, `scripts/verify.sh` |
| Debugging | Investigation of the silent loss of RTP/JPEG frames (UDP receive buffer) | `debug-report.md` |
| Experiment | JPEG quality 30 vs 85, 3 × 60 s per configuration | `scripts/run-experiment.sh`, `evidence/measurements.csv`, `experiment.md` |
| Documentation | README, architecture, this file, AI disclosure | `*.md` |

## Parts developed collaboratively

None between team members (solo team). The work was done with an AI
assistant, interactively. Every suggestion was run and checked in the
container before being kept (see AI_USAGE.md, sections 5 to 8).

## Tests performed

All tests were performed by Lorenzo Bravard, inside the course container.

| Component | Tests |
|---|---|
| Pipeline bricks | Each element added one at a time with `gst-launch-1.0 -v`. Caps checked at every stage. Deadlock reproduced with a `tee` without queues. |
| `sender.sh` | Help and invalid arguments; headless run of 10 s (150/150 frames, a 10.0 s file); preview visible in the virtual desktop; real Ctrl+C sent through a pseudo-terminal (3/3 clean EOS) |
| `receiver.sh` | Test mode: 150/150 frames at 960x540. Without a sender: explicit error and status 1. Display mode checked on a screenshot. Ctrl+C gives EOS and status 0. |
| `play-recording.sh` | 150/150 decoded frames. A fake `.mkv` file is rejected. A truncated file decodes partly, which led to the frame-count check in `verify.sh`. |
| `monitor_sender` | 13 option cases (valid and invalid, status 0/2). Three 10 s runs: 151 frames, 10.07 s each. SIGTERM and Ctrl+C give EOS and status 0. Errors without a display or with an invalid output folder name the element. `GST_TRACERS=leaks`: 0 objects left alive, against 64 for a build that deliberately leaks. |
| Load | Full pipeline at q30/40/50/60/70/85 (45 s and 20 s runs) to choose the default quality |
| `verify.sh` | `clean → build → verify` twice in a row; Ctrl+C in the middle of a run; one control run plus 6 sabotages, each detected by its own key: wrong receiver port, sender killed without EOS, recording replaced with random bytes, hidden `DYNAMIC_PROPERTY` lines, missing `team.conf`, broken build |
| Debug report | Fault reproduced with the final scripts: 2 runs of 5 configurations, plus the reproduction commands run exactly as written |

## Review

The subject asks for a collective review. With a single member, it was
replaced by a **systematic self-review**, done for each component before it
was committed:

| Component | Reviewed by | How |
|---|---|---|
| Pipeline and scripts | Lorenzo Bravard | Re-reading against the subject requirements; every script run from another directory and with invalid arguments |
| `monitor_sender` | Lorenzo Bravard | Line-by-line reading of the code; compiled with `-Wall -Wextra` (0 warnings); leak tracer, with a sabotaged build to prove that the check works |
| `verify.sh` | Lorenzo Bravard | Negative tests: each key must be able to report FAIL for the right reason. A first batch of sabotages was found to fail at `BUILD` for every case and was redone with a control run. |
| Reports | Lorenzo Bravard | Every number checked against `evidence/measurements.csv` or a re-run; statements that had not been measured were removed |
| AI suggestions | Lorenzo Bravard | Nothing kept without a test in the container; errors logged in AI_USAGE.md |

The work was committed in small, tested steps (see `git log`). Each step was
verified before its commit.
