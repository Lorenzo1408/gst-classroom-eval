/**
 * @file monitor_sender.cpp
 * @brief Video monitoring sender: one live source, three branches
 *        (local preview, H.264 recording, RTP/JPEG over UDP).
 *
 * Build:  scripts/build.sh   (CMake, output in build/)
 * Run:    build/monitor_sender --help
 *
 * Exit codes: 0 = success, 1 = runtime error, 2 = invalid arguments.
 */
#include <gst/gst.h>

#include <cstdio>
#include <string>

static constexpr int EXIT_RUNTIME_ERROR = 1;
static constexpr int EXIT_INVALID_ARGS  = 2;

/** Values given on the command line (-1 / nullptr = not given). */
struct Options {
  gchar   *pattern      = nullptr;
  gint     width        = -1;
  gint     height       = -1;
  gint     fps          = -1;
  gint     port         = -1;
  gchar   *output       = nullptr;
  gint     duration     = -1;   // -1 = not given, 0 = until Ctrl+C
  gboolean headless     = FALSE;
  gint     jpeg_quality = 30;   // snow saturates the UDP buffer above ~60
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
    {nullptr, 0, 0, G_OPTION_ARG_NONE, nullptr, nullptr, nullptr}
  };

  GOptionContext *context = g_option_context_new("- video monitoring sender");
  g_option_context_set_summary(context,
      "Live test pattern -> overlay -> tee -> preview + H.264 recording + RTP/JPEG over UDP.\n"
      "All options except --headless and --jpeg-quality are required.");
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
  return true;
}

int main(int argc, char *argv[]) {
  // Line-buffered stdout: log lines reach a file or pipe immediately.
  setvbuf(stdout, nullptr, _IOLBF, 0);

  Options opt;
  if (!parse_options(argc, argv, opt)) {
    return EXIT_INVALID_ARGS;
  }

  g_print("CONFIG pattern=%s size=%dx%d fps=%d port=%d output=%s duration=%d headless=%s jpeg-quality=%d\n",
          opt.pattern, opt.width, opt.height, opt.fps, opt.port, opt.output,
          opt.duration, opt.headless ? "yes" : "no", opt.jpeg_quality);

  g_free(opt.pattern);
  g_free(opt.output);
  (void)EXIT_RUNTIME_ERROR;  // used once the pipeline is added (next step)
  return 0;
}
