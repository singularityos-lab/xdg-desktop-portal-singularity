using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Notification by forwarding
     * to the FDO Notifications daemon. Removal is a no-op because the
     * FDO Notify API identifies notifications by numeric ID, not by
     * the app_id + id pair the portal spec uses.
     */
    [DBus (name = "org.freedesktop.impl.portal.Notification")]
    public class NotificationPortal : Object {
        private DBusConnection _conn;

        public NotificationPortal(DBusConnection conn) {
            _conn = conn;
        }

        public void add_notification(string app_id, string id, HashTable<string, Variant> notification) throws Error {
            string title = "";
            string body = "";
            string icon_name = "dialog-information";

            var title_v = notification.get("title");
            if (title_v != null) title = title_v.get_string();

            var body_v = notification.get("body");
            if (body_v != null) body = body_v.get_string();

            var icon_v = notification.get("icon");
            if (icon_v != null && icon_v.is_of_type(VariantType.STRING)) {
                icon_name = icon_v.get_string();
            }

            try {
                var actions = new VariantBuilder(new VariantType("as"));
                var hints = new VariantBuilder(new VariantType("a{sv}"));

                int32 timeout = -1;
                _conn.call_sync(
                    "org.freedesktop.Notifications",
                    "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications",
                    "Notify",
                    new Variant("(susssasa{sv}i)",
                        app_id, (uint32) 0, icon_name, title, body,
                        actions, hints, timeout),
                    null, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                warning("NotificationPortal: failed to forward: %s", e.message);
            }
        }

        public void remove_notification(string app_id, string id) throws Error {
            // FDO notifications use numeric IDs, not app_id+id pairs
        }
    }
}