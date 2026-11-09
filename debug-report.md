# Debugging report — RTP/JPEG stream silently lost on the receiver

## 1. Observed symptom

With the team configuration (`snow`, 960x540, 15 fps, RTP/JPEG on UDP port 5103),
the receiver decoded **0 frames** when the network JPEG quality was 85, although:

- the sender ran normally: it reached PLAYING, recorded a valid file and printed
  **no warning and no error**;
- the receiver also reached PLAYING and printed no error either: it just never
  output a frame.

The same receiver decoded every frame when the sender used the `smpte` pattern.

## 2. Initial hypotheses

| # | Hypothesis | Why it was plausible |
|---|---|---|
| H1 | Receiver caps or RTP payload type incorrect (`encoding-name`, `payload=26`, clock rate) | Incomplete receiver caps is a classic cause of "nothing decoded" with `udpsrc` |
| H2 | The sender did not really send valid RTP/JPEG | An earlier bug (missing `format=I420`) had made `rtpjpegpay` drop every frame (`Invalid component`) |
| H3 | Packets lost between sender and receiver | Snow is almost incompressible: one JPEG frame is hundreds of packets sent in a burst over UDP, with no retransmission |

## 3. Commands used during the investigation

All commands run in the course container, from the repository root.

```bash
# Frame count on the receiver: one "last-message = chain" line per decoded frame
gst-launch-1.0 -e -v udpsrc port=5103 \
  caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=JPEG,payload=26" \
  ! rtpjitterbuffer latency=200 ! rtpjpegdepay ! jpegdec \
  ! fakesink name=rx_sink silent=false sync=false | grep -c "rx_sink: last-message = chain"

# Sender with the full 3-branch pipeline, quality as the only change
scripts/sender.sh --headless --duration 10 --jpeg-quality 85

# What the receiver elements say
GST_DEBUG="udpsrc:4,rtpjpegdepay:2" gst-launch-1.0 -e udpsrc port=5103 caps="..." ! ... ! fakesink

# Size of one JPEG frame (bytes per buffer) for each pattern/quality
gst-launch-1.0 -v videotestsrc pattern=snow num-buffers=30 \
  ! video/x-raw,format=I420,width=960,height=540,framerate=15/1 \
  ! jpegenc quality=85 ! fakesink name=s silent=false

# Kernel side: UDP datagrams dropped because the socket buffer was full
awk '/^Udp:/ && ++n==2 {print $6}' /proc/net/snmp      # RcvbufErrors counter
cat /proc/sys/net/core/rmem_default /proc/sys/net/core/rmem_max
gst-inspect-1.0 udpsrc | grep -A2 buffer-size
```

Diagnostic tools used: `gst-launch-1.0 -v`, `GST_DEBUG` with element
categories, `gst-inspect-1.0`, and the kernel UDP counters (`/proc/net/snmp`).

## 4. Relevant log extract

Receiver with the default socket buffer, sender at quality 85 for 8 s
(`GST_DEBUG="udpsrc:4,rtpjpegdepay:2"`, then counters around the run):

```
INFO  udpsrc gstudpsrc.c:1728:gst_udpsrc_open:<udpsrc0> have udp buffer of 106496 bytes
WARN  rtpjpegdepay gstrtpjpegdepay.c:769:gst_rtp_jpeg_depay_process:<rtpjpegdepay0> discarding data packets received when we have no header
WARN  rtpjpegdepay gstrtpjpegdepay.c:769:gst_rtp_jpeg_depay_process:<rtpjpegdepay0> discarding data packets received when we have no header
    ... (4958 lines of this warning in 8 s, 0 decoded frame)
sender log: 0 warning, 0 error

Kernel counter over one 10 s run (150 frames sent):
snow  q85, default buffer      : frames=0/150    RcvbufErrors +11351
snow  q85, buffer-size=rmem_max: frames=108/150  RcvbufErrors +1213
snow  q30, default buffer      : frames=45/150   RcvbufErrors +1145
snow  q30, buffer-size=rmem_max: frames=150/150  RcvbufErrors +0
smpte q85, default buffer      : frames=151/150  RcvbufErrors +0

With the fix:
INFO  udpsrc gstudpsrc.c:1728:gst_udpsrc_open:<udpsrc0> have udp buffer of 212992 bytes
```

Average JPEG frame size (30 frames): snow q85 = 334 861 bytes (about 240 RTP
packets), snow q30 = 162 312 bytes (about 115 packets), smpte q85 = 40 383
bytes (about 28 packets).

## 5. Root cause

The **kernel UDP receive buffer of the receiver socket is too small for one
snow frame**. `udpsrc` uses the system default (GStreamer reports 106 496
bytes). At quality 85 a snow frame is about 335 KB, sent by `rtpjpegpay` +
`udpsink` as a burst of about 240 packets. The buffer fills up before
`udpsrc` can read it, and **the kernel drops the remaining datagrams without
any message** to the application: only the `RcvbufErrors` counter increases.

