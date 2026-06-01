using GLib;
using Gtk;

namespace Singularity.Portal {

    // C backend bindings
    [CCode (cname = "screencast_backend_new", cheader_filename = "screencast_backend.h")]
    private extern void* screencast_backend_new ();
    [CCode (cname = "screencast_backend_free", cheader_filename = "screencast_backend.h")]
    private extern void screencast_backend_free (void* b);
    [CCode (cname = "screencast_backend_list_outputs", cheader_filename = "screencast_backend.h", array_length = false, array_null_terminated = true)]
    private extern string[] screencast_backend_list_outputs (void* b);
    [CCode (cname = "screencast_backend_start", cheader_filename = "screencast_backend.h")]
    private extern int screencast_backend_start (void* b, string output_name);
    [CCode (cname = "screencast_backend_stop", cheader_filename = "screencast_backend.h")]
    private extern void screencast_backend_stop (void* b);
    [CCode (cname = "screencast_backend_get_node_id", cheader_filename = "screencast_backend.h")]
    private extern uint32 screencast_backend_get_node_id (void* b);
    [CCode (cname = "screencast_backend_get_pw_fd", cheader_filename = "screencast_backend.h")]
    private extern int screencast_backend_get_pw_fd (void* b);

    /**
     * Per-session state for active ScreenCast sessions.
     * Each session has its own async resume callbacks so concurrent
     * sessions don't clobber each other.
     */
    private class ScreenCastSessionState : Object {
        public string output_name = "";
        public uint32 node_id     = 0xffffffffu;
        public bool   running     = false;
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
        private bool                                         _gtk_inited = false;

        // Impl-portal capability properties read by the xdg-desktop-portal
        // frontend. Without these the frontend can't advertise ScreenCast to
        // apps. Bitmask values per the portal spec.
        //   SourceTypes: MONITOR=1, WINDOW=2, VIRTUAL=4  (we capture outputs)
        //   CursorModes: HIDDEN=1, EMBEDDED=2, METADATA=4
        public uint AvailableSourceTypes { get { return 1u; } }
        public uint AvailableCursorModes { get { return 1u; } }   // hidden
        public uint version { get { return 2u; } }

        public ScreenCastPortal (GLib.Application? app = null) {
            _app             = app;
            _states          = new HashTable<string, ScreenCastSessionState> (str_hash, str_equal);
            _sessions        = new HashTable<string, ScreenCastSession>      (str_hash, str_equal);
            _session_reg_ids = new HashTable<string, uint>                   (str_hash, str_equal);
            _backend         = screencast_backend_new ();
            if (_backend == null)
                warning ("ScreenCastPortal: backend init failed (no compositor/PipeWire?)");
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

            string? chosen = yield _show_source_picker ();
            if (chosen == null) { response = 1; return; }

            state.output_name = chosen;
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

            if (state == null || state.output_name == "" || _backend == null) {
                response = 2;
                return;
            }

            int rc = screencast_backend_start (_backend, state.output_name);
            if (rc != 0) { response = 2; return; }
            state.running = true;

            // Poll for node_id: PipeWire connects asynchronously
            state.start_tick   = 0;
            state.start_resume = start.callback;
            GLib.Timeout.add (10, () => {
                return _poll_node_id (state);
            });
            yield;

            uint32 nid = screencast_backend_get_node_id (_backend);
            if (nid == 0xffffffffu) {
                warning ("ScreenCastPortal: timed out waiting for PipeWire node_id");
                screencast_backend_stop (_backend);
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
            props_builder.add ("{sv}", "source_type", new Variant.uint32 (1u));

            var stream_entry = new Variant ("(u@a{sv})", nid, props_builder.end ());
            var streams_builder = new VariantBuilder (new VariantType ("a(ua{sv})"));
            streams_builder.add_value (stream_entry);
            results.insert ("streams", streams_builder.end ());
            response = 0;
        }

        /** Opens a PipeWire remote fd for the given session (called via D-Bus filter). */
        [DBus (visible = false)]
        public int open_pipewire_remote_fd (ObjectPath session_handle) throws Error {
            var state = _states.lookup ((string) session_handle);
            if (state == null || _backend == null)
                throw new IOError.FAILED ("ScreenCastPortal: invalid session");
            int raw_fd = screencast_backend_get_pw_fd (_backend);
            if (raw_fd < 0)
                throw new IOError.FAILED ("ScreenCastPortal: failed to open PipeWire remote fd");
            return raw_fd;
        }

        [DBus (visible = false)]
        public void _close_session (string session_handle) {
            var state = _states.lookup (session_handle);
            if (state != null && state.running && _backend != null) {
                screencast_backend_stop (_backend);
                state.running = false;
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

        private async string? _show_source_picker () {
            if (_backend == null) return null;

            // The daemon runs a raw GLib main loop with no GApplication, so GTK
            // is never initialised and the libsingularity theme is never loaded.
            // Do both lazily here (guarded) the first time we show the picker;
            // otherwise the dialog crashes (null GdkDisplay) or renders as
            // unstyled stock GTK instead of inheriting the Singularity look.
            if (!_gtk_inited) {
                Gtk.init ();
                var gs = Gtk.Settings.get_default ();
                if (gs != null) gs.gtk_theme_name = "Singularity";
                var sm = Singularity.Style.StyleManager.get_default ();
                sm.load_theme ();
                try {
                    var ds = new GLib.Settings ("dev.sinty.desktop");
                    sm.apply_color_scheme (ds.get_boolean ("dark-mode"));
                    // Resolve the accent exactly like Singularity.Application:
                    // named swatch, "wallpaper" (sampled from the background),
                    // or "custom" (a stored hex).
                    string color_name = ds.get_string ("accent-color");
                    string? wallpaper_path = null;
                    if (color_name == "wallpaper") {
                        string uri = ds.get_string ("background-picture-uri");
                        if (uri != "")
                            wallpaper_path = GLib.File.new_for_uri (uri).get_path ();
                    } else if (color_name == "custom") {
                        string hex = ds.get_string ("custom-accent-color");
                        if (hex == null || hex == "") hex = "#3584e4";
                        color_name = hex;
                    }
                    sm.apply_accent_color (color_name, wallpaper_path);
                } catch (Error e) {
                    // desktop schema unavailable: keep StyleManager defaults
                }
                _gtk_inited = true;
            }

            string[] outputs = screencast_backend_list_outputs (_backend);
            var picker = new ScreenCastSourcePicker (_app, outputs);

            string? result = null;
            // Resume this coroutine from the picker's signals instead of
            // busy-polling on idle.
            picker.selected.connect ((name) => {
                result = name;
                _show_source_picker.callback ();
            });
            picker.cancelled.connect (() => {
                result = null;
                _show_source_picker.callback ();
            });
            picker.open_dialog ();
            yield;
            return result;
        }
    }
}