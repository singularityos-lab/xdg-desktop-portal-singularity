using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Email by constructing
     * a mailto: URI and launching the system default handler.
     */
    [DBus (name = "org.freedesktop.impl.portal.Email")]
    public class EmailPortal : Object {
        public EmailPortal() {}

        public async void compose_email(
            ObjectPath handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            var sb = new StringBuilder("mailto:");

            var address_v = options.get("address");
            if (address_v != null) {
                sb.append(GLib.Uri.escape_string(address_v.get_string(), "@.", true));
            }

            var addresses_v = options.get("addresses");
            if (addresses_v != null) {
                var iter = addresses_v.iterator();
                string addr;
                bool first = address_v == null;
                while (iter.next("s", out addr)) {
                    sb.append(first ? "" : ",");
                    sb.append(GLib.Uri.escape_string(addr, "@.", true));
                    first = false;
                }
            }

            string sep = "?";
            var subject_v = options.get("subject");
            if (subject_v != null) {
                sb.append_printf("%ssubject=%s", sep,
                    GLib.Uri.escape_string(subject_v.get_string(), null, true));
                sep = "&";
            }

            var body_v = options.get("body");
            if (body_v != null) {
                sb.append_printf("%sbody=%s", sep,
                    GLib.Uri.escape_string(body_v.get_string(), null, true));
            }

            try {
                var handler = AppInfo.get_default_for_uri_scheme("mailto");
                if (handler != null) {
                    var uris = new List<string>();
                    uris.append(sb.str);
                    handler.launch_uris(uris, null);
                    response = 0;
                } else {
                    response = 2;
                }
            } catch (Error e) {
                warning("EmailPortal: %s", e.message);
                response = 2;
            }
        }
    }
}