using GLib;

namespace Singularity.Portal {

    [CCode (cname = "screencast_backend_new", cheader_filename = "screencast_backend.h")]
    private extern void* screencast_backend_new ();
    [CCode (cname = "screencast_backend_free", cheader_filename = "screencast_backend.h")]
    private extern void screencast_backend_free (void* backend);
    [CCode (cname = "screencast_backend_is_healthy", cheader_filename = "screencast_backend.h")]
    private extern bool screencast_backend_is_healthy (void* backend);
    [CCode (cname = "screencast_backend_list_outputs", cheader_filename = "screencast_backend.h", array_length = false, array_null_terminated = true)]
    private extern string[] screencast_backend_list_outputs (void* backend);
    [CCode (cname = "screencast_backend_create_capture", cheader_filename = "screencast_backend.h")]
    private extern void* screencast_backend_create_capture (void* backend,
                                                            string output_name);
    [CCode (cname = "screencast_capture_stop", cheader_filename = "screencast_backend.h")]
    private extern void screencast_capture_stop (void* capture);
    [CCode (cname = "screencast_capture_free", cheader_filename = "screencast_backend.h")]
    private extern void screencast_capture_free (void* capture);
    [CCode (cname = "screencast_capture_get_node_id", cheader_filename = "screencast_backend.h")]
    private extern uint32 screencast_capture_get_node_id (void* capture);
    [CCode (cname = "screencast_capture_has_failed", cheader_filename = "screencast_backend.h")]
    private extern bool screencast_capture_has_failed (void* capture);

    /** A single capture owned by exactly one portal session. */
    public interface ScreenCastCapture : Object {
        public abstract uint32 node_id { get; }
        public abstract bool failed { get; }
        public abstract void stop ();
    }

    /** Boundary between portal policy and the Wayland/PipeWire capture engine. */
    public interface ScreenCastCaptureManager : Object {
        public abstract string[] list_outputs ();
        public abstract ScreenCastCapture? create_capture (string output_name);
    }

    /** Boundary around the out-of-process user interaction. */
    public interface ScreenCastChooser : Object {
        public abstract async string? choose (
            string[] outputs, Cancellable cancellable);
    }

    private class NativeScreenCastCapture : Object, ScreenCastCapture {
        private NativeScreenCastCaptureManager _manager;
        private void* _capture;
        private bool _stopped = false;

        public bool valid { get { return _capture != null; } }
        public uint32 node_id {
            get {
                return _capture != null
                    ? screencast_capture_get_node_id (_capture)
                    : 0xffffffffu;
            }
        }
        public bool failed {
            get {
                return _capture == null ||
                    screencast_capture_has_failed (_capture);
            }
        }

        public NativeScreenCastCapture (NativeScreenCastCaptureManager manager,
                                        string output_name) {
            _manager = manager;
            _capture = screencast_backend_create_capture (
                manager.native_handle, output_name);
            if (_capture != null)
                manager.capture_created ();
        }

        public void stop () {
            if (_capture == null || _stopped)
                return;
            _stopped = true;
            screencast_capture_stop (_capture);
        }

        ~NativeScreenCastCapture () {
            if (_capture != null) {
                stop ();
                screencast_capture_free (_capture);
                _capture = null;
                _manager.capture_destroyed ();
            }
        }
    }

    private class NativeScreenCastCaptureManager : Object, ScreenCastCaptureManager {
        private void* _inventory_backend;
        private uint _active_captures = 0;

        internal void* native_handle { get { return _inventory_backend; } }
        public NativeScreenCastCaptureManager () {
            _inventory_backend = screencast_backend_new ();
        }

        public string[] list_outputs () {
            _ensure_backend ();
            if (_inventory_backend == null)
                return {};
            return screencast_backend_list_outputs (_inventory_backend);
        }

        public ScreenCastCapture? create_capture (string output_name) {
            _ensure_backend ();
            var capture = new NativeScreenCastCapture (
                this, output_name);
            return capture.valid ? capture : null;
        }

        internal void capture_created () {
            _active_captures++;
        }

        internal void capture_destroyed () {
            assert (_active_captures > 0);
            _active_captures--;
        }

        private void _ensure_backend () {
            if (_inventory_backend != null &&
                (_active_captures != 0 ||
                 screencast_backend_is_healthy (_inventory_backend)))
                return;

            if (_inventory_backend != null)
                screencast_backend_free (_inventory_backend);
            _inventory_backend = screencast_backend_new ();
        }

