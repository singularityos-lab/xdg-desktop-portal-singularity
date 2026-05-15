using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.FileChooser.
     *
     * Delegates to singularity-files in portal mode, communicating
     * results via a temporary file.
     */
    [DBus (name = "org.freedesktop.impl.portal.FileChooser")]
    public class FileChooserPortal : Object {
        public FileChooserPortal() {}

        /** Opens a file selection dialog. */
        public async void open_file(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            response = yield _run_picker(
                title != "" ? title : "Open File",
                _get_bool_option(options, "multiple"),
                false,
                null,
                results
            );
        }

        /** Opens a save-file dialog. */
        public async void save_file(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            response = yield _run_picker(
                title != "" ? title : "Save File",
                false,
                true,
                _get_string_option(options, "current_name"),
                results
            );
        }

        /** Opens a save-files dialog. */
        public async void save_files(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            response = yield _run_picker(
                title != "" ? title : "Save Files",
                false,
                true,
                _get_string_option(options, "current_name"),
                results
            );
        }

        private bool _get_bool_option(HashTable<string, Variant> options, string key) {
            Variant? val = options.get(key);
            return val != null && val.get_boolean();
        }

        private string? _get_string_option(HashTable<string, Variant> options, string key) {
            Variant? val = options.get(key);
            if (val == null) return null;
            string str = val.get_string();
            return str != "" ? str : null;
        }

        private async uint32 _run_picker(
            string title,
            bool multiple,
            bool save_mode,
            string? current_name,
            HashTable<string, Variant> results
        ) {
            int64 ts = GLib.get_real_time();
            string result_path = GLib.Path.build_filename(
                Environment.get_tmp_dir(),
                "singularity-portal-%lld.uris".printf(ts));

            try {
                // Resolve singularity-files relative to our own executable
                // so the correct binary is found even when activated via D-Bus
                string files_bin = "singularity-files";
                string? schemas_dir = null;
                try {
                    string exe = FileUtils.read_link("/proc/self/exe");
                    string exe_dir = Path.get_dirname(exe);
                    string candidate = Path.build_filename(exe_dir, "singularity-files");
                    if (FileUtils.test(candidate, FileTest.IS_EXECUTABLE)) {
                        files_bin = candidate;
                    }
                    // GSettings schema dir: <install_prefix>/share/glib-2.0/schemas
                    string candidate_schemas = Path.build_filename(
                        Path.get_dirname(exe_dir), "share", "glib-2.0", "schemas");
                    if (FileUtils.test(candidate_schemas, FileTest.IS_DIR)) {
                        schemas_dir = candidate_schemas;
                    }
                } catch (Error path_err) {
                    warning("FileChooserPortal: could not resolve exe path, falling back to PATH: %s", path_err.message);
                }

                string[] argv = {
                    files_bin,
                    "--portal-mode",
                    "--title=" + title
                };
                if (multiple) {
                    argv += "--multiple";
                }
                if (save_mode) {
                    argv += "--save";
                }
                if (current_name != null) {
                    argv += "--current-name=" + current_name;
                }

                var launcher = new SubprocessLauncher(
                    SubprocessFlags.STDIN_INHERIT |
                    SubprocessFlags.STDOUT_SILENCE |
                    SubprocessFlags.STDERR_SILENCE
                );
                launcher.setenv("SINGULARITY_PORTAL_RESULT_FILE", result_path, true);
                if (schemas_dir != null) {
                    launcher.setenv("GSETTINGS_SCHEMA_DIR", schemas_dir, true);
                }
                var proc = launcher.spawnv(argv);
                yield proc.wait_async(null);
            } catch (Error e) {
                warning("FileChooserPortal: failed to launch picker: %s", e.message);
                return 2;
            }

            if (!FileUtils.test(result_path, FileTest.EXISTS)) {
                return 1;
            }

            try {
                string content;
                FileUtils.get_contents(result_path, out content);
                FileUtils.unlink(result_path);

                string[] lines = content.strip().split("\n");
                var uri_list = new VariantBuilder(new VariantType("as"));
                foreach (var line in lines) {
                    string uri = line.strip();
                    if (uri.length > 0) {
                        uri_list.add("s", uri);
                    }
                }
                results.insert("uris", uri_list.end());
                return 0;
            } catch (Error e) {
                warning("FileChooserPortal: failed to read result: %s", e.message);
                FileUtils.unlink(result_path);
                return 2;
            }
        }
    }
}
