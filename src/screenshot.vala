using GLib;

namespace Singularity.Portal {

    /**
     * Implements the org.freedesktop.impl.portal.Screenshot interface.
     *
     * Delegates capture to singularity-screenshot and region selection
     * to singularity-region-picker. Color picking uses hyprpicker.
     */
    [DBus (name = "org.freedesktop.impl.portal.Screenshot")]
    public class ScreenshotPortal : Object {

        /** Takes a screenshot, optionally with interactive region selection. */
        public async void screenshot(
            ObjectPath handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            bool interactive = options.contains("interactive") &&
                               options.get("interactive").get_boolean();
            string temp_path = GLib.Path.build_filename(
                Environment.get_tmp_dir(),
                "singularity-screenshot-%d.png".printf((int)Posix.getpid()));
            message("ScreenshotPortal: interactive=%s path=%s", interactive.to_string(), temp_path);
            try {
                string bin_dir = GLib.Path.build_filename(
                    Environment.get_home_dir(), ".local", "singularity", "bin");
                string screenshot_bin = GLib.Path.build_filename(bin_dir, "singularity-screenshot");
                string picker_bin = GLib.Path.build_filename(bin_dir, "singularity-region-picker");
                string[] argv;
                if (interactive) {
                    argv = {"bash", "-c",
                        "%s -g \"$(%s)\" %s".printf(screenshot_bin, picker_bin, GLib.Shell.quote(temp_path))};
                } else {
                    argv = {screenshot_bin, temp_path};
                }
                var subprocess = new Subprocess.newv(argv,
                    SubprocessFlags.STDIN_INHERIT |
                    SubprocessFlags.STDOUT_SILENCE |
                    SubprocessFlags.STDERR_SILENCE);
                bool ok = yield subprocess.wait_check_async(null);
                if (ok && FileUtils.test(temp_path, FileTest.EXISTS)) {
                    message("ScreenshotPortal: saved %s", temp_path);
                    results.insert("uri", new Variant.string(Filename.to_uri(temp_path)));
                    response = 0;
                } else {
                    message("ScreenshotPortal: failed, status=%s", ok.to_string());
                    response = 2;
                }
            } catch (Error e) {
                warning("ScreenshotPortal: %s", e.message);
                response = 2;
            }
        }

        /** Picks a color from the screen using hyprpicker. */
        public async void pick_color(
            ObjectPath handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            try {
                // spawn_command_line_sync would block the Wayland main loop
                // causing a compositor deadlock with hyprpicker
                string[] argv = {"hyprpicker"};
                var proc = new Subprocess.newv(argv,
                    SubprocessFlags.STDIN_INHERIT |
                    SubprocessFlags.STDOUT_PIPE  |
                    SubprocessFlags.STDERR_SILENCE);
                string? stdout_buf = null;
                yield proc.communicate_utf8_async(null, null, out stdout_buf, null);
                if (proc.get_exit_status() == 0 && stdout_buf != null && stdout_buf.length > 0) {
                    string hex = stdout_buf.strip();
                    double r = 0, g = 0, b = 0;
                    if (hex.has_prefix("#") && hex.length >= 7) {
                        uint64 rval = 0, gval = 0, bval = 0;
                        hex.substring(1, 2).scanf("%llx", out rval);
                        hex.substring(3, 2).scanf("%llx", out gval);
                        hex.substring(5, 2).scanf("%llx", out bval);
                        r = (double)rval / 255.0;
                        g = (double)gval / 255.0;
                        b = (double)bval / 255.0;
                    }
                    results.insert("color", new Variant("(ddd)", r, g, b));
                    response = 0;
                } else {
                    response = 1;
                }
            } catch (Error e) {
                warning("ScreenshotPortal: pick_color failed: %s", e.message);
                response = 2;
            }
        }
    }
}