# AI usage disclosure

## 1. AI tools used

- **Claude Code** (Anthropic, Claude Opus model), used inside VS Code. It had
  access to the project folder and could run commands in the course Docker
  container.

No other AI tool was used.

## 2. Team member(s) using each tool

- **Lorenzo Bravard** (solo team): all AI interactions.

## 3. Purpose of use

The assistant was used throughout the project, step by step:

- **Understanding and planning**: reading the assignment PDF, listing every
  requirement and the grading priorities. It wrote a plan, then compared it
  page by page with the assignment; 9 gaps were found and fixed before any
  code was written.
- **Building and testing pipelines**: proposing `gst-launch-1.0` pipelines brick
  by brick and running them in the container. It read the caps (`-v`) and the
  `GST_DEBUG` logs, and took screenshots of the virtual desktop to check the
  windows.
- **Writing code**: the shell scripts, `monitor_sender.cpp` and
  `CMakeLists.txt`, each tested before moving on.
- **Diagnosis and measurements**: the UDP loss investigation, the EOS
  finalization analysis, and the experiment script and its measurements.
- **Writing documentation**: first drafts of the reports, based only on the
  measurements made in the project.

Working rules set by the student and followed throughout:

- the assistant never ran `git add`, `git commit` or `git push`: it gave the
  commands, and Lorenzo ran them after checking;
- no unnecessary file was added to the repository;
- every notable AI suggestion or error was logged in a journal (appended
  below).

## 4. Representative prompts

Quoted exactly (in French, as typed), with a translation:

1. > « passe au plan et prend autant de temps que tu veux mais je veux vraiment
   > quil corresponde a 100% a ce qui attendu. A la fin du plan tu me fera une
   > comparaison entre le plane t les attendu et si il y a des probleme tu
   > modifiera le plan »

   *"Move on to the plan and take as much time as you want, but I really want
   it to match the requirements 100%. At the end, compare the plan with the
   requirements, and if there are problems, change the plan."*
   This produced the page-by-page comparison and 9 corrections to the plan
   (for example, deriving the recording extension from `CONTAINER`, and
   negative tests for `verify.sh`).

2. > « okay par contre on va se mettre une autre regle il ne faudra jamais
   > ajouter de .md qui ne sont aps necessaire et pas demander comme le plan ou
   > le tuto dans le repo. Et des que tu fera suelque chose quon aura test et
   > qui fonctionne tu ne commitera et push jamais tu me dira juste les
   > commandes pour add et commit sur le repo je veux que ça soit moi qui le
   > fasse. […] »

   *"New rule: never add unnecessary or unrequested .md files (like the plan or
   the tutorial) to the repository. And whenever something is tested and
   works, never commit or push yourself; just give me the add and commit
   commands, I want to do it myself."*

3. > « brique par brique »

   *"Brick by brick."* This was the answer when the assistant offered to test
   the whole pipeline at once. Each element was then added and checked
   separately, which is how the I420 caps problem and the 544-line receiver
   output were isolated.

4. > « je commit pas encore fais letape 6 avant »

   *"I'm not committing yet, do step 6 first."* The verification script was
   finished and tested, including the negative tests, before anything from
   steps 5 and 6 was committed.

## 5. Important suggestions retained

- Force `format=I420` before the tee: without it, `rtpjpegpay` rejects every
  frame (`Invalid component`).
- Crop the receiver output with `videocrop`, computed from `team.conf`:
  RFC 2435 sizes are multiples of 8, so 540 lines become 544.
- Ask `udpsrc` for `buffer-size = rmem_max`, read at run time, and use JPEG
  quality 30 by default. Both were measured: 0/150 frames before, 150/150
  after.
- Stop every run through EOS (`gst-launch-1.0 -e` + `timeout --foreground -s INT`,
  and EOS on duration/SIGINT/SIGTERM in `monitor_sender`), with a watchdog.
- In `verify.sh`, check the EOS **finalization** (duration within ±0.5 s and
  Matroska Cues index at the end of the file), not only that the file
  decodes; require ≥ 90 % of the expected frames decoded; and prove every FAIL
  with sabotage tests.
- Use the kernel `RcvbufErrors` counter as direct evidence in the debug
  report, and SSIM (GStreamer `compare`) to quantify the image-quality side of
  the experiment.

