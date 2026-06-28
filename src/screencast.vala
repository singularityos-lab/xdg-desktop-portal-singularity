using GLib;

namespace Singularity.Portal {

    // C backend bindings
    [CCode (cname = "screencast_backend_new", cheader_filename = "screencast_backend.h")]
    private extern void* screencast_backend_new ();
    [CCode (cname = "screencast_backend_free", cheader_filename = "screencast_backend.h")]
    private extern void screencast_backend_free (void* b);
    [CCode (cname = "screencast_backend_get_available_source_types", cheader_filename = "screencast_backend.h")]
    private extern uint32 screencast_backend_get_available_source_types (void* b);
    [CCode (cname = "screencast_backend_is_healthy", cheader_filename = "screencast_backend.h")]
    private extern bool screencast_backend_is_healthy (void* b);
    [CCode (cname = "screencast_backend_has_failed", cheader_filename = "screencast_backend.h")]
    private extern bool screencast_backend_has_failed (void* b);
    [CCode (cname = "screencast_backend_list_sources_json", cheader_filename = "screencast_backend.h")]
    private extern string? screencast_backend_list_sources_json (void* b, uint32 requested_types);
    [CCode (cname = "screencast_backend_start", cheader_filename = "screencast_backend.h")]
    private extern int screencast_backend_start (void* b, uint32 source_type, string source_id, bool paint_cursors);
    [CCode (cname = "screencast_backend_stop", cheader_filename = "screencast_backend.h")]
    private extern void screencast_backend_stop (void* b);
    [CCode (cname = "screencast_backend_get_node_id", cheader_filename = "screencast_backend.h")]
    private extern uint32 screencast_backend_get_node_id (void* b);
    [CCode (cname = "screencast_backend_get_pw_fd", cheader_filename = "screencast_backend.h")]
    private extern int screencast_backend_get_pw_fd (void* b);

    private const uint32 SOURCE_MONITOR = 1u;
    private const uint32 SOURCE_WINDOW = 2u;
    private const uint32 CURSOR_HIDDEN = 1u;
    private const uint32 CURSOR_EMBEDDED = 2u;

    private class ScreenCastSelection : Object {
        public uint32 source_type;
        public string source_id;

        public ScreenCastSelection (uint32 source_type, string source_id) {
            this.source_type = source_type;
            this.source_id = source_id;
        }
    }

    /**
     * Per-session state for active ScreenCast sessions.
     * Each session has its own async resume callbacks so concurrent
     * sessions don't clobber each other.
     */
    private class ScreenCastSessionState : Object {
        public uint32 source_type = 0;
        public string source_id = "";
        public uint32 requested_types = SOURCE_MONITOR;
        public uint32 cursor_mode = CURSOR_HIDDEN;
        public uint32 node_id     = 0xffffffffu;
        public bool   running     = false;
        public bool   closed      = false;
        public SourceFunc? start_resume;
        public int          start_tick;
    }

    /**
     * D-Bus session object for ScreenCast.
     * Emitted when the frontend or the backend closes a session.
     */
    [DBus (name = "org.freedesktop.impl.portal.Session")]
    public class ScreenCastSession : Object {

        // org.freedesktop.impl.portal.Session.Closed takes no arguments.
        public signal void closed ();

        private weak ScreenCastPortal _portal;
        private string                _handle;

        public ScreenCastSession (ScreenCastPortal portal, string handle) {
            _portal = portal;
            _handle = handle;
        }

        public void close () throws GLib.Error {
            _portal._close_session (_handle);
            closed ();
        }
    }

    /**
     * Implements the org.freedesktop.impl.portal.ScreenCast interface.
     *
     * Allows applications to request screen sharing via wlr-screencopy
     * and PipeWire.
     */
    [DBus (name = "org.freedesktop.impl.portal.ScreenCast")]
    public class ScreenCastPortal : Object {

