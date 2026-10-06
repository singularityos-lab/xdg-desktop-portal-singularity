using GLib;

namespace Singularity.Portal {

    public const string SCREEN_RECORDER_OBJECT_PATH = "/dev/sinty/portal/ScreenRecorder";

    [DBus (name = "dev.sinty.portal.ScreenRecorder")]
    public class ScreenRecorderService : Object {
        private const uint START_TIMEOUT_MS = 5000;
        private const uint POLL_INTERVAL_MS = 10;

        private ScreenCastCaptureManager _manager;
        private DBusConnection? _connection;
        private HashTable<uint, ScreenCastCapture> _captures;
        private HashTable<uint, string> _owners;
        private HashTable<string, uint> _watches;
        private uint _next_handle = 1;

        public ScreenRecorderService (ScreenCastCaptureManager manager,
                                      DBusConnection? connection = null) {
            _manager = manager;
            _connection = connection;
            _captures = new HashTable<uint, ScreenCastCapture> (null, null);
            _owners = new HashTable<uint, string> (null, null);
            _watches = new HashTable<string, uint> (str_hash, str_equal);
        }

        public string list_windows (BusName sender) throws Error {
            _check_caller (sender);
            return ScreenCastJson.encode_sources (
                _manager.list_sources (SCREENCAST_SOURCE_WINDOW));
        }

        public async void start_capture (uint32 source_type,
                                         string source_id,
                                         bool paint_cursors,
                                         BusName sender,
                                         out uint32 handle,
                                         out uint32 node_id) throws Error {
            handle = 0;
            node_id = 0;
            _check_caller (sender);
            if (source_type != SCREENCAST_SOURCE_MONITOR &&
                source_type != SCREENCAST_SOURCE_WINDOW)
                throw new DBusError.INVALID_ARGS ("Unknown source type %u",
                    source_type);
            if ((_manager.available_source_types & source_type) == 0)
                throw new DBusError.NOT_SUPPORTED (
                    "The compositor cannot capture this source type");

            var capture = _manager.create_capture (
                source_type, source_id, paint_cursors);
            if (capture == null)
                throw new DBusError.FILE_NOT_FOUND (
                    "No capture source named %s", source_id);

            uint waited = 0;
            while (!capture.failed && capture.node_id == 0xffffffffu &&
                   waited < START_TIMEOUT_MS) {
                Timeout.add (POLL_INTERVAL_MS, start_capture.callback);
                yield;
                waited += POLL_INTERVAL_MS;
            }
            if (capture.failed || capture.node_id == 0xffffffffu) {
                capture.stop ();
                throw new DBusError.FAILED (
                    "The compositor did not deliver any frames");
            }

            handle = _next_handle++;
            node_id = capture.node_id;
            _captures.insert (handle, capture);
            _owners.insert (handle, (string) sender);
            _watch_owner ((string) sender);
        }

        public void stop_capture (uint32 handle, BusName sender) throws Error {
            string? owner = _owners.lookup (handle);
            if (owner == null || owner != (string) sender)
                throw new DBusError.ACCESS_DENIED ("Unknown capture %u", handle);
            _release (handle);
        }

        [DBus (visible = false)]
        public uint active_captures {
            get { return _captures.size (); }
        }

        [DBus (visible = false)]
        public void release_owner (string owner) {
            uint[] handles = {};
            _owners.foreach ((handle, name) => {
                if (name == owner)
                    handles += handle;
            });
            foreach (uint handle in handles)
                _release (handle);
        }

        private void _release (uint handle) {
            var capture = _captures.lookup (handle);
            string? owner = _owners.lookup (handle);
            _captures.remove (handle);
            _owners.remove (handle);
            if (capture != null)
                capture.stop ();
            if (owner != null && !_owner_has_captures (owner))
                _unwatch_owner (owner);
        }

        private bool _owner_has_captures (string owner) {
            bool found = false;
            _owners.foreach ((handle, name) => {
                if (name == owner)
                    found = true;
            });
            return found;
        }

        private void _watch_owner (string owner) {
            if (_connection == null || _watches.contains (owner))
                return;
            uint watch_id = Bus.watch_name_on_connection (
                _connection, owner, BusNameWatcherFlags.NONE, null,
                (connection, name) => {
                    release_owner (name);
                });
            _watches.insert (owner, watch_id);
        }

        private void _unwatch_owner (string owner) {
            uint watch_id;
            if (_watches.lookup_extended (owner, null, out watch_id)) {
                _watches.remove (owner);
                Bus.unwatch_name (watch_id);
            }
        }

        private void _check_caller (BusName sender) throws Error {
            if (_connection == null)
                return;
            uint32 pid = 0;
            try {
                Variant reply = _connection.call_sync (
                    "org.freedesktop.DBus", "/org/freedesktop/DBus",
                    "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                    new Variant ("(s)", (string) sender),
                    new VariantType ("(u)"), DBusCallFlags.NONE, -1, null);
                reply.get ("(u)", out pid);
            } catch (Error caught) {
                throw new DBusError.ACCESS_DENIED (
                    "Cannot identify the caller: %s", caught.message);
            }
            if (FileUtils.test ("/proc/%u/root/.flatpak-info".printf (pid),
                    FileTest.EXISTS))
                throw new DBusError.ACCESS_DENIED (
                    "Sandboxed applications must use the ScreenCast portal");
        }
    }
}
