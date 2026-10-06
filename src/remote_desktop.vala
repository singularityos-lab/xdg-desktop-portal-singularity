using GLib;

namespace Singularity.Portal {

    public const uint32 REMOTE_DEVICE_KEYBOARD = 1;
    public const uint32 REMOTE_DEVICE_POINTER = 2;
    public const uint32 REMOTE_DEVICE_TOUCHSCREEN = 4;

    public class RemoteSessionState : Object {
        public string handle;
        public string app_id;
        public PortalSession session;
        public ScreenCastSession? screencast;
        public uint32 requested_devices = REMOTE_DEVICE_KEYBOARD | REMOTE_DEVICE_POINTER;
        public uint32 devices = 0;
        public bool devices_selected = false;
        public bool clipboard_requested = false;
        public bool clipboard_enabled = false;
        public bool started = false;
        public int64 started_at = 0;
        public string? output = null;
        public int x = 0;
        public int y = 0;
        public int width = 0;
        public int height = 0;
    }

    public interface RemoteInput : Object {
        public abstract bool available { get; }
        public abstract bool output_geometry (string? output, out int x, out int y, out int width, out int height);
        public abstract void motion (double dx, double dy);
        public abstract void motion_output (string? output, double x, double y);
        public abstract void button (uint32 button, bool pressed);
        public abstract void axis (uint32 axis, double value);
        public abstract void axis_discrete (uint32 axis, int steps);
        public abstract void keycode (uint32 keycode, bool pressed);
        public abstract bool keysym (uint32 keysym, bool pressed);
        public abstract void release_all ();
    }

    public class WaylandRemoteInput : Object, RemoteInput {
        internal Rd.Display? display = null;

        public bool available {
            get {
                ensure ();
                return display != null && display.can_inject ();
            }
        }

        internal void ensure () {
            if (display != null) return;
            try {
                display = new Rd.Display ();
            } catch (Error e) {
                warning ("RemoteDesktopPortal: %s", e.message);
            }
        }

        public bool output_geometry (string? output, out int x, out int y, out int width, out int height) {
            x = y = width = height = 0;
            ensure ();
            if (display == null) return false;
            string? name = output;
            if (name == null) {
                var names = display.get_outputs ();
                if (names.length == 0) return false;
                name = names[0];
            }
            string description;
            double scale;
            return display.get_output_info (name, out description, out x, out y, out width, out height, out scale);
        }

        public void motion (double dx, double dy) {
            if (available) display.pointer_motion (dx, dy);
        }

        public void motion_output (string? output, double x, double y) {
            if (available) display.pointer_motion_output (output, x, y);
        }

        public void button (uint32 button, bool pressed) {
            if (available) display.pointer_button (button, pressed);
        }

        public void axis (uint32 axis, double value) {
            if (available) display.pointer_axis (axis, value);
        }

        public void axis_discrete (uint32 axis, int steps) {
            if (available) display.pointer_axis_discrete (axis, steps);
        }

        public void keycode (uint32 keycode, bool pressed) {
            if (available) display.keycode (keycode, pressed);
        }

        public bool keysym (uint32 keysym, bool pressed) {
            return available && display.keysym (keysym, pressed);
        }

        public void release_all () {
            if (display != null) display.release_all ();
        }
    }

    [DBus (name = "dev.sinty.portal.RemoteSessions")]
    public class RemoteSessionsMonitor : Object {
        private weak RemoteDesktopPortal _portal;

        public signal void changed ();

        public RemoteSessionsMonitor (RemoteDesktopPortal portal) {
            _portal = portal;
        }

        public HashTable<string, Variant>[] list_sessions () throws Error {
            return _portal.describe_sessions ();
        }

        public void stop_session (string handle) throws Error {
            _portal.close_session (handle, true);
        }

