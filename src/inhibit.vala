using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Inhibit.
     *
     * Forwards inhibit requests to the FDO ScreenSaver and tracks
     * cookies locally so release() can uninhibit them.
     */
    [DBus (name = "org.freedesktop.impl.portal.Inhibit")]
    public class InhibitPortal : Object {
        private HashTable<string, uint32> _inhibits;
        private HashTable<string, uint32> _ss_cookies;
        private uint32 _next_cookie;
        private DBusConnection _conn;

        public InhibitPortal(DBusConnection conn) {
            _inhibits = new HashTable<string, uint32>(str_hash, str_equal);
            _ss_cookies = new HashTable<string, uint32>(str_hash, str_equal);
            _next_cookie = 1;
            _conn = conn;
        }

        public void inhibit(
            ObjectPath handle,
            string app_id,
            string window,
            uint32 flags,
            HashTable<string, Variant> options
        ) throws Error {
            string reason = "";
            var reason_v = options.get("reason");
            if (reason_v != null) reason = reason_v.get_string();

            uint32 cookie = _next_cookie++;
            _inhibits.insert(handle, cookie);
            message("InhibitPortal: app=%s flags=%u reason=%s cookie=%u", app_id, flags, reason, cookie);

            try {
                var reply = _conn.call_sync(
                    "org.freedesktop.ScreenSaver",
                    "/org/freedesktop/ScreenSaver",
                    "org.freedesktop.ScreenSaver",
                    "Inhibit",
                    new Variant("(ss)", app_id, reason),
                    new VariantType("(u)"),
                    DBusCallFlags.NONE, -1, null);
                uint32 ss_cookie = 0;
                reply.get("(u)", out ss_cookie);
                _ss_cookies.insert(handle, ss_cookie);
            } catch (Error e) {
                // ScreenSaver inhibit not available, just track locally
            }
        }

        [DBus (visible = false)]
        public void _release(string handle) {
            _inhibits.remove(handle);
            uint32 ss_cookie = _ss_cookies.lookup(handle);
            if (ss_cookie != 0) {
                try {
                    _conn.call_sync(
                        "org.freedesktop.ScreenSaver",
                        "/org/freedesktop/ScreenSaver",
                        "org.freedesktop.ScreenSaver",
                        "UnInhibit",
                        new Variant("(u)", ss_cookie),
                        null,
                        DBusCallFlags.NONE, -1, null);
                } catch (Error e) {
                    warning("InhibitPortal: UnInhibit failed: %s", e.message);
                }
                _ss_cookies.remove(handle);
            }
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