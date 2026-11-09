/**
 * @file monitor_sender.cpp
 * @brief Video monitoring sender: one live source, three branches
 *        (local preview, H.264 recording, RTP/JPEG over UDP).
 *
 * The pipeline is described as text and built with gst_parse_launch(): the
 * same description is used by scripts/sender.sh, so both can be compared
 * line by line. Elements that the program needs later are named.
 *
 * Build:  scripts/build.sh   (CMake, output in build/)
 * Run:    build/monitor_sender --help
 *
 * Exit codes: 0 = success, 1 = runtime error, 2 = invalid arguments.
 */
#include <gst/gst.h>
#include <glib-unix.h>

#include <csignal>
#include <cstdio>
#include <string>

static constexpr int EXIT_RUNTIME_ERROR = 1;
static constexpr int EXIT_INVALID_ARGS  = 2;

// Time allowed between sending EOS and receiving it back on the bus.
static constexpr guint EOS_TIMEOUT_SECONDS = 5;

// Shown in the overlay to identify the team.
static const char *TEAM_MEMBERS = "Lorenzo Bravard";

/** Values given on the command line (-1 / nullptr = not given). */
struct Options {
  gchar   *pattern          = nullptr;
  gint     width            = -1;
  gint     height           = -1;
  gint     fps              = -1;
  gint     port             = -1;
  gchar   *output           = nullptr;
  gint     duration         = -1;   // -1 = not given, 0 = until Ctrl+C
  gboolean headless         = FALSE;
  gint     jpeg_quality     = 30;   // snow saturates the UDP buffer above ~60
  gchar   *overlay_position = nullptr;
};

/** Runtime state shared with the GLib callbacks. */
struct App {
  GstElement *pipeline     = nullptr;
  GMainLoop  *loop         = nullptr;
  bool        eos_sent     = false;
  bool        eos_received = false;
  bool        failed       = false;
  guint       duration_id  = 0;   // GLib source ids, 0 = not active
  guint       watchdog_id  = 0;
  guint       sigint_id    = 0;
  guint       sigterm_id   = 0;
};

static bool invalid(const char *message) {
  g_printerr("monitor_sender: %s (see --help)\n", message);
  return false;
}