        public void stop_all () throws Error {
            _portal.close_all ();
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.RemoteDesktop")]
    public class RemoteDesktopPortal : Object {
        private DBusConnection _conn;
        private ScreenCastPortal? _screencast;
        private ConsentRunner _consent;
        private RemoteInput _input;
        private HashTable<string, RemoteSessionState> _sessions =
            new HashTable<string, RemoteSessionState> (str_hash, str_equal);

        [DBus (visible = false)]
        public signal void sessions_changed ();
        [DBus (visible = false)]
        public signal void session_closed (string handle);

        public uint32 AvailableDeviceTypes {
            get { return REMOTE_DEVICE_KEYBOARD | REMOTE_DEVICE_POINTER; }
        }

        [DBus (name = "version")]
        public uint32 version { get { return 2; } }

        public RemoteDesktopPortal (DBusConnection conn, ScreenCastPortal? screencast) {
            this.with_adapters (conn, screencast, new SubprocessConsentRunner (), new WaylandRemoteInput ());
        }

        [DBus (visible = false)]
        public RemoteDesktopPortal.with_adapters (DBusConnection conn, ScreenCastPortal? screencast,
                                                  ConsentRunner consent, RemoteInput input) {
            _conn = conn;
            _screencast = screencast;
            _consent = consent;
            _input = input;
        }

        [DBus (visible = false)]
        public RemoteInput input { get { return _input; } }

        [DBus (visible = false)]
        public RemoteSessionState? lookup (string handle) {
            return _sessions.lookup (handle);
        }

        public async void create_session (ObjectPath handle, ObjectPath session_handle, string app_id,
                                          HashTable<string, Variant> options,
                                          out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);
            string path = (string) session_handle;
            if (_sessions.contains (path)) {
                response = 2;
                return;
            }
            var state = new RemoteSessionState ();
            state.handle = path;
            state.app_id = app_id;
            state.session = new PortalSession (_conn, session_handle, app_id);
            state.session.ended.connect (() => close_session (path, false));
            if (_screencast != null) {
                state.screencast = _screencast.adopt_session (path);
                state.screencast.closed.connect (() => close_session (path, true));
            }
            _sessions.insert (path, state);
            results.insert ("session_id", new Variant.string (path));
            response = 0;
        }

        public async void select_devices (ObjectPath handle, ObjectPath session_handle, string app_id,
                                          HashTable<string, Variant> options,
                                          out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);
            var state = _sessions.lookup ((string) session_handle);
            if (state == null || state.started) {
                response = 2;
                return;
            }
            Variant? types = options.lookup ("types");
            uint32 requested = types != null && types.is_of_type (VariantType.UINT32)
                ? types.get_uint32 () : AvailableDeviceTypes;
            state.requested_devices = requested & AvailableDeviceTypes;
            state.devices_selected = true;
            response = 0;
        }

        [DBus (visible = false)]
        public ConsentRequest consent_request (RemoteSessionState state) {
            var request = new ConsentRequest ();
            request.kind = "remote";
            request.app_id = state.app_id;
            string name = portal_app_name (state.app_id);
            request.app_name = name;
            request.icon = state.app_id != "" ? state.app_id : "preferences-desktop-remote-desktop";
            request.title = name != "" ? _("Let %s Control This Computer?").printf (name)
                : _("Let an App Control This Computer?");
            request.subtitle = _("It will be able to see the screen and use the mouse and keyboard.");
            request.body = _("You can stop it at any time from the top bar.");
            request.grant_label = _("Allow");
            request.deny_label = _("Deny");
            if ((state.requested_devices & REMOTE_DEVICE_POINTER) != 0)
                request.add_item (new ConsentItem ("pointer", _("Mouse"), _("Move the pointer and click")));
            if ((state.requested_devices & REMOTE_DEVICE_KEYBOARD) != 0)
                request.add_item (new ConsentItem ("keyboard", _("Keyboard"), _("Type and press shortcuts")));
            if (state.clipboard_requested)
                request.add_item (new ConsentItem ("clipboard", _("Clipboard"), _("Read and change what you copy")));
            return request;
        }

