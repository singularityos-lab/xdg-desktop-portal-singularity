using GLib;

namespace Singularity.Portal {

    [DBus (name = "org.freedesktop.impl.portal.Inhibit")]
    public class InhibitPortal : Object {
        private const string SHELL_NAME = "org.freedesktop.ScreenSaver";
        private const string SHELL_PATH = "/org/freedesktop/ScreenSaver";
        private const string INHIBITORS_IFACE = "dev.sinty.desktop.Inhibitors";
        private const uint IDLE_OR_SUSPEND = 4 | 8;

        private HashTable<string, PortalRequest> _requests;
        private HashTable<string, uint32> _cookies;
        private HashTable<string, string> _interfaces;
        private DBusConnection _conn;

        public InhibitPortal(DBusConnection conn) {
            _requests = new HashTable<string, PortalRequest>(str_hash, str_equal);
            _cookies = new HashTable<string, uint32>(str_hash, str_equal);
            _interfaces = new HashTable<string, string>(str_hash, str_equal);
            _conn = conn;
        }

        public async void inhibit(
            ObjectPath handle,
            string app_id,
            string window,
            uint32 flags,
            HashTable<string, Variant> options
        ) throws Error {
            string reason = "";
            var reason_v = options.get("reason");
            if (reason_v != null && reason_v.is_of_type(VariantType.STRING)) reason = reason_v.get_string();

            var request = new PortalRequest(_conn, handle);
            string key = handle;
            request.cancellable.cancelled.connect(() => Idle.add(() => {
                _release(key);
                return Source.REMOVE;
            }));
            _requests.insert(handle, request);
            message("InhibitPortal: app=%s flags=%u", app_id, flags);

            try {
                var reply = yield _conn.call(SHELL_NAME, SHELL_PATH, INHIBITORS_IFACE, "Inhibit",
                    new Variant("(ssu)", app_id, reason, flags),
                    new VariantType("(u)"), DBusCallFlags.NONE, 5000, null);
                _store(handle, reply, INHIBITORS_IFACE);
                return;
            } catch (Error e) {
                debug("InhibitPortal: %s unavailable: %s", INHIBITORS_IFACE, e.message);
            }
            if ((flags & IDLE_OR_SUSPEND) == 0) return;
            try {
                var reply = yield _conn.call(SHELL_NAME, SHELL_PATH, "org.freedesktop.ScreenSaver", "Inhibit",
                    new Variant("(ss)", app_id, reason),
                    new VariantType("(u)"), DBusCallFlags.NONE, 5000, null);
                _store(handle, reply, "org.freedesktop.ScreenSaver");
            } catch (Error e) {
                warning("InhibitPortal: no screensaver service: %s", e.message);
            }
        }

        private void _store(string handle, Variant reply, string iface) {
            if (!_requests.contains(handle)) {
                uint32 late = 0;
                reply.get("(u)", out late);
                _uninhibit(iface, late);
                return;
            }
            uint32 cookie = 0;
            reply.get("(u)", out cookie);
            _cookies.insert(handle, cookie);
            _interfaces.insert(handle, iface);
        }

        private void _uninhibit(string iface, uint32 cookie) {
            _conn.call.begin(SHELL_NAME, SHELL_PATH, iface, "UnInhibit",
                new Variant("(u)", cookie), null, DBusCallFlags.NONE, 5000, null, (obj, res) => {
                    try {
                        _conn.call.end(res);
                    } catch (Error e) {
                        warning("InhibitPortal: UnInhibit failed: %s", e.message);
                    }
                });
        }

        [DBus (visible = false)]
        public void _release(string handle) {
            var request = _requests.lookup(handle);
            if (request != null) {
                request.unexport();
                _requests.remove(handle);
            }
            if (_cookies.contains(handle) && _interfaces.contains(handle)) {
                _uninhibit(_interfaces.lookup(handle), _cookies.lookup(handle));
            }
            _cookies.remove(handle);
            _interfaces.remove(handle);
            message("InhibitPortal: released %s", handle);
        }

        public async void create_monitor(
            ObjectPath handle,
            ObjectPath session_handle,
            string app_id,
            string window,
            out uint32 response
        ) throws Error {
            response = 0;
        }

        public void query_end_response(ObjectPath session_handle) throws Error {
        }
    }
}