/** Parse argv with GOptionContext, then check presence and ranges. */
static bool parse_options(int &argc, char **&argv, Options &opt) {
  const GOptionEntry entries[] = {
    {"pattern",      0, 0, G_OPTION_ARG_STRING, &opt.pattern,      "Test pattern: smpte, ball, snow, zone-plate", "NAME"},
    {"width",        0, 0, G_OPTION_ARG_INT,    &opt.width,        "Frame width in pixels (even, 16-3840)",       "W"},
    {"height",       0, 0, G_OPTION_ARG_INT,    &opt.height,       "Frame height in pixels (even, 16-2160)",      "H"},
    {"fps",          0, 0, G_OPTION_ARG_INT,    &opt.fps,          "Frame rate (1-60)",                           "FPS"},
    {"port",         0, 0, G_OPTION_ARG_INT,    &opt.port,         "UDP port on 127.0.0.1 (1024-65535)",          "PORT"},
    {"output",       0, 0, G_OPTION_ARG_STRING, &opt.output,       "Recording file (.mkv or .ts)",                "FILE"},
    {"duration",     0, 0, G_OPTION_ARG_INT,    &opt.duration,     "Seconds before EOS; 0 = until Ctrl+C",        "SECONDS"},
    {"headless",     0, 0, G_OPTION_ARG_NONE,   &opt.headless,     "No preview window (fakesink)",                nullptr},
    {"jpeg-quality", 0, 0, G_OPTION_ARG_INT,    &opt.jpeg_quality, "Network JPEG quality, 1-100 (default 30)",    "Q"},
    {"overlay-position", 0, 0, G_OPTION_ARG_STRING, &opt.overlay_position,
     "Overlay position: top-left, top-center, bottom-right (default bottom-right)", "POS"},
    {nullptr, 0, 0, G_OPTION_ARG_NONE, nullptr, nullptr, nullptr}
  };

  GOptionContext *context = g_option_context_new("- video monitoring sender");
  g_option_context_set_summary(context,
      "Live test pattern -> overlay -> tee -> preview + H.264 recording + RTP/JPEG over UDP.\n"
      "--pattern, --width, --height, --fps, --port, --output and --duration are required.");
  g_option_context_add_main_entries(context, entries, nullptr);
  g_option_context_add_group(context, gst_init_get_option_group());

  GError *error = nullptr;
  const gboolean parsed = g_option_context_parse(context, &argc, &argv, &error);
  g_option_context_free(context);
  if (!parsed) {
    g_printerr("monitor_sender: %s (see --help)\n", error->message);
    g_error_free(error);
    return false;
  }
  if (argc > 1) {
    return invalid((std::string("unexpected argument '") + argv[1] + "'").c_str());
  }

  if (!opt.pattern || opt.width == -1 || opt.height == -1 || opt.fps == -1 || opt.port == -1
      || !opt.output || opt.duration == -1) {
    return invalid("missing required option: --pattern, --width, --height, --fps, "
                   "--port, --output and --duration are all required");
  }

  const std::string pattern = opt.pattern;
  if (pattern != "smpte" && pattern != "ball" && pattern != "snow" && pattern != "zone-plate") {
    return invalid("--pattern must be smpte, ball, snow or zone-plate");
  }
  if (opt.width < 16 || opt.width > 3840 || opt.width % 2 != 0) {
    return invalid("--width must be an even number between 16 and 3840");
  }
  if (opt.height < 16 || opt.height > 2160 || opt.height % 2 != 0) {
    return invalid("--height must be an even number between 16 and 2160");
  }
  if (opt.fps < 1 || opt.fps > 60) {
    return invalid("--fps must be between 1 and 60");
  }
  if (opt.port < 1024 || opt.port > 65535) {
    return invalid("--port must be between 1024 and 65535");
  }
  if (opt.duration < 0) {
    return invalid("--duration must be 0 or more seconds");
  }
  if (opt.jpeg_quality < 1 || opt.jpeg_quality > 100) {
    return invalid("--jpeg-quality must be between 1 and 100");
  }
  if (!g_str_has_suffix(opt.output, ".mkv") && !g_str_has_suffix(opt.output, ".ts")) {
    return invalid("--output must end with .mkv (Matroska) or .ts (MPEG-TS)");
  }
  if (!opt.overlay_position) {
    opt.overlay_position = g_strdup("bottom-right");
  }
  const std::string position = opt.overlay_position;
  if (position != "top-left" && position != "top-center" && position != "bottom-right") {
    return invalid("--overlay-position must be top-left, top-center or bottom-right");
  }
  return true;
}