        public async void start (ObjectPath handle, ObjectPath session_handle, string app_id, string parent_window,
                                 HashTable<string, Variant> options,
                                 out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant> (str_hash, str_equal);
            string path = (string) session_handle;
            var state = _sessions.lookup (path);
            if (state == null || state.started) {
                response = 2;
                return;
            }
            if (!_input.available) {
                warning ("RemoteDesktopPortal: the compositor has no virtual input protocols");
                response = 2;
                return;
            }

            var request = new PortalRequest (_conn, handle);
            ConsentResult consent;
            try {
                consent = yield _consent.ask (consent_request (state), request.cancellable);
            } finally {
                request.unexport ();
            }
            if (request.cancellable.is_cancelled () || _sessions.lookup (path) != state) {
                response = 1;
                return;
            }
            if (!consent.granted) {
                response = consent.response == 0 ? 1 : consent.response;
                return;
            }

            uint32 devices = 0;
            if (consent.has_selected ("pointer")) devices |= REMOTE_DEVICE_POINTER;
            if (consent.has_selected ("keyboard")) devices |= REMOTE_DEVICE_KEYBOARD;
            state.devices = devices & state.requested_devices;
            state.clipboard_enabled = state.clipboard_requested && consent.has_selected ("clipboard");
            if (_screencast != null) state.output = _screencast.monitor_source (path);
            _input.output_geometry (state.output, out state.x, out state.y, out state.width, out state.height);

            if (_screencast != null && _screencast.has_sources (path)) {
                uint32 sc_response;
                HashTable<string, Variant> sc_results;
                yield _screencast.start (handle, session_handle, app_id, parent_window, options,
                    out sc_response, out sc_results);
                if (sc_response != 0) {
                    response = sc_response;
                    return;
                }
                Variant? streams = sc_results.lookup ("streams");
                if (streams != null)
                    results.insert ("streams", with_stream_size (streams, state.x, state.y, state.width, state.height));
            }

            state.started = true;
            state.started_at = get_real_time () / 1000000;
            results.insert ("devices", new Variant.uint32 (state.devices));
            results.insert ("clipboard_enabled", new Variant.boolean (state.clipboard_enabled));
            response = 0;
            message ("RemoteDesktopPortal: session %s of %s started (devices %u, clipboard %s)", path, app_id,
                state.devices, state.clipboard_enabled ? "yes" : "no");
            sessions_changed ();
        }

        [DBus (visible = false)]
        public static Variant with_stream_size (Variant streams, int x, int y, int width, int height) {
            var builder = new VariantBuilder (new VariantType ("a(ua{sv})"));
            var iter = streams.iterator ();
            uint32 node;
            Variant props;
            while (iter.next ("(u@a{sv})", out node, out props)) {
                var dict = new VariantDict (props);
                if (!dict.contains ("size") && width > 0 && height > 0)
                    dict.insert_value ("size", new Variant ("(ii)", width, height));
                if (!dict.contains ("position")) dict.insert_value ("position", new Variant ("(ii)", x, y));
                builder.add ("(u@a{sv})", node, dict.end ());
            }
            return builder.end ();
        }

        private RemoteSessionState? active (ObjectPath session_handle, uint32 device) {
            var state = _sessions.lookup ((string) session_handle);
            if (state == null || !state.started || (state.devices & device) == 0) return null;
            return state;
        }

        public void notify_pointer_motion (ObjectPath session_handle, HashTable<string, Variant> options,
                                           double dx, double dy) throws Error {
            if (active (session_handle, REMOTE_DEVICE_POINTER) != null) _input.motion (dx, dy);
        }

        public void notify_pointer_motion_absolute (ObjectPath session_handle, HashTable<string, Variant> options,
                                                    uint32 stream, double x, double y) throws Error {
            var state = active (session_handle, REMOTE_DEVICE_POINTER);
            if (state == null) return;
            _input.motion_output (state.output, x, y);
        }

        public void notify_pointer_button (ObjectPath session_handle, HashTable<string, Variant> options,
                                           int32 button, uint32 state) throws Error {
            if (active (session_handle, REMOTE_DEVICE_POINTER) != null && button > 0)
                _input.button ((uint32) button, state != 0);
        }

