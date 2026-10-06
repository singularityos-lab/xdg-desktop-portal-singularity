using GLib;

namespace Singularity.Portal {

    [DBus (name = "org.freedesktop.impl.portal.Request")]
    public class PortalRequest : Object {
        [DBus (visible = false)]
        public Cancellable cancellable { get; private set; default = new Cancellable(); }

        private DBusConnection _conn;
        private uint _registration = 0;

        [DBus (visible = false)]
        public PortalRequest(DBusConnection conn, ObjectPath handle) {
            _conn = conn;
            try {
                _registration = conn.register_object(handle, this);
            } catch (Error e) {
                _registration = 0;
            }
        }

        public void close() throws Error {
            cancellable.cancel();
            unexport();
        }

        [DBus (visible = false)]
        public void unexport() {
            if (_registration == 0) return;
            _conn.unregister_object(_registration);
            _registration = 0;
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.Session")]
    public class PortalSession : Object {
        public signal void closed();

        [DBus (name = "version")]
        public uint32 version { get { return 1; } }

        [DBus (visible = false)]
        public string app_id { get; private set; }
        [DBus (visible = false)]
        public ObjectPath handle { get; private set; }
        [DBus (visible = false)]
        public bool is_closed { get; private set; default = false; }
        [DBus (visible = false)]
        public signal void ended();

        private DBusConnection _conn;
        private uint _registration = 0;

        [DBus (visible = false)]
        public PortalSession(DBusConnection conn, ObjectPath handle, string app_id) {
            _conn = conn;
            this.handle = handle;
            this.app_id = app_id;
            try {
                _registration = conn.register_object(handle, this);
            } catch (Error e) {
                _registration = 0;
            }
        }

        public void close() throws Error {
            end(false);
        }

        [DBus (visible = false)]
        public void end(bool notify_frontend) {
            if (is_closed) return;
            is_closed = true;
            if (notify_frontend) closed();
            if (_registration != 0) {
                _conn.unregister_object(_registration);
                _registration = 0;
            }
            ended();
        }
    }
}