/** Same pipeline as scripts/sender.sh (see architecture.md for each queue). */
static std::string build_pipeline_description(const Options &opt) {
  const std::string w = std::to_string(opt.width);
  const std::string h = std::to_string(opt.height);
  const std::string fps = std::to_string(opt.fps);
  const std::string position = opt.overlay_position;

  const std::string halign = position == "top-left" ? "left"
                           : position == "top-center" ? "center" : "right";
  const std::string valign = position == "bottom-right" ? "bottom" : "top";
  const std::string muxer = g_str_has_suffix(opt.output, ".mkv") ? "matroskamux" : "mpegtsmux";
  const std::string preview_sink = opt.headless ? "fakesink sync=true"
                                                : "ximagesink handle-events=false";
  const std::string overlay_text =
      std::string(TEAM_MEMBERS) + " | " + w + "x" + h + " @ " + fps + " fps |";

  return
      // Source + common processing. format=I420: rtpjpegpay rejects Y444.
      "videotestsrc name=source pattern=" + std::string(opt.pattern) + " is-live=true"
      " ! video/x-raw,format=I420,width=" + w + ",height=" + h + ",framerate=" + fps + "/1"
      " ! videobalance name=video_balance"
      " ! timeoverlay name=info_overlay text=\"" + overlay_text + "\""
      "   halignment=" + halign + " valignment=" + valign +
      "   shaded-background=true font-desc=\"Sans 14\""
      " ! tee name=t"
      // Branch A: preview. Leaky queue: a slow display never blocks the tee.
      " t. ! queue name=preview_queue leaky=downstream max-size-buffers=2"
      "    ! videoconvert ! " + preview_sink + " name=preview_sink"
      // Branch B: recording. Not leaky (no gaps); 3 s absorbs encoder bursts.
      " t. ! queue name=record_queue max-size-time=3000000000 max-size-buffers=0 max-size-bytes=0"
      "    ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=" + fps + " bitrate=1500"
      "    ! h264parse ! " + muxer + " ! filesink name=rec_sink location=\"" + opt.output + "\""
      // Branch C: network. Leaky: a late live frame is useless.
      " t. ! queue name=net_queue leaky=downstream"
      "    ! jpegenc quality=" + std::to_string(opt.jpeg_quality) + " ! rtpjpegpay"
      "    ! udpsink name=net_sink host=127.0.0.1 port=" + std::to_string(opt.port);
}

/** Abort if EOS does not come back: the file would not be finalized. */
static gboolean on_eos_timeout(gpointer data) {
  App *app = static_cast<App *>(data);
  g_printerr("ERROR: EOS not received within %u s after sending it\n", EOS_TIMEOUT_SECONDS);
  app->watchdog_id = 0;
  app->failed = true;
  g_main_loop_quit(app->loop);
  return G_SOURCE_REMOVE;
}

/**
 * Ask the pipeline to finish: EOS flows from the source through every branch,
 * the muxer writes its index and headers, then EOS comes back on the bus.
 */
static void send_eos(App *app, const char *reason) {
  if (app->eos_sent) {
    return;
  }
  app->eos_sent = true;
  g_print("EOS_SENT reason=%s\n", reason);
  gst_element_send_event(app->pipeline, gst_event_new_eos());
  app->watchdog_id = g_timeout_add_seconds(EOS_TIMEOUT_SECONDS, on_eos_timeout, app);
}

static gboolean on_duration_elapsed(gpointer data) {
  App *app = static_cast<App *>(data);
  app->duration_id = 0;
  send_eos(app, "duration");
  return G_SOURCE_REMOVE;
}

/** SIGINT (Ctrl+C) and SIGTERM also stop through EOS, never abruptly. */
static gboolean on_sigint(gpointer data) {
  send_eos(static_cast<App *>(data), "SIGINT");
  return G_SOURCE_CONTINUE;
}

static gboolean on_sigterm(gpointer data) {
  send_eos(static_cast<App *>(data), "SIGTERM");
  return G_SOURCE_CONTINUE;
}

static gboolean on_bus_message(GstBus *, GstMessage *msg, gpointer data) {
  App *app = static_cast<App *>(data);

  switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_ERROR: {
      GError *error = nullptr;
      gchar *debug = nullptr;
      gst_message_parse_error(msg, &error, &debug);
      g_printerr("ERROR from element %s: %s\n", GST_OBJECT_NAME(msg->src), error->message);
      g_printerr("Debugging information: %s\n", debug ? debug : "none");
      g_clear_error(&error);
      g_free(debug);
      app->failed = true;
      g_main_loop_quit(app->loop);
      break;
    }
    case GST_MESSAGE_WARNING: {
      GError *error = nullptr;
      gchar *debug = nullptr;
      gst_message_parse_warning(msg, &error, &debug);
      g_printerr("WARNING from element %s: %s\n", GST_OBJECT_NAME(msg->src), error->message);
      g_clear_error(&error);
      g_free(debug);
      break;
    }
    case GST_MESSAGE_EOS:
      g_print("EOS_RECEIVED\n");
      app->eos_received = true;
      g_main_loop_quit(app->loop);
      break;
    case GST_MESSAGE_STATE_CHANGED:
      // Only the pipeline itself: every element posts its own changes.
      if (GST_MESSAGE_SRC(msg) == GST_OBJECT(app->pipeline)) {
        GstState old_state, new_state;
        gst_message_parse_state_changed(msg, &old_state, &new_state, nullptr);
        g_print("STATE_CHANGED %s -> %s\n",
                gst_element_state_get_name(old_state), gst_element_state_get_name(new_state));
      }
      break;
    default:
      break;
  }
  return G_SOURCE_CONTINUE;
}