        public void notify_pointer_axis (ObjectPath session_handle, HashTable<string, Variant> options,
                                         double dx, double dy) throws Error {
            if (active (session_handle, REMOTE_DEVICE_POINTER) == null) return;
            if (dy != 0) _input.axis (0, dy);
            if (dx != 0) _input.axis (1, dx);
        }

        public void notify_pointer_axis_discrete (ObjectPath session_handle, HashTable<string, Variant> options,
                                                  uint32 axis, int32 steps) throws Error {
            if (active (session_handle, REMOTE_DEVICE_POINTER) != null) _input.axis_discrete (axis, steps);
        }

        public void notify_keyboard_keycode (ObjectPath session_handle, HashTable<string, Variant> options,
                                             int32 keycode, uint32 state) throws Error {
            if (active (session_handle, REMOTE_DEVICE_KEYBOARD) != null && keycode >= 0)
                _input.keycode ((uint32) keycode, state != 0);
        }

        public void notify_keyboard_keysym (ObjectPath session_handle, HashTable<string, Variant> options,
                                            int32 keysym, uint32 state) throws Error {
            if (active (session_handle, REMOTE_DEVICE_KEYBOARD) != null)
                _input.keysym ((uint32) keysym, state != 0);
        }

        public void notify_touch_down (ObjectPath session_handle, HashTable<string, Variant> options, uint32 stream,
                                       uint32 slot, double x, double y) throws Error {
            throw new DBusError.NOT_SUPPORTED ("Touch input is not available");
        }

        public void notify_touch_motion (ObjectPath session_handle, HashTable<string, Variant> options, uint32 stream,
                                         uint32 slot, double x, double y) throws Error {
            throw new DBusError.NOT_SUPPORTED ("Touch input is not available");
        }

        public void notify_touch_up (ObjectPath session_handle, HashTable<string, Variant> options,
                                     uint32 slot) throws Error {
            throw new DBusError.NOT_SUPPORTED ("Touch input is not available");
        }

        [DBus (visible = false)]
        public HashTable<string, Variant>[] describe_sessions () {
            HashTable<string, Variant>[] list = {};
            _sessions.foreach ((handle, state) => {
                if (!state.started) return;
                var t = new HashTable<string, Variant> (str_hash, str_equal);
                t["handle"] = handle;
                t["app_id"] = state.app_id;
                t["name"] = portal_app_name (state.app_id);
                t["devices"] = state.devices;
                t["clipboard"] = state.clipboard_enabled;
                t["started"] = state.started_at;
                list += t;
            });
            return list;
        }

        [DBus (visible = false)]
        public void close_session (string handle, bool notify) {
            var state = _sessions.lookup (handle);
            if (state == null) return;
            _sessions.remove (handle);
            bool was_started = state.started;
            state.started = false;
            _input.release_all ();
            if (_screencast != null) _screencast._close_session (handle);
            state.session.end (notify);
            session_closed (handle);
            if (was_started) {
                message ("RemoteDesktopPortal: session %s ended", handle);
                sessions_changed ();
            }
        }