        private GLib.Application?                            _app;
        private void*                                        _backend;
        private DBusConnection?                              _conn;
        private HashTable<string, ScreenCastSessionState>    _states;
        private HashTable<string, ScreenCastSession>         _sessions;
        private HashTable<string, uint>                      _session_reg_ids;
        private string?                                      _active_session_handle;

        // Impl-portal capability properties read by the xdg-desktop-portal
        // frontend. Without these the frontend can't advertise ScreenCast to
        // apps. Bitmask values per the portal spec.
        //   SourceTypes: MONITOR=1, WINDOW=2, VIRTUAL=4
        //   CursorModes: HIDDEN=1, EMBEDDED=2, METADATA=4
        public uint AvailableSourceTypes {
            get {
                return (ensure_backend () != null)
                    ? screencast_backend_get_available_source_types (_backend) : 0u;
            }
        }
        public uint AvailableCursorModes { get { return CURSOR_HIDDEN | CURSOR_EMBEDDED; } }
        public uint version { get { return 3u; } }

        public ScreenCastPortal (GLib.Application? app = null) {
            _app             = app;
            _states          = new HashTable<string, ScreenCastSessionState> (str_hash, str_equal);
            _sessions        = new HashTable<string, ScreenCastSession>      (str_hash, str_equal);
            _session_reg_ids = new HashTable<string, uint>                   (str_hash, str_equal);
            _backend         = screencast_backend_new ();
            if (_backend == null)
                warning ("ScreenCastPortal: backend not ready at startup, will retry on first request");
        }

        private void* ensure_backend () {
            if (_backend != null && !screencast_backend_is_healthy (_backend)) {
                warning ("ScreenCastPortal: recreating failed screencast backend");
                _reset_backend ();
            }
            if (_backend == null)
                _backend = screencast_backend_new ();
            return _backend;
        }

        private void _reset_backend () {
            if (_active_session_handle != null) {
                var old_state = _states.lookup (_active_session_handle);
                if (old_state != null)
                    old_state.running = false;
            }
            if (_backend != null) {
                screencast_backend_free (_backend);
                _backend = null;
            }
            _active_session_handle = null;
            _backend = screencast_backend_new ();
            if (_backend == null)
                warning ("ScreenCastPortal: failed to recreate screencast backend");
        }

        ~ScreenCastPortal () {
            if (_backend != null) {
                screencast_backend_free (_backend);
                _backend = null;
            }
        }

        [DBus (visible = false)]
        public void register_on (DBusConnection conn) {
            _conn = conn;
        }

        /** Creates a new ScreenCast session. */
        public async void create_session (
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);

            var state   = new ScreenCastSessionState ();
            var session = new ScreenCastSession (this, (string) session_handle);
            _states.insert  ((string) session_handle, state);
            _sessions.insert ((string) session_handle, session);

            if (_conn != null) {
                try {
                    uint reg_id = _conn.register_object (
                        (string) session_handle, session);
                    _session_reg_ids.insert ((string) session_handle, reg_id);
                } catch (Error e) {
                    warning ("ScreenCastPortal: register session object: %s", e.message);
                }
            }

            results.insert ("session_handle",
                new Variant.object_path ((string) session_handle));
            response = 0;
        }

        /** Prompts the user to select a screen source for the session. */
        public async void select_sources (
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results  = new HashTable<string, Variant> (str_hash, str_equal);
            var state = _states.lookup ((string) session_handle);
            if (state == null) { response = 2; return; }

            uint32 requested_types = _get_uint_option (options, "types", SOURCE_MONITOR);
            uint32 cursor_mode = _get_uint_option (options, "cursor_mode", CURSOR_HIDDEN);
            if (cursor_mode != CURSOR_HIDDEN && cursor_mode != CURSOR_EMBEDDED) {
                response = 2;
                return;
            }

            uint32 available = (ensure_backend () != null)
                ? screencast_backend_get_available_source_types (_backend) : 0u;
            requested_types &= available;
            if (requested_types == 0) {
                response = 2;
                return;
            }

            ScreenCastSelection? chosen = yield _show_source_picker (requested_types);
            if (chosen == null) { response = 1; return; }

            state.source_type = chosen.source_type;
            state.source_id = chosen.source_id;
            state.requested_types = requested_types;
            state.cursor_mode = cursor_mode;
            response = 0;
        }