## 6. Important suggestions rejected or corrected

- **`x-dimensions` in the receiver caps** to fix the 544-line output:
  rejected, because it had no effect. Replaced with `videocrop`.
- **`autovideosink`** for the preview: corrected, because it stayed in PAUSED
  under Xvfb. Replaced with `ximagesink handle-events=false`.
- **"`buffer-size` does not help"**: corrected. This was concluded from a
  single run. Repeated runs showed that requesting `rmem_max` doubles the
  buffer and removes the loss at moderate quality.
- **`timeout` without `--foreground`** in the scripts: corrected, because Ctrl+C
  typed in a real terminal was ignored.
- **`g_timeout_add_seconds()`** for `--duration`: corrected, because the
  recordings lasted 9.8 to 10.7 s for 10 s. Replaced with a millisecond timer.
- **`pgrep -f` with loose patterns** and **trusting the exit status of
  `gst-discoverer-1.0`** in `verify.sh`: corrected. The first gave a false
  FAIL; the second returns 0 even on random bytes.

## 7. Limitations or technical errors found in AI responses

The full list is in the journal below. The most significant ones:

1. **Wrong claim about a recording without EOS.** The assistant stated that a
   Matroska file without EOS would be undecodable and caught by the
   decodability check. Measurement showed the opposite: the file decodes
   fully, but its duration is only estimated, and the Cues index and the tags
   are missing. The verification design was changed accordingly
   (`EOS_HANDLING` checks the finalization).
2. **A negative test that proved nothing.** The first batch of sabotage runs
   all produced FAIL, and the assistant was about to present this as proof.
   On inspection, every run had stopped at the `BUILD` step, because the test
   copy had no build log, so the FAILs came from the wrong reason. The tests
   were redone with a control run.
3. **A leak check that proved nothing.** `GST_TRACERS=leaks` reported nothing
   only because the tracer reports at `gst_deinit()`, which was not called.
   After the fix, a deliberately leaking build (64 objects) proved that the
   check works.
