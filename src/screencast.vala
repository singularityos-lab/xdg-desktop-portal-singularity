using GLib;

namespace Singularity.Portal {

    [CCode (cname = "screencast_backend_new", cheader_filename = "screencast_backend.h")]
    private extern void* screencast_backend_new ();
    [CCode (cname = "screencast_backend_free", cheader_filename = "screencast_backend.h")]
    private extern void screencast_backend_free (void* backend);
    [CCode (cname = "screencast_backend_get_available_source_types", cheader_filename = "screencast_backend.h")]
    private extern uint32 screencast_backend_get_available_source_types (
        void* backend);
    [CCode (cname = "screencast_backend_list_sources_json", cheader_filename = "screencast_backend.h")]
    private extern string? screencast_backend_list_sources_json (
        void* backend, uint32 requested_types);
    [CCode (cname = "screencast_backend_create_capture", cheader_filename = "screencast_backend.h")]
    private extern void* screencast_backend_create_capture (void* backend,
                                                            uint32 source_type,
                                                            string source_id,
                                                            bool paint_cursors);
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
        public abstract uint32 available_source_types { get; }
        public abstract ScreenCastSource[] list_sources (uint32 requested_types);
        public abstract ScreenCastCapture? create_capture (
            uint32 source_type, string source_id, bool paint_cursors);
    }

    /** Boundary around the out-of-process user interaction. */
    public interface ScreenCastChooser : Object {
        public abstract async ScreenCastChooserResult choose (
            ScreenCastSource[] sources, Cancellable cancellable);
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
                                        uint32 source_type,
                                        string source_id,
                                        bool paint_cursors) {
            _manager = manager;
            _capture = screencast_backend_create_capture (
                manager.native_handle, source_type, source_id, paint_cursors);
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
        public uint32 available_source_types {
            get {
                _ensure_backend ();
                return _inventory_backend != null
                    ? screencast_backend_get_available_source_types (
                        _inventory_backend) : 0u;
            }
        }

        public NativeScreenCastCaptureManager () {
            _inventory_backend = screencast_backend_new ();
        }

        public ScreenCastSource[] list_sources (uint32 requested_types) {
            _ensure_backend ();
            if (_inventory_backend == null)
                return {};
            string? json = screencast_backend_list_sources_json (
                _inventory_backend, requested_types);
            return json != null
                ? ScreenCastJson.decode_sources (json)
                : new ScreenCastSource[0];
        }

        public ScreenCastCapture? create_capture (uint32 source_type,
                                                  string source_id,
                                                  bool paint_cursors) {
            _ensure_backend ();
            var capture = new NativeScreenCastCapture (
                this, source_type, source_id, paint_cursors);
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
                 screencast_backend_get_available_source_types (
                    _inventory_backend) != 0))
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
        public async ScreenCastChooserResult choose (
            ScreenCastSource[] sources, Cancellable cancellable) {
            string[] argv = { _resolve_chooser_bin () };

            try {
                var process = new Subprocess.newv (argv,
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
                ulong cancelled_id = cancellable.cancelled.connect (() => {
                    process.force_exit ();
                });
                string? stdout_buffer = null;
                try {
                    yield process.communicate_utf8_async (
                        ScreenCastJson.encode_sources (sources), cancellable,
                        out stdout_buffer, null);
                } finally {
                    cancellable.disconnect (cancelled_id);
                }
                if (!process.get_successful ()) {
                    warning ("ScreenCastPortal: chooser exited unsuccessfully");
                    return new ScreenCastChooserResult (
                        ScreenCastChooserStatus.FAILED);
                }
                if (stdout_buffer == null)
                    return new ScreenCastChooserResult (
                        ScreenCastChooserStatus.CANCELLED);
                string chosen = stdout_buffer.strip ();
                if (chosen == "")
                    return new ScreenCastChooserResult (
                        ScreenCastChooserStatus.CANCELLED);
                ScreenCastSelection? selection =
                    ScreenCastJson.decode_selection (chosen);
                if (selection == null) {
                    warning ("ScreenCastPortal: chooser returned malformed output");
                    return new ScreenCastChooserResult (
                        ScreenCastChooserStatus.FAILED);
                }
                return new ScreenCastChooserResult (
                    ScreenCastChooserStatus.SELECTED, selection);
            } catch (IOError.CANCELLED caught) {
                return new ScreenCastChooserResult (
                    ScreenCastChooserStatus.CANCELLED);
            } catch (Error caught) {
                warning ("ScreenCastPortal: failed to run chooser: %s", caught.message);
                return new ScreenCastChooserResult (
                    ScreenCastChooserStatus.FAILED);
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
        public uint32 source_type = 0;
        public string source_id = "";
        public uint32 requested_types = SCREENCAST_SOURCE_MONITOR;
        public uint32 cursor_mode = SCREENCAST_CURSOR_HIDDEN;
        public bool multiple = false;
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
            get { return _manager.available_source_types; }
        }
        public uint AvailableCursorModes {
            get {
                return _manager.available_source_types != 0
                    ? SCREENCAST_CURSOR_HIDDEN | SCREENCAST_CURSOR_EMBEDDED
                    : 0u;
            }
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
            uint32 requested_types = _get_uint_option (
                options, "types", SCREENCAST_SOURCE_MONITOR);
            requested_types &= _manager.available_source_types;
            uint32 cursor_mode = _get_uint_option (
                options, "cursor_mode", SCREENCAST_CURSOR_HIDDEN);
            if (requested_types == 0 ||
                (cursor_mode != SCREENCAST_CURSOR_HIDDEN &&
                 cursor_mode != SCREENCAST_CURSOR_EMBEDDED)) {
                state.selection_cancellable = null;
                _end_request (request_path);
                response = 2;
                return;
            }

            ScreenCastSource[] sources = _manager.list_sources (requested_types);
            if (sources.length == 0) {
                message ("ScreenCastPortal: no sources are currently available");
                state.selection_cancellable = null;
                _end_request (request_path);
                response = 2;
                return;
            }
            ScreenCastChooserResult choice;
            try {
                choice = yield _chooser.choose (sources, cancellable);
            } finally {
                state.selection_cancellable = null;
                _end_request (request_path);
            }
            if (state.closed || cancellable.is_cancelled () ||
                choice.status == ScreenCastChooserStatus.CANCELLED) {
                response = cancellable.is_cancelled () ? 1u
                    : state.closed ? 2u : 1u;
                return;
            }
            ScreenCastSelection? chosen = choice.selection;
            if (choice.status != ScreenCastChooserStatus.SELECTED ||
                chosen == null) {
                response = 2;
                return;
            }

            bool offered = false;
            foreach (unowned ScreenCastSource source in sources) {
                if (source.source_type == chosen.source_type &&
                    source.source_id == chosen.source_id &&
                    (requested_types & source.source_type) != 0) {
                    offered = true;
                    break;
                }
            }
            if (!offered) {
                response = 2;
                return;
            }

            state.source_type = chosen.source_type;
            state.source_id = chosen.source_id;
            state.requested_types = requested_types;
            state.cursor_mode = cursor_mode;
            state.multiple = _get_bool_option (options, "multiple", false);
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
                state.source_id == "") {
                response = 2;
                return;
            }
            state.start_called = true;

            state.capture = _manager.create_capture (
                state.source_type,
                state.source_id,
                state.cursor_mode == SCREENCAST_CURSOR_EMBEDDED);
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
                new Variant.uint32 (state.source_type));
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

        private static bool _get_bool_option (
            HashTable<string, Variant> options,
            string key,
            bool fallback) {
            Variant? value = options.lookup (key);
            return value != null && value.is_of_type (VariantType.BOOLEAN)
                ? value.get_boolean () : fallback;
        }
    }
}