        /** Starts capturing the selected output and exports via PipeWire. */
        public async void start (
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results  = new HashTable<string, Variant> (str_hash, str_equal);
            var state = _states.lookup ((string) session_handle);

            string current_handle = (string) session_handle;
            if (state == null || state.closed || state.source_id == "" || ensure_backend () == null) {
                response = 2;
                return;
            }

            if (_active_session_handle != null && _active_session_handle != current_handle) {
                var old_state = _states.lookup (_active_session_handle);
                if (old_state != null)
                    old_state.running = false;
                if (_backend != null)
                    screencast_backend_stop (_backend);
                message ("ScreenCastPortal: stopped previous active session %s",
                    _active_session_handle);
                _active_session_handle = null;
            }

            bool paint_cursors = state.cursor_mode == CURSOR_EMBEDDED;
            int rc = screencast_backend_start (_backend, state.source_type,
                state.source_id, paint_cursors);
            if (rc != 0) {
                if (_backend != null && !screencast_backend_is_healthy (_backend))
                    _reset_backend ();
                response = 2;
                return;
            }
            state.running = true;
            _active_session_handle = current_handle;

            // Poll for node_id: PipeWire connects asynchronously
            state.start_tick   = 0;
            state.start_resume = start.callback;
            GLib.Timeout.add (10, () => {
                return _poll_node_id (state);
            });
            yield;

            if (state.closed) {
                if (_active_session_handle == current_handle && _backend != null) {
                    screencast_backend_stop (_backend);
                    _active_session_handle = null;
                }
                state.running = false;
                response = 2;
                return;
            }

            if (_backend == null || screencast_backend_has_failed (_backend)) {
                warning ("ScreenCastPortal: backend failed before PipeWire node_id");
                if (_backend != null && !screencast_backend_is_healthy (_backend)) {
                    _reset_backend ();
                } else if (_active_session_handle == current_handle && _backend != null) {
                    screencast_backend_stop (_backend);
                    _active_session_handle = null;
                }
                state.running = false;
                response = 2;
                return;
            }

            uint32 nid = screencast_backend_get_node_id (_backend);
            if (nid == 0xffffffffu) {
                warning ("ScreenCastPortal: timed out waiting for PipeWire node_id");
                if (_backend != null && !screencast_backend_is_healthy (_backend)) {
                    _reset_backend ();
                } else if (_active_session_handle == current_handle && _backend != null) {
                    screencast_backend_stop (_backend);
                    _active_session_handle = null;
                }
                state.running = false;
                response = 2;
                return;
            }

            state.node_id = nid;

            // Build streams as a(ua{sv}). The per-stream a{sv} must be built
            // with a VariantBuilder and spliced in with @a{sv}; passing a
            // HashTable straight into the "(ua{sv})" format yields an invalid
            // variant and crashes in g_variant_builder_end.
            var props_builder = new VariantBuilder (new VariantType ("a{sv}"));
            props_builder.add ("{sv}", "source_type", new Variant.uint32 (state.source_type));

            var stream_entry = new Variant ("(u@a{sv})", nid, props_builder.end ());
            var streams_builder = new VariantBuilder (new VariantType ("a(ua{sv})"));
            streams_builder.add_value (stream_entry);
            results.insert ("streams", streams_builder.end ());
            response = 0;
        }

        /** Opens a PipeWire remote fd for the given session (called via D-Bus filter). */
        [DBus (visible = false)]
        public int open_pipewire_remote_fd (ObjectPath session_handle) throws Error {
            string current_handle = (string) session_handle;
            var state = _states.lookup (current_handle);
            if (state == null || state.closed ||
                _active_session_handle != current_handle || ensure_backend () == null)
                throw new IOError.FAILED ("ScreenCastPortal: invalid session");
            int raw_fd = screencast_backend_get_pw_fd (_backend);
            if (raw_fd < 0)
                throw new IOError.FAILED ("ScreenCastPortal: failed to open PipeWire remote fd");
            return raw_fd;
        }