Every frame therefore loses some of its fragments. `rtpjpegdepay` cannot
rebuild an incomplete JPEG frame: when the packet carrying the frame header
is lost, it discards all the following packets ("discarding data packets
received when we have no header") until the next frame. The result is 0
decoded frames, with no error anywhere in GStreamer.

## 6. Correction

Two changes, both in the repository:

1. **Receiver** (`scripts/receiver.sh`): ask for the largest receive buffer that
   the kernel allows without privileges, read at runtime instead of hard-coded:
   ```bash
   UDP_BUFFER_SIZE="$(cat /proc/sys/net/core/rmem_max)"
   udpsrc port="$PORT" buffer-size="$UDP_BUFFER_SIZE" caps="$RTP_JPEG_CAPS" ! ...
   ```
2. **Sender** (`src/monitor_sender.cpp`, `scripts/sender.sh`): network JPEG
   quality **30 by default** (`--jpeg-quality` to change it), so that one snow
   frame (about 115 packets) fits in the enlarged buffer.

## 7. Why the correction works

- `buffer-size` sets `SO_RCVBUF` on the socket. Without privileges the kernel
  caps it at `net.core.rmem_max` (212 992 here). Requesting exactly that value
  **doubles** the effective buffer (GStreamer reports 212 992 instead of
  106 496) without any warning. Requesting more (tested: 32 MB) only adds the
  warning *"Could not create a buffer of requested 33554432 bytes (Operation not
  permitted)"* and gives the same size.
- Doubling the buffer alone is not enough at quality 85 (108/150 frames): a
  frame is still about twice too big. Lowering the quality to 30 halves the
  frame size. With both changes a whole frame burst fits, and the kernel
  drops nothing: **150/150 frames, `RcvbufErrors` +0**.
- Under the real load (full 3-branch sender, preview displayed, 45 s runs),
  qualities 30, 40 and 50 all gave 675/675 frames. Losses start between 60 and
  70. Quality 30 is about half of this threshold, which leaves a safety
  margin.
- The quality/loss trade-off is measured in more detail in `experiment.md`.

## 8. Alternative diagnosis considered and rejected

**H1 — wrong receiver caps or payload type** (the most common cause of
"nothing decoded").

## 9. Evidence used to reject it

- **Same receiver, same caps, same port, only the pattern changes**: `smpte` at
  quality 85 gives **151/150 frames** with the default buffer and
  `RcvbufErrors` +0. If the caps or payload type were wrong, smpte would fail
  too. The difference is the frame size: 40 KB (28 packets) against 335 KB
  (240 packets).
- With wrong caps `rtpjpegdepay` would never get a valid packet. Here it does
  receive packets and complains about **missing headers**, which points to
  missing fragments, not to a format problem.
- H2 was also rejected: the sender log has 0 warnings at q85 (unlike the
  earlier `Invalid component` bug), and the kernel counter shows the packets
  reached the receiving host and were dropped there.

One mistake during the investigation: a first single run with
`buffer-size=33554432` seemed to change nothing, and I concluded that
`buffer-size` was useless. Repeating each configuration 3 to 5 times showed
that it does help (0/90 → 54–61/90 frames at q85). Since then every
measurement is repeated before drawing a conclusion.

## 10. How to reproduce the original fault

Inside the container, from the repository root, after `./scripts/build.sh`.
Use two terminals, and start the receiver first.

```bash
# Terminal 1 — receiver WITHOUT the fix (default socket buffer), 14 s
before=$(awk '/^Udp:/ && ++n==2 {print $6}' /proc/net/snmp)
timeout -s INT 14 gst-launch-1.0 -e -v udpsrc port=5103 \
  caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=JPEG,payload=26" \
  ! rtpjitterbuffer latency=200 ! rtpjpegdepay ! jpegdec \
  ! fakesink name=rx_sink silent=false sync=false | grep -c "rx_sink: last-message = chain"
echo "RcvbufErrors +$(( $(awk '/^Udp:/ && ++n==2 {print $6}' /proc/net/snmp) - before ))"

# Terminal 2 — sender at quality 85, 10 s (150 frames)
scripts/sender.sh --headless --duration 10 --jpeg-quality 85
```

Expected result: about 0 frames and several thousand `RcvbufErrors`.

To see the corrected behaviour, replace terminal 1 with the fixed receiver and
run terminal 2 with the default quality:

```bash
scripts/receiver.sh test --duration 14          # terminal 1: RECEIVED_FRAMES=150
scripts/sender.sh --headless --duration 10      # terminal 2: default quality 30
```

The numbers depend on the machine load. Only the order of magnitude matters:
0 frames against all frames, and thousands of kernel drops against 0.
