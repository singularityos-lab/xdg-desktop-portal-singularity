using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Account.
     *
     * Returns the local user's information from AccountsService or
     * environment variables, with IconFile and ~/.face as fallbacks.
     */
    [DBus (name = "org.freedesktop.impl.portal.Account")]
    public class AccountPortal : Object {
        private DBusConnection _conn;

        public AccountPortal(DBusConnection conn) {
            _conn = conn;
        }

        public async void get_user_information(
            ObjectPath handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            string username = Environment.get_user_name();
            string realname = Environment.get_real_name() ?? username;
            string home = Environment.get_home_dir();
            string icon = "";

            try {
                var reply = _conn.call_sync(
                    "org.freedesktop.Accounts",
                    "/org/freedesktop/Accounts",
                    "org.freedesktop.Accounts",
                    "FindUserByName",
                    new Variant("(s)", username),
                    new VariantType("(o)"),
                    DBusCallFlags.NONE, -1, null);
                string user_path;
                reply.get("(o)", out user_path);

                var props = _conn.call_sync(
                    "org.freedesktop.Accounts",
                    user_path,
                    "org.freedesktop.DBus.Properties",
                    "Get",
                    new Variant("(ss)", "org.freedesktop.Accounts.User", "IconFile"),
                    new VariantType("(v)"),
                    DBusCallFlags.NONE, -1, null);
                Variant inner;
                props.get("(v)", out inner);
                icon = inner.get_string();
            } catch (Error e) {
                string face = Path.build_filename(home, ".face");
                if (FileUtils.test(face, FileTest.EXISTS)) {
                    icon = face;
                }
            }

            results.insert("id", new Variant.string(username));
            results.insert("name", new Variant.string(realname));
            if (icon != "") {
                results.insert("image", new Variant.string(Filename.to_uri(icon)));
            }
            response = 0;
        }
    }
}