        ~NativeScreenCastCaptureManager () {
            if (_inventory_backend != null) {
                screencast_backend_free (_inventory_backend);
                _inventory_backend = null;
            }
        }
    }

    private class SubprocessScreenCastChooser : Object, ScreenCastChooser {
        public async string? choose (
            string[] outputs, Cancellable cancellable) {
            string[] argv = { _resolve_chooser_bin () };
            foreach (unowned string output in outputs)
                argv += output;

            try {
                var process = new Subprocess.newv (argv,
                    SubprocessFlags.STDOUT_PIPE);
                ulong cancelled_id = cancellable.cancelled.connect (() => {
                    process.force_exit ();
                });
                string? stdout_buffer = null;
                try {
                    yield process.communicate_utf8_async (
                        null, cancellable,
                        out stdout_buffer, null);
                } finally {
                    cancellable.disconnect (cancelled_id);
                }
                if (!process.get_successful ()) {
                    warning ("ScreenCastPortal: chooser exited unsuccessfully");
                    return null;
                }
                if (stdout_buffer == null)
                    return null;
                string chosen = stdout_buffer.strip ();
                if (chosen == "")
                    return null;
                return chosen;
            } catch (IOError.CANCELLED caught) {
                return null;
            } catch (Error caught) {
                warning ("ScreenCastPortal: failed to run chooser: %s", caught.message);
                return null;
            }
        }

        private static string _resolve_chooser_bin () {
            const string binary = "singularity-screencast-chooser";
            try {
                string executable = FileUtils.read_link ("/proc/self/exe");
                string candidate = Path.build_filename (
                    Path.get_dirname (executable), binary);
                if (FileUtils.test (candidate, FileTest.IS_EXECUTABLE))
                    return candidate;
            } catch (Error caught) {
                // Fall through to the installed path and then PATH.
            }
            return binary;
        }
    }

    private class ScreenCastSessionState : Object {
        public string output_name = "";
        public bool select_called = false;
        public bool start_called = false;
        public bool closed = false;
        public ScreenCastCapture? capture;
        public SourceFunc? start_resume;
        public uint start_source_id = 0;
        public uint health_source_id = 0;
        public uint start_ticks = 0;
        public Cancellable? selection_cancellable;
        public Cancellable? start_cancellable;
    }

    [DBus (name = "org.freedesktop.impl.portal.Request")]
    public class ScreenCastRequest : Object {
        private weak ScreenCastPortal _portal;
        private string _handle;

        public ScreenCastRequest (ScreenCastPortal portal, string handle) {
            _portal = portal;
            _handle = handle;
        }