4. **Statements not backed by measurements** in a report draft ("8×8 blocks
   visible", "frames lost in groups"). They were removed on review.

The common pattern: the assistant's explanations were often plausible but
wrong in a detail. Single runs and checks that "pass" can mislead.

## 8. Tests used to validate the final solution

- `./scripts/clean.sh && ./scripts/build.sh && ./scripts/verify.sh`, run
  twice in a row (about 25 s each).
- 6 sabotages plus 1 control run of `verify.sh`, each failing only its own key:
  - wrong receiver port: `RTP_RECEPTION`;
  - SIGKILL without EOS: `EOS_HANDLING`;
  - random bytes instead of the recording: `RECORDING_DECODABLE`;
  - hidden logs: `DYNAMIC_PROPERTY`;
  - no `team.conf`: `CONFIG`;
  - broken code: `BUILD`.
- Ctrl+C sent through a real pseudo-terminal to `sender.sh`, `receiver.sh`,
  `monitor_sender` and `verify.sh`: clean EOS, no process left.
- `monitor_sender`: 13 argument cases (status 0/2); `GST_TRACERS=leaks` (0
  objects left); compiled with `-Wall -Wextra` (0 warnings).
- The recording checked with `gst-discoverer-1.0` and decoded frame by frame
  (`recordings/sample.mkv`: 90.000 s, 1350/1350 frames).
- Debug report: the fault reproduced with the final scripts, and the
  reproduction commands run exactly as written.
- Experiment: 3 × 60 s per configuration, alternated, all values in
  `evidence/measurements.csv`.

## 9. What I learned

- **GStreamer**:
  - caps negotiation picks a format that every downstream element accepts,
    and it is not always the one you expect;
  - `tee` needs a `queue` per branch;
  - live and non-live sources behave differently in PAUSED;
  - EOS is what turns a stream of clusters into a finalized, seekable file.
- **Networking**: UDP loss can be completely silent in the application. The
  evidence was in a kernel counter, not in GStreamer's logs. The size of one
  frame compared with the socket buffer explained everything.
- **Working with an AI assistant**: it is very fast at producing pipelines,
  scripts and drafts, but many of its first answers were wrong in a detail
  that only a measurement revealed. I learned to:
  - ask for every claim to be tested in the container;
  - repeat measurements before concluding;
  - prove that a check can fail before trusting a PASS;
  - keep a journal of what was corrected.

---

## Appendix: AI usage journal

Kept during the project, one row per notable interaction. Rows are in
chronological order; a later row can correct an earlier one (for example,
the `buffer-size` conclusion on row 5 is corrected on row 9).

| # | Purpose | What the AI proposed | Outcome | How it was checked |
|---|---|---|---|---|
| 1 | Read the assignment PDF and list the requirements | Requirement list, grading priorities, repository structure | Retained, then compared page by page with the assignment | Manual re-reading of the PDF |
| 2 | Plan the project | Step-by-step plan; a page-by-page comparison with the assignment revealed 9 gaps, which were fixed in the plan | Retained | Comparison table against pages 4–68 |
| 3 | Test the network branch with the team configuration | Without a forced format, `videotestsrc pattern=snow` negotiates Y444 and `rtpjpegpay` rejects it (`Invalid component`): force `format=I420` | Retained | `gst-launch-1.0 -v` caps output |
| 4 | Fix the 960×544 output of the receiver | Use `x-dimensions` in the receiver caps | **Rejected**: no effect (still 544 lines) → `videocrop bottom=4` | `gst-launch-1.0 -v`, caps of `rtpjpegdepay` |
| 5 | Fix 0 decoded frames with the snow pattern | Increase the `udpsrc buffer-size` | **Rejected** at first: believed to be capped by the kernel (`rmem_max` = 212992, no NET_ADMIN in the container) → lower JPEG quality (15). *Corrected later, see row 9.* | `GST_DEBUG=udpsrc:4`, measurement of the quality threshold (q5–q25) |
| 6 | Display sink in the virtual desktop | Use `autovideosink` | **Corrected**: blocks in PAUSED on Xvfb → `ximagesink handle-events=false` | Screenshot of the virtual desktop with `ximagesrc` |
| 7 | Container restart | — (problem found while testing) | Stale `/tmp/.X0-lock` prevented Xvfb from starting → lock removed in `start-desktop.sh` | `/tmp/desktop.log` |
| 8 | Explain what happens to a Matroska file recorded without EOS | Claimed the file would have no/incorrect duration and be "not seekable", and that `RECORDING_DECODABLE` would detect it | **Corrected**: the file still decodes fully (150/150 frames) and gst-discoverer accepts it (estimated duration 9.005 s instead of 10.000 s); what is missing is the finalization (unknown segment size, no Cues index, no Duration, no Tags). The verification was changed: finalization is checked by `EOS_HANDLING` | gst-discoverer on both files + Matroska (EBML) structure parsed with a short Python script |
| 9 | Re-test of the UDP loss with repeated runs | Earlier conclusion: "increasing `buffer-size` does not help, it is capped by rmem_max" | **Corrected**: with 3–5 repetitions, requesting `buffer-size` gives 54–61/90 frames at q85 (vs 0/90) and makes q25/q35 loss-free. Requesting exactly rmem_max (212 992) doubles the buffer seen by GStreamer (106 496 by default) without any warning. A single earlier run had been over-interpreted | Repeated sender/receiver runs, `GST_DEBUG=udpsrc:4` |
| 10 | Make `sender.sh` stop after a duration | `timeout --preserve-status -s INT N gst-launch-1.0 -e …` | **Corrected**: with a real terminal, Ctrl+C was ignored (timeout puts the command in its own process group) → `timeout --foreground`. A first artificial test (signals sent by hand) gave a misleading result; only the pseudo-terminal test reproduced the real behaviour | Python pty sending Ctrl+C: 3/3 clean EOS after the fix |
| 11 | `receiver.sh` test mode without any sender | Generated script exited silently (no summary, no message) when no frame was received | **Corrected**: `grep` with no match inside `$(...)` + `set -euo pipefail` aborted the script → `\|\| true` added | Run without sender: summary + explicit ERROR, exit 1 |
| 12 | `monitor_sender`: stop after `--duration` | Used `g_timeout_add_seconds()` for the duration timer | **Corrected**: recordings lasted 9.8–10.7 s for 10 s (GLib aligns these timers to whole seconds) → `g_timeout_add(ms)`; now 10.07 s / 151 frames on 3 runs | Timestamps of `EOS_SENT` + gst-discoverer + decoded frame count |
| 13 | `monitor_sender`: error reporting | When `set_state(PLAYING)` failed, only "refused to go to PLAYING" was printed, without the element name required by the subject | **Corrected**: the pending ERROR is popped from the bus and printed (`preview_sink: Could not initialise X output`, `rec_sink: Could not open file`) | Runs without DISPLAY and with an invalid output directory |
| 14 | `monitor_sender`: memory leak check | First leak check with `GST_TRACERS=leaks` reported nothing, which proved nothing: the tracer only reports at `gst_deinit()`, which was not called | **Corrected**: `gst_deinit()` added, then the check was validated with a deliberately leaking build (64 objects alive) vs the real build (0) | `GST_TRACERS=leaks GST_DEBUG=GST_TRACER:7` on both builds |
| 15 | `build.sh` / `clean.sh` + first run after a clean | Generated `monitor_sender` assumed the output folder existed | **Corrected**: right after `clean.sh`, `artifacts/` is gone and `--output artifacts/x.mkv` failed → `g_mkdir_with_parents()` on the output folder, with an explicit error if it cannot be created | clean → build → run with `artifacts/sub/s.mkv` (45/45 frames), and with an impossible path (exit 1) |
| 16 | `verify.sh`: proving that each FAIL is real (negative tests) | First batch of sabotage runs all gave the expected FAIL keys, and the AI was about to report them as proof | **Corrected**: every run had actually stopped at `BUILD` (the test copy had no `artifacts/build.log`), so the FAILs came from the wrong reason. Re-run on fresh copies built first, with a no-sabotage control run: each sabotage now fails exactly its own check | Control run + 6 sabotages |
| 17 | `verify.sh`: leftover process check | Loose `pgrep -f` patterns | **Corrected**: matched any command line containing these words (the test shell; an editor or `watch` on the teacher side) → false CLEAN_TERMINATION=FAIL in the control run. Patterns anchored on the start of the real command lines | Control run PASS, SIGKILL sabotage still FAIL |
| 18 | `verify.sh`: recording decodability | Relied on the exit status of `gst-discoverer-1.0` | **Corrected**: exit status 0 measured on a file of random bytes ("Could not determine type of stream") → also require a `video #` stream in its output, plus ≥ 90 % of the expected frames decoded | Random-bytes sabotage |
| 19 | `verify.sh`: console/log output | `exec > >(tee -a verification.log)` | **Corrected** twice: (1) the script returned before tee finished, so the end of the output could appear after the prompt and the log could be truncated → close the pipe and `wait` for tee in the EXIT trap; (2) Ctrl+C also killed tee, so the summary was never shown → tee ignores SIGINT | Output line counts; real Ctrl+C through a pty after 10 s |
| 20 | Write `debug-report.md` | Re-measure with the final repository scripts instead of reusing early numbers, and add the kernel counter `RcvbufErrors` as direct evidence of the drops | **Kept**: +11 000–13 000 drops at q85 with the default buffer, +0 with the fix at q30. The reproduction commands were run exactly as written (1 frame / 12 049 drops vs 150/150) | 2 runs × 5 configurations |
| 21 | Experiment q30 vs q85 | Measure image quality with GStreamer's `compare method=ssim` element | **Kept** after a sanity check: identical frames give 1.0, and the value increases with quality (0.948 / 0.979 / 0.998 / 0.9995 at q30/50/85/95) | 3 × 60 s per configuration, alternated |
| 22 | `run-experiment.sh`: CPU column | Parsed the pidstat "Average" line with an index shifted by one column → CPU = 0.00 % in the first test run | **Corrected**: "Average:" takes the time column's place (real value 25.4 %) | Re-parse of the saved pidstat logs |
| 23 | `experiment.md` draft | Draft contained two statements that were not measured ("8×8 blocks visible at q30", "frames lost in groups") | **Corrected** on review: replaced by what the measurements show (SSIM, loss rate) | Re-read against `evidence/measurements.csv` |