        [DBus (visible = false)]
        public void _close_session (string session_handle) {
            var state = _states.lookup (session_handle);
            if (state != null) {
                state.closed = true;
                if (_active_session_handle == session_handle && _backend != null) {
                    screencast_backend_stop (_backend);
                    _active_session_handle = null;
                }
                state.running = false;
                _fire_resume (ref state.start_resume);
            }

            uint reg_id = _session_reg_ids.lookup (session_handle);
            if (reg_id != 0 && _conn != null) {
                _conn.unregister_object (reg_id);
                _session_reg_ids.remove (session_handle);
            }

            _states.remove   (session_handle);
            _sessions.remove (session_handle);
        }

        // Poll for PipeWire node_id after start
        private bool _poll_node_id (ScreenCastSessionState state) {
            if (state.closed) {
                _fire_resume (ref state.start_resume);
                return false;
            }
            if (_backend == null || screencast_backend_has_failed (_backend)) {
                _fire_resume (ref state.start_resume);
                return false;
            }
            if (_backend != null && screencast_backend_get_node_id (_backend) != 0xffffffffu) {
                _fire_resume (ref state.start_resume);
                return false;
            }
            if (++state.start_tick > 500) {
                _fire_resume (ref state.start_resume);
                return false;
            }
            return true;
        }

        private static void _fire_resume (ref SourceFunc? resume) {
            if (resume != null) {
                SourceFunc cb = (owned) resume;
                resume = null;
                cb ();
            }
        }

        private static uint32 _get_uint_option (HashTable<string, Variant> options,
                                                string key,
                                                uint32 fallback) {
            Variant? value = options.lookup (key);
            return value != null ? value.get_uint32 () : fallback;
        }

        // Run the source chooser as a separate process and read the selected
        // source from its stdout (empty == cancelled). The chooser must NOT run
        // in this daemon: GTK's init queries the Settings portal, which loops
        // back to our own (then-blocked) Settings impl and deadlocks for 25s.
        private async ScreenCastSelection? _show_source_picker (uint32 requested_types) {
            if (ensure_backend () == null) return null;

            string? sources_json = screencast_backend_list_sources_json (_backend, requested_types);
            if (sources_json == null) return null;
            string[] argv = { _resolve_chooser_bin () };

            try {
                var proc = new Subprocess.newv (argv,
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
                string? out_buf = null;
                yield proc.communicate_utf8_async (sources_json, null, out out_buf, null);
                if (out_buf == null) return null;
                string chosen = out_buf.strip ();
                if (chosen == "") return null;

                var parser = new Json.Parser ();
                parser.load_from_data (chosen);
                Json.Object obj = parser.get_root ().get_object ();
                uint32 source_type = (uint32) obj.get_int_member ("type");
                string source_id = obj.get_string_member ("id");
                if (source_id == "") return null;
                return new ScreenCastSelection (source_type, source_id);
            } catch (Error e) {
                warning ("ScreenCastPortal: failed to launch chooser: %s", e.message);
                return null;
            }
        }

        // Locate singularity-screencast-chooser next to our own executable
        // (both land in the same bin dir when deployed), falling back to the
        // install prefix and finally PATH.
        private string _resolve_chooser_bin () {
            string bin = "singularity-screencast-chooser";
            try {
                string exe = GLib.FileUtils.read_link ("/proc/self/exe");
                string cand = GLib.Path.build_filename (GLib.Path.get_dirname (exe), bin);
                if (GLib.FileUtils.test (cand, GLib.FileTest.IS_EXECUTABLE)) return cand;
            } catch (Error e) { }
            string opt = "/opt/local/bin/" + bin;
            if (GLib.FileUtils.test (opt, GLib.FileTest.IS_EXECUTABLE)) return opt;
            return bin;
        }
    }
}