        [DBus (visible = false)]
        public void close_all () {
            foreach (string handle in _sessions.get_keys ()) close_session (handle, true);
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.Clipboard")]
    public class ClipboardPortal : Object {
        private weak RemoteDesktopPortal _remote;
        private uint32 _next_serial = 1;
        private HashTable<uint32, int> _pending = new HashTable<uint32, int> (direct_hash, direct_equal);
        private string? _owner = null;
        private bool _watching = false;

        public signal void selection_owner_changed (ObjectPath session_handle, HashTable<string, Variant> options);
        public signal void selection_transfer (ObjectPath session_handle, string mime_type, uint32 serial);

        [DBus (name = "version")]
        public uint32 version { get { return 1; } }

        public ClipboardPortal (RemoteDesktopPortal remote) {
            _remote = remote;
            _remote.session_closed.connect ((handle) => {
                if (_owner == handle) _owner = null;
            });
        }

        private unowned Rd.Display? display () {
            var input = _remote.input as WaylandRemoteInput;
            if (input == null) return null;
            input.ensure ();
            if (input.display == null || !input.display.can_clipboard ()) return null;
            if (!_watching) {
                _watching = true;
                input.display.watch_clipboard (on_selection);
            }
            return input.display;
        }

        private RemoteSessionState? enabled (ObjectPath session_handle) {
            var state = _remote.lookup ((string) session_handle);
            if (state == null || !state.started || !state.clipboard_enabled) return null;
            return state;
        }

        public void request_clipboard (ObjectPath session_handle, HashTable<string, Variant> options) throws Error {
            var state = _remote.lookup ((string) session_handle);
            if (state == null || state.started) throw new DBusError.ACCESS_DENIED ("Invalid session");
            state.clipboard_requested = true;
            display ();
        }

        public void set_selection (ObjectPath session_handle, HashTable<string, Variant> options) throws Error {
            if (enabled (session_handle) == null) throw new DBusError.ACCESS_DENIED ("Clipboard not enabled");
            unowned Rd.Display? d = display ();
            if (d == null) throw new DBusError.NOT_SUPPORTED ("The compositor has no clipboard access");
            Variant? types = options.lookup ("mime_types");
            string[] mime_types = types != null && types.is_of_type (new VariantType ("as"))
                ? types.get_strv () : new string[0];
            _owner = (string) session_handle;
            debug ("ClipboardPortal: %s offers %s", _owner, string.joinv (", ", mime_types));
            d.offer_clipboard (mime_types.length > 0 ? mime_types : null, on_send);
        }

        private void on_send (string mime, int fd) {
            string? owner = _owner;
            if (owner == null || enabled (new ObjectPath (owner)) == null) {
                Posix.close (fd);
                return;
            }
            uint32 serial = _next_serial++;
            _pending.insert (serial, fd);
            selection_transfer (new ObjectPath (owner), mime, serial);
        }

        public UnixOutputStream selection_write (ObjectPath session_handle, uint32 serial) throws Error {
            if (enabled (session_handle) == null || _owner != (string) session_handle)
                throw new DBusError.ACCESS_DENIED ("Clipboard not owned by this session");
            if (!_pending.contains (serial)) throw new DBusError.INVALID_ARGS ("Unknown serial");
            int fd = _pending.lookup (serial);
            int copy = Posix.dup (fd);
            if (copy < 0) throw new IOError.FAILED ("Cannot pass the clipboard pipe");
            return new UnixOutputStream (copy, true);
        }

        public void selection_write_done (ObjectPath session_handle, uint32 serial, bool success) throws Error {
            if (!_pending.contains (serial)) return;
            Posix.close (_pending.lookup (serial));
            _pending.remove (serial);
        }

        public UnixInputStream selection_read (ObjectPath session_handle, string mime_type) throws Error {
            if (enabled (session_handle) == null) throw new DBusError.ACCESS_DENIED ("Clipboard not enabled");
            unowned Rd.Display? d = display ();
            if (d == null) throw new DBusError.NOT_SUPPORTED ("The compositor has no clipboard access");
            int fds[2];
            if (Posix.pipe (fds) != 0) throw new IOError.FAILED ("Cannot create a pipe");
            Posix.fcntl (fds[0], Posix.F_SETFD, Posix.FD_CLOEXEC);
            Posix.fcntl (fds[1], Posix.F_SETFD, Posix.FD_CLOEXEC);
            if (!d.receive_clipboard (mime_type, fds[1])) {
                Posix.close (fds[0]);
                throw new DBusError.FAILED ("The clipboard is empty");
            }
            return new UnixInputStream (fds[0], true);
        }

        private void on_selection (string[] mime_types, bool own) {
            foreach (var info in _remote.describe_sessions ()) {
                string handle = info["handle"].get_string ();
                if (!info["clipboard"].get_boolean ()) continue;
                var options = new HashTable<string, Variant> (str_hash, str_equal);
                options["mime_types"] = new Variant.strv (mime_types);
                options["session_is_owner"] = new Variant.boolean (own && _owner == handle);
                selection_owner_changed (new ObjectPath (handle), options);
            }
        }
    }
}