static void remove_source(guint &id) {
  if (id != 0) {
    g_source_remove(id);
    id = 0;
  }
}

int main(int argc, char *argv[]) {
  // Line-buffered stdout: log lines reach a file or pipe immediately.
  setvbuf(stdout, nullptr, _IOLBF, 0);

  Options opt;
  if (!parse_options(argc, argv, opt)) {
    return EXIT_INVALID_ARGS;
  }
  g_print("CONFIG pattern=%s size=%dx%d fps=%d port=%d output=%s duration=%d headless=%s "
          "jpeg-quality=%d overlay-position=%s\n",
          opt.pattern, opt.width, opt.height, opt.fps, opt.port, opt.output, opt.duration,
          opt.headless ? "yes" : "no", opt.jpeg_quality, opt.overlay_position);

  const std::string description = build_pipeline_description(opt);
  GError *error = nullptr;
  App app;
  app.pipeline = gst_parse_launch(description.c_str(), &error);
  if (!app.pipeline || error) {
    // A missing plugin also lands here (e.g. "no element x264enc").
    g_printerr("ERROR: could not build the pipeline: %s\n", error ? error->message : "unknown");
    g_clear_error(&error);
    if (app.pipeline) {
      gst_object_unref(app.pipeline);
    }
    g_free(opt.pattern);
    g_free(opt.output);
    g_free(opt.overlay_position);
    return EXIT_RUNTIME_ERROR;
  }

  app.loop = g_main_loop_new(nullptr, FALSE);
  GstBus *bus = gst_element_get_bus(app.pipeline);
  gst_bus_add_watch(bus, on_bus_message, &app);
  app.sigint_id  = g_unix_signal_add(SIGINT,  on_sigint,  &app);
  app.sigterm_id = g_unix_signal_add(SIGTERM, on_sigterm, &app);

  if (gst_element_set_state(app.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
    g_printerr("ERROR: the pipeline refused to go to PLAYING\n");
    app.failed = true;
    // The main loop never ran: print the element's ERROR still on the bus.
    GstMessage *msg = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
    if (msg) {
      on_bus_message(bus, msg, &app);
      gst_message_unref(msg);
    }
  } else {
    if (opt.duration > 0) {
      // Millisecond timer: g_timeout_add_seconds() may fire up to ~1 s off
      // (measured 9.8-10.7 s for 10 s), which changes the recording length.
      app.duration_id = g_timeout_add(static_cast<guint>(opt.duration) * 1000,
                                      on_duration_elapsed, &app);
    }
    g_main_loop_run(app.loop);
  }

  // Cleanup: NULL state releases devices, sockets and the output file.
  gst_element_set_state(app.pipeline, GST_STATE_NULL);
  remove_source(app.duration_id);
  remove_source(app.watchdog_id);
  remove_source(app.sigint_id);
  remove_source(app.sigterm_id);
  gst_bus_remove_watch(bus);
  gst_object_unref(bus);
  gst_object_unref(app.pipeline);
  g_main_loop_unref(app.loop);

  const bool success = app.eos_received && !app.failed;
  g_print("EXIT status=%s\n", success ? "success" : "failure");
  g_free(opt.pattern);
  g_free(opt.output);
  g_free(opt.overlay_position);
  gst_deinit();  // also lets GST_TRACERS=leaks report remaining objects
  return success ? 0 : EXIT_RUNTIME_ERROR;
}
