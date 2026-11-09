# -----------------------------------------------------------------------------
# GStreamer Classroom Environment
#
# Base image:
#   livekit/gstreamer provides a recent GStreamer installation.
#
# This image is intended for GitHub Codespaces and training environments where
# students need:
#   - A complete GStreamer runtime
#   - Development headers for writing plugins/applications
#   - A browser-accessible desktop to display video sinks
#   - Python tooling for exercises and examples
#
# Video display architecture:
#
#   GStreamer --> X11 Window --> Xvfb
#                                   |
#                               x11vnc
#                                   |
#                             localhost:5900
#             port 5900 is entirely internal to the container
#                                   |
#                              websockify
#                                   |
#                                noVNC (6080)
#                                   |
#                              Student Browser
#
# This allows pipelines such as:
#   gst-launch-1.0 videotestsrc ! autovideosink
#   gst-launch-1.0 playbin uri=file:///video.mp4
# to display graphical windows directly inside a browser.
# -----------------------------------------------------------------------------

# Copied from the course repository (gst-classroom), trimmed to what this
# assignment needs: GStreamer runtime + dev headers and the noVNC desktop.
# Removed: classroom web app (Python venv) and MediaMTX audio streaming.
FROM livekit/gstreamer:1.26.7-prod-rs

# -----------------------------------------------------------------------------
# Environment configuration
# -----------------------------------------------------------------------------

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DISPLAY=:99 \
    PULSE_SERVER=unix:/tmp/pulse/native \
    XDG_RUNTIME_DIR=/tmp/runtime-classroom

# -----------------------------------------------------------------------------
# Install required packages
#
# General tools
#   - bash, curl, git
#   - graphviz (pipeline diagrams)
#
# Python
#   - python3, pip, venv
#
# Remote graphical desktop
#   - xvfb      : virtual X11 server
#   - fluxbox   : lightweight window manager
#   - x11vnc    : expose X11 desktop through VNC
#   - novnc     : browser-based VNC client
#   - websockify: websocket bridge used by noVNC
#   - xterm     : terminal available from the virtual desktop
#
# GStreamer runtime
#   - standard plugin collections
#   - libav codecs
#   - OpenGL support
#   - X11 video sinks
#
# GStreamer development
#   - headers for exercises involving plugin/application development
# -----------------------------------------------------------------------------
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    \
    # General utilities
    bash \
    ca-certificates \
    curl \
    eterm \
    git \
    git-lfs \
    graphviz \
    #    procps: provides tools such as ps, pgrep, and pkill
    procps \
    #    psmisc: provides tools such as pstree, fuser, and killall
    # psmisc \
    #    net-tools: provides legacy commands such as netstat and ifconfig
    # net-tools \
    #    iproute2: provides ip and related network diagnostics
    # iproute2 \
    \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    \
    # pidstat
    sysstat \
    # tcpdump
    tcpdump \
    # To be able to build a plugin example:
    #   cmake/opencv/pkg-config/...
    build-essential \
    cmake \
    libopencv-dev \
    pkg-config \
    \
    # Virtual desktop
    xvfb \
    fluxbox \
    x11vnc \
    #  x11-utils: provides xdpyinfo (to test whether Xvfb is ready)
    x11-utils \
    novnc \
    tar \
    wget \
    websockify \
    xterm \
    \
    # Audio
    pulseaudio \
    pulseaudio-utils \
    alsa-utils \
    \
    # GStreamer runtime
    gstreamer1.0-gl \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-pulseaudio \
    gstreamer1.0-rtsp \
    gstreamer1.0-tools \
    gstreamer1.0-x \
    \
    # GStreamer development
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Runtime directories
# -----------------------------------------------------------------------------

RUN mkdir -p \
      /workspace \
      /tmp/runtime-classroom \
      /tmp/pulse \
      /var/log/classroom \
    && chmod 700 /tmp/runtime-classroom \
    && chmod 777 /tmp/pulse

WORKDIR /workspace

# -----------------------------------------------------------------------------
# Browser-accessible desktop
#
# Port 6080:
#   noVNC web interface
#
# Example:
#   https://<codespace-name>-6080.app.github.dev
# -----------------------------------------------------------------------------

# To automatically open the VNC client
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

EXPOSE 6080
# - 6080: Virtual desktop (noVNC)

# -----------------------------------------------------------------------------
# Startup scripts
#
# Starts:
#   1. Xvfb
#   2. Fluxbox
#   3. x11vnc
#   4. noVNC/websockify
# -----------------------------------------------------------------------------

COPY environment/start-desktop.sh   /usr/local/bin/start-desktop.sh
COPY environment/start-classroom.sh /usr/local/bin/start-classroom.sh

RUN chmod +x \
      /usr/local/bin/start-desktop.sh \
      /usr/local/bin/start-classroom.sh

# -----------------------------------------------------------------------------
# Health check
# -----------------------------------------------------------------------------
# Lets Docker periodically verify that the container is still functioning as
# expected
#
# Every 30 seconds, verify the entire desktop stack:
#  - Xvfb running
#  - x11vnc running
#  - noVNC responding
#
# A health check gives you a visible indication that something is wrong.
# For example:
#   docker ps
# might show:
#   Up 2h (healthy)
# or:
#   Up 2h (unhealthy)
# instead of silently failing.
# -----------------------------------------------------------------------------

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD sh -c '\
    pgrep -x Xvfb >/dev/null && \
    pgrep -x x11vnc >/dev/null && \
    pgrep -f "websockify.*6080" >/dev/null && \
    curl -fsS http://127.0.0.1:6080/ >/dev/null \
  '

CMD ["/usr/local/bin/start-classroom.sh"]
