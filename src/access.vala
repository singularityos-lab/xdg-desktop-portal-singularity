using GLib;

namespace Singularity.Portal {

    [DBus (name = "org.freedesktop.impl.portal.Access")]
    public class AccessPortal : Object {
        private DBusConnection? _conn;
        private ConsentRunner _runner;

        public AccessPortal(DBusConnection? conn = null, ConsentRunner? runner = null) {
            _conn = conn;
            _runner = runner ?? new SubprocessConsentRunner();
        }

        public async void access_dialog(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            string subtitle,
            string body,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            var request = new ConsentRequest();
            request.kind = "access";
            request.app_id = app_id;
            request.app_name = portal_app_name(app_id);
            request.title = title;
            request.subtitle = subtitle;
            request.body = body;
            request.icon = "dialog-question-symbolic";
            var icon = options.lookup("icon");
            if (icon != null && icon.is_of_type(VariantType.STRING)) request.icon = icon.get_string();
            var grant = options.lookup("grant_label");
            if (grant != null && grant.is_of_type(VariantType.STRING)) request.grant_label = grant.get_string();
            var deny = options.lookup("deny_label");
            if (deny != null && deny.is_of_type(VariantType.STRING)) request.deny_label = deny.get_string();

            PortalRequest? portal_request = _conn != null ? new PortalRequest(_conn, handle) : null;
            var result = yield _runner.ask(request, portal_request != null ? portal_request.cancellable : null);
            if (portal_request != null) portal_request.unexport();
            response = result.response;
        }
    }
}