        public void close () throws Error {
            _portal._close_request (_handle);
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.Session")]
    public class ScreenCastSession : Object {
        public signal void closed ();

        private weak ScreenCastPortal _portal;
        private string _handle;

        [DBus (name = "version")]
        public uint version { get { return 1u; } }

        public ScreenCastSession (ScreenCastPortal portal, string handle) {
            _portal = portal;
            _handle = handle;
        }

        public void close () throws Error {
            _portal._close_session (_handle);
        }

        [DBus (visible = false)]
        internal void close_from_backend () {
            closed ();
            _portal._close_session (_handle);
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.ScreenCast")]
    public class ScreenCastPortal : Object {
        private GLib.Application? _app;
        private ScreenCastCaptureManager _manager;
        private ScreenCastChooser _chooser;
        private DBusConnection? _connection;
        private HashTable<string, ScreenCastSessionState> _states;
        private HashTable<string, ScreenCastSession> _sessions;
        private HashTable<string, uint> _session_registration_ids;
        private HashTable<string, ScreenCastRequest> _requests;
        private HashTable<string, Cancellable> _request_cancellables;
        private HashTable<string, uint> _request_registration_ids;

        public uint AvailableSourceTypes {
            get { return 1u; }
        }
        public uint AvailableCursorModes {
            get { return 1u; }
        }
        [DBus (name = "version")]
        public uint version { get { return 3u; } }

        public ScreenCastPortal (GLib.Application? app = null) {
            _app = app;
            _manager = new NativeScreenCastCaptureManager ();
            _chooser = new SubprocessScreenCastChooser ();
            _initialize ();
        }

        public ScreenCastPortal.with_adapters (ScreenCastCaptureManager manager,
                                               ScreenCastChooser chooser) {
            _manager = manager;
            _chooser = chooser;
            _initialize ();
        }

        private void _initialize () {
            _states = new HashTable<string, ScreenCastSessionState> (
                str_hash, str_equal);
            _sessions = new HashTable<string, ScreenCastSession> (
                str_hash, str_equal);
            _session_registration_ids = new HashTable<string, uint> (
                str_hash, str_equal);
            _requests = new HashTable<string, ScreenCastRequest> (
                str_hash, str_equal);
            _request_cancellables = new HashTable<string, Cancellable> (
                str_hash, str_equal);
            _request_registration_ids = new HashTable<string, uint> (
                str_hash, str_equal);
        }

        [DBus (visible = false)]
        public void register_on (DBusConnection connection) {
            _connection = connection;
        }

        public async void create_session (
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);
            string session_path = (string) session_handle;

            if (_states.contains (session_path)) {
                response = 2;
                return;
            }

            var state = new ScreenCastSessionState ();
            var session = new ScreenCastSession (this, session_path);
            _states.insert (session_path, state);
            _sessions.insert (session_path, session);

            if (_connection != null) {
                try {
                    uint registration_id = _connection.register_object (
                        session_path, session);
                    _session_registration_ids.insert (
                        session_path, registration_id);
                } catch (Error caught) {
                    warning ("ScreenCastPortal: register session object: %s",
                        caught.message);
                    _states.remove (session_path);
                    _sessions.remove (session_path);
                    response = 2;
                    return;
                }
            }

            response = 0;
        }

        public async void select_sources (
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);
            var state = _states.lookup ((string) session_handle);
            if (state == null || state.closed || state.select_called) {
                response = 2;
                return;
            }
            state.select_called = true;

            string request_path = (string) handle;
            var cancellable = _begin_request (request_path);
            if (cancellable == null) {
                response = 2;
                return;
            }
            state.selection_cancellable = cancellable;
            uint32 requested_types = _get_uint_option (options, "types", 1u);
            uint32 cursor_mode = _get_uint_option (options, "cursor_mode", 1u);
            if ((requested_types & 1u) == 0 || cursor_mode != 1u) {
                state.selection_cancellable = null;
                _end_request (request_path);
                response = 2;
                return;
            }

            string[] outputs = _manager.list_outputs ();
            if (outputs.length == 0) {
                message ("ScreenCastPortal: no outputs are currently available");
                state.selection_cancellable = null;
                _end_request (request_path);
                response = 2;
                return;
            }
            string? chosen;
            try {
                chosen = yield _chooser.choose (outputs, cancellable);
            } finally {
                state.selection_cancellable = null;
                _end_request (request_path);
            }
            if (state.closed || cancellable.is_cancelled () ||
                chosen == null) {
                response = cancellable.is_cancelled () ? 1u
                    : state.closed ? 2u : 1u;
                return;
            }

            bool offered = false;
            foreach (unowned string output in outputs) {
                if (output == chosen) {
                    offered = true;
                    break;
                }
            }
            if (!offered) {
                response = 2;
                return;
            }

            state.output_name = chosen;
            response = 0;
        }

        public async void start (
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);
            var state = _states.lookup ((string) session_handle);
            if (state == null || state.closed || state.start_called ||
                state.output_name == "") {
                response = 2;
                return;
            }
            state.start_called = true;

            state.capture = _manager.create_capture (state.output_name);
            if (state.capture == null) {
                response = 2;
                return;
            }

            string request_path = (string) handle;
            var cancellable = _begin_request (request_path);
            if (cancellable == null) {
                state.capture.stop ();
                state.capture = null;
                response = 2;
                return;
            }
            state.start_cancellable = cancellable;

            state.start_ticks = 0;
            state.start_resume = start.callback;
            state.start_source_id = Timeout.add (10, () => {
                return _poll_node_id (state);
            });
            ulong cancelled_id = cancellable.cancelled.connect (() => {
                if (state.start_source_id != 0) {
                    Source.remove (state.start_source_id);
                    state.start_source_id = 0;
                }
                if (state.capture != null)
                    state.capture.stop ();
                _fire_resume (ref state.start_resume);
            });
            yield;
            cancellable.disconnect (cancelled_id);
            state.start_cancellable = null;
            _end_request (request_path);

            if (cancellable.is_cancelled ()) {
                if (state.capture != null) {
                    state.capture.stop ();
                    state.capture = null;
                }
                response = 1;
                return;
            }
            if (state.closed || state.capture == null || state.capture.failed) {
                if (state.capture != null) {
                    state.capture.stop ();
                    state.capture = null;
                }
                response = 2;
                return;
            }

            uint32 node_id = state.capture.node_id;
            if (node_id == 0xffffffffu) {
                warning ("ScreenCastPortal: timed out waiting for PipeWire node id");
                state.capture.stop ();
                state.capture = null;
                response = 2;
                return;
            }

            var properties = new VariantBuilder (new VariantType ("a{sv}"));
            properties.add ("{sv}", "source_type",
                new Variant.uint32 (1u));
            var stream = new Variant ("(u@a{sv})", node_id, properties.end ());
            var streams = new VariantBuilder (new VariantType ("a(ua{sv})"));
            streams.add_value (stream);
            results.insert ("streams", streams.end ());
            string session_path = (string) session_handle;
            state.health_source_id = Timeout.add (250, () => {
                return _watch_capture (session_path, state);
            });
            response = 0;
        }

        [DBus (visible = false)]
        public void _close_session (string session_handle) {
            var state = _states.lookup (session_handle);
            if (state == null || state.closed)
                return;

            state.closed = true;
            if (state.selection_cancellable != null)
                state.selection_cancellable.cancel ();
            if (state.start_cancellable != null)
                state.start_cancellable.cancel ();
            if (state.start_source_id != 0) {
                Source.remove (state.start_source_id);
                state.start_source_id = 0;
            }
            if (state.health_source_id != 0) {
                Source.remove (state.health_source_id);
                state.health_source_id = 0;
            }
            if (state.capture != null) {
                state.capture.stop ();
                state.capture = null;
            }
            _fire_resume (ref state.start_resume);

            uint registration_id = _session_registration_ids.lookup (
                session_handle);
            if (registration_id != 0 && _connection != null) {
                _connection.unregister_object (registration_id);
                _session_registration_ids.remove (session_handle);
            }

            _states.remove (session_handle);
            _sessions.remove (session_handle);
        }

        [DBus (visible = false)]
        public void _close_request (string request_handle) {
            var cancellable = _request_cancellables.lookup (request_handle);
            if (cancellable == null)
                return;
            cancellable.cancel ();
            _end_request (request_handle);
        }

        private Cancellable? _begin_request (string request_handle) {
            if (_requests.contains (request_handle))
                return null;

            var cancellable = new Cancellable ();
            var request = new ScreenCastRequest (this, request_handle);
            _requests.insert (request_handle, request);
            _request_cancellables.insert (request_handle, cancellable);

            if (_connection != null) {
                try {
                    uint registration_id = _connection.register_object (
                        request_handle, request);
                    _request_registration_ids.insert (
                        request_handle, registration_id);
                } catch (Error caught) {
                    warning ("ScreenCastPortal: register request object: %s",
                        caught.message);
                    _requests.remove (request_handle);
                    _request_cancellables.remove (request_handle);
                    return null;
                }
            }

            return cancellable;
        }

        private void _end_request (string request_handle) {
            uint registration_id = _request_registration_ids.lookup (
                request_handle);
            if (registration_id != 0 && _connection != null) {
                _connection.unregister_object (registration_id);
                _request_registration_ids.remove (request_handle);
            }
            _request_cancellables.remove (request_handle);
            _requests.remove (request_handle);
        }

        private bool _poll_node_id (ScreenCastSessionState state) {
            if (state.closed ||
                (state.start_cancellable != null &&
                    state.start_cancellable.is_cancelled ()) ||
                state.capture == null || state.capture.failed ||
                state.capture.node_id != 0xffffffffu || ++state.start_ticks > 500) {
                state.start_source_id = 0;
                _fire_resume (ref state.start_resume);
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        }

        private bool _watch_capture (string session_handle,
                                     ScreenCastSessionState state) {
            if (state.closed || state.capture == null)
                return Source.REMOVE;
            if (!state.capture.failed)
                return Source.CONTINUE;

            state.health_source_id = 0;
            ScreenCastSession? session = _sessions.lookup (session_handle);
            if (session != null)
                session.close_from_backend ();
            else
                _close_session (session_handle);
            return Source.REMOVE;
        }

        private static void _fire_resume (ref SourceFunc? resume) {
            if (resume != null) {
                SourceFunc callback = (owned) resume;
                resume = null;
                Idle.add ((owned) callback);
            }
        }

        private static uint32 _get_uint_option (
            HashTable<string, Variant> options,
            string key,
            uint32 fallback) {
            Variant? value = options.lookup (key);
            return value != null && value.is_of_type (VariantType.UINT32)
                ? value.get_uint32 () : fallback;
        }

    }
}
