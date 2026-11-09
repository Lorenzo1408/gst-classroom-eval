# Engineering experiment — network JPEG quality 30 vs 85

## Question

For our monitoring stream (`snow`, 960x540, 15 fps, RTP/JPEG over UDP), how
does the network JPEG quality affect the **reliability of the live stream**
(frames that actually reach the operator), the **network data rate**, the
**CPU cost** and the **image quality**?

## Hypothesis

Snow is almost incompressible, so each JPEG frame is large and is sent as a
burst of RTP packets. Our hypothesis:

- quality 85 roughly doubles the frame size compared to quality 30;
- the doubled bursts overflow the receiver's UDP buffer, so whole frames are
  lost (see `debug-report.md`);
- quality 30 delivers every frame, at the price of a visibly lower image
  quality;
- CPU usage hardly depends on the quality setting, because the cost of JPEG
  encoding is dominated by the DCT, not by quantization.

## The two configurations

| | Configuration A | Configuration B |
|---|---|---|
| `--jpeg-quality` (`jpegenc quality`) | **30** (project default) | **85** |

This is the only principal variable that changes.

## Controlled variables

- **Sender**: the native sender `build/monitor_sender` in headless mode, with
  the full 3-branch pipeline (preview on `fakesink sync=true`, H.264 recording,
  RTP/JPEG). All other values come from `config/team.conf`: snow, 960x540,
  15 fps, port 5103, overlay bottom-right, Matroska.
- **Receiver**: `scripts/receiver.sh test`, with the same receive buffer in
  both cases, `buffer-size` = `net.core.rmem_max` = 212 992 bytes, the same
  `rtpjitterbuffer latency=200`, and decoding to `fakesink`.
- **Run length**: 60 s per run (at least 45 s required), **3 runs per
  configuration**, alternated (A, B, A, B, A, B) so that a slow drift of the
  machine load affects both configurations the same way.
- **Machine**: the same container (GStreamer 1.24.2, 10 CPUs, loopback
  interface), with no other workload.
- **Recording branch**: x264 at 1500 kbit/s in both cases. The recording size
  is measured as a check: it must not change.

## Measurement method

Everything is done by `scripts/run-experiment.sh` (default: 3 runs × 60 s per
configuration). It writes one CSV line per run to
`evidence/measurements.csv`.

| Measurement | How |
|---|---|
| Frames produced | frames decoded from that run's recording (`play-recording.sh --headless`). The source feeds both branches, so this is the number of frames offered to the network branch. |
| Frames received | `RECEIVED_FRAMES` from the receiver (one `fakesink` buffer per **fully decoded** frame) |
| Frame loss | `(produced − received) / produced` |
| Kernel UDP drops | change of the `RcvbufErrors` counter (`/proc/net/snmp`) during the run |
| Network data rate | `NETWORK_BYTES_SENT` (the `bytes-served` property of `udpsink`, printed by the sender at EOS) × 8 / duration |
| CPU | `pidstat -p <pid> 1 60`, "Average" %CPU of the sender process and of the receiver's `gst-launch-1.0` process (100 % = one core) |
| Recording size | size of the `.mkv` file, as a control |
| Warnings | `WARNING` lines in the sender and receiver logs |
| Image quality | mean **SSIM** between the original frames and the same frames after JPEG encode/decode at that quality (GStreamer `compare method=ssim`, 150 frames; 1.0 = identical). Checked first: identical frames give 1.0, and the value increases with the quality (q30 0.948, q50 0.979, q85 0.998, q95 0.9995). |

Latency was **not** measured. Both configurations use the same jitter buffer
(200 ms), and on loopback the transmission time is negligible compared to
it. A meaningful end-to-end latency measurement would need timestamps
embedded in the video and compared on the receiver; we did not implement
this.

## Results

Raw data: `evidence/measurements.csv` (6 runs). Mean of the 3 runs, with the
range in brackets:

| Measurement | q30 | q85 |
|---|---|---|
| Frames received / produced | **901 / 901** (all 3 runs) | **592 / 901** [558–612] |
| Frame loss | **0.0 %** | **34.3 %** [32.1–38.1] |
| Kernel UDP drops (60 s) | **0** | **10 369** [9 226–11 649] |
| Network data rate | **19.3 Mbit/s** | **40.5 Mbit/s** |
| Sender CPU | 25.7 % [25.67–25.70] | 27.4 % [27.07–27.81] |
| Receiver CPU | 6.0 % | 6.2 % |
| Recording size (control) | 11.36 MB | 11.35 MB |
| Warnings (sender / receiver) | 0 / 0 | 0 / 0 |
| Mean SSIM | **0.948** | **0.998** |

Observations:

- At **q85**, about **one frame in three never reaches the operator**, so the
  displayed video is no longer regular. GStreamer prints **no warning**. The only trace is the kernel counter, with
  about 10 000 datagrams dropped per minute.
- At **q30**, every frame was received in all 3 runs, with 0 kernel drops.
- The data rate **doubles** (×2.1) from q30 to q85. This matches the average
  JPEG frame size measured in the debug report: 162 KB against 335 KB.
- CPU usage differs by only 1.7 points (+7 %) for the sender, and not at all
  for the receiver: the hypothesis is confirmed.
- The recording size is identical, so the recording branch was not affected
  by the change (good control).
- The price of q30 is image quality: SSIM 0.948 against 0.998. q30 loses part
  of the fine detail of each frame, while q85 is practically identical to the
  source.

## Limitations

- **Loopback only.** The bottleneck here is the receiver socket buffer, not
  the link. On a real network, 40.5 Mbit/s would also exceed many links, such
  as Wi-Fi or a remote site uplink, and the loss would come earlier. Our
  numbers are a best case.
- **Worst-case content.** Snow is pure noise, the hardest content for JPEG. A
  real camera image compresses far better, so both qualities would need fewer
  packets per frame. The loss threshold would be higher.
- **Machine-dependent threshold.** The loss depends on how fast the receiver
  empties its socket, and therefore on CPU speed and load. On the teacher's
  machine the exact percentage at q85 can differ. The order of magnitude (0 %
  against tens of %) was stable over our 3 runs and over earlier tests.
- **Buffer limit.** `rmem_max` (212 992 bytes) cannot be raised without
  administrator rights in the course container. With a larger buffer, q85
  might be delivered as well.
- **SSIM measured offline**, on the same 150 snow frames without the overlay,
  so the value is identical for every run of one configuration. It measures
  the coding loss only, not the effect of lost frames.
- **3 runs per configuration.** This is enough to show a clear, repeatable
  difference, but not for a precise statistical estimate.

## Engineering conclusion

For a **live video monitoring** stream, a complete and regular image flow
matters more than fine detail in each image. An operator watching a stream
that freezes for one frame in three can miss an event, while a slightly
blocky image still shows what happens. In our setup:

- **q30 is the right default**:
  - 100 % of the frames delivered, with zero kernel drops;
  - half the bandwidth (19 Mbit/s instead of 40);
  - the same CPU cost;
  - an image that is less sharp (SSIM 0.95) but still usable for monitoring.
- **q85 only makes sense if the receive path is sized for it**: a larger
  `rmem_max`, which needs `sysctl` and administrator rights, plus a link of
  more than 40 Mbit/s. Without that, its better image quality is wasted,
  because a third of the frames are dropped.
- **Error recovery is a strong point of JPEG here**: every frame is
  independent (intra-only), so a lost packet costs exactly one frame and the
  next frame is clean. With H.264/RTP the data rate would be much lower, but
  one lost packet could corrupt the following frames until the next keyframe.
  This trade-off would be the next experiment.
- **Interoperability and complexity** are the same for both settings: the same
  RTP/JPEG payload (RFC 2435, payload type 26) and the same receiver. Only one
  sender option changes, so the operator can raise the quality when the
  network allows it.
