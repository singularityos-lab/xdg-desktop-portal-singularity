using GLib;

namespace Singularity.Portal {

    public const uint32 APP_STATE_BACKGROUND = 0;
    public const uint32 APP_STATE_RUNNING = 1;
    public const uint32 APP_STATE_ACTIVE = 2;

    public const uint32 BACKGROUND_FORBID = 0;
    public const uint32 BACKGROUND_ALLOW = 1;
    public const uint32 BACKGROUND_ALLOW_ONCE = 2;

    namespace BackgroundLogic {
        public HashTable<string, Variant> app_states(string[] window_app_ids) {
            var states = new HashTable<string, Variant>(str_hash, str_equal);
            foreach (unowned string id in window_app_ids) {
                string app_id = id.has_suffix(".desktop") ? id.substring(0, id.length - 8) : id;
                if (app_id == "") continue;
                states.insert(app_id, new Variant.uint32(APP_STATE_RUNNING));
            }
            return states;
        }

        public uint32 choice_to_result(ConsentResult consent) {
            if (!consent.granted) return BACKGROUND_ALLOW_ONCE;
            switch (consent.choice) {
                case "forbid": return BACKGROUND_FORBID;
                case "allow": return BACKGROUND_ALLOW;
                default: return BACKGROUND_ALLOW_ONCE;
            }
        }

        public string exec_quote(string arg) {
            bool plain = arg != "";
            for (int i = 0; i < arg.length; i++) {
                if (" \t\n\"'\\><~|&;$*?#()`".index_of_char(arg[i]) >= 0) plain = false;
            }
            if (plain) return arg;
            var quoted = new StringBuilder("\"");
            for (int i = 0; i < arg.length; i++) {
                char c = arg[i];
                if (c == '"' || c == '`' || c == '$' || c == '\\') quoted.append_c('\\');
                quoted.append_c(c);
            }
            quoted.append_c('"');
            return quoted.str;
        }

        public string autostart_contents(string app_id, string name, string[] commandline, bool dbus_activatable) {
            var file = new KeyFile();
            file.set_string("Desktop Entry", "Type", "Application");
            file.set_string("Desktop Entry", "Name", name != "" ? name : app_id);
            file.set_string("Desktop Entry", "X-XDP-Autostart", app_id);
            if (commandline.length > 0) {
                string[] quoted = {};
                foreach (unowned string arg in commandline) quoted += exec_quote(arg);
                file.set_string("Desktop Entry", "Exec", string.joinv(" ", quoted));
            }
            if (dbus_activatable) file.set_boolean("Desktop Entry", "DBusActivatable", true);
            return file.to_data();
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.Background")]
    public class BackgroundPortal : Object {
        public const string INTERFACE = "org.freedesktop.impl.portal.Background";

        private DBusConnection _conn;
        private ConsentRunner _runner;
        private ToplevelMonitor? _monitor = null;
        private uint _changed_idle = 0;

        [DBus (visible = false)]
        public BackgroundPortal(DBusConnection conn, ConsentRunner? runner = null) {
            _conn = conn;
            _runner = runner ?? new SubprocessConsentRunner();
            _monitor = new ToplevelMonitor(() => queue_changed());
        }

        public HashTable<string, Variant> get_app_state() throws Error {
            if (_monitor == null || !(_monitor.is_connected() || _monitor.connect()))
                throw new DBusError.NOT_SUPPORTED("The compositor does not list open windows");
            return BackgroundLogic.app_states(_monitor.list_app_ids());
        }

        public async void notify_background(ObjectPath handle, string app_id, string name,
                                            out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            string display = name != "" ? name : portal_app_name(app_id);
            var request = new ConsentRequest();
            request.kind = "background";
            request.app_id = app_id;
            request.app_name = display;
            request.icon = "system-run-symbolic";
            request.title = _("%s Is Running in the Background").printf(display);
            request.subtitle = _("It has no open windows. Background apps can use power and data.");
            request.body = _("You can change this later in Settings, Privacy, Background Activity.");
            request.deny_label = _("Stop and Don't Allow");
            request.add_item(new ConsentItem("allow", _("Allow"), _("Let it keep running in the background")));
            request.add_item(new ConsentItem("once", _("This Time"), _("Ask again next time it starts")));

            var portal_request = new PortalRequest(_conn, handle);
            var consent = yield _runner.ask(request, portal_request.cancellable);
            portal_request.unexport();
            results.insert("result", new Variant.uint32(BackgroundLogic.choice_to_result(consent)));
            response = 0;
        }

        public bool enable_autostart(string app_id, bool enable, string[] commandline, uint32 flags) throws Error {
            string dir = Path.build_filename(Environment.get_user_config_dir(), "autostart");
            string path = Path.build_filename(dir, app_id + ".desktop");
            if (!enable) {
                FileUtils.unlink(path);
                return false;
            }
            DirUtils.create_with_parents(dir, 0755);
            string contents = BackgroundLogic.autostart_contents(app_id, portal_app_name(app_id), commandline, (flags & 1) != 0);
            FileUtils.set_contents(path, contents);
            return true;
        }

        private void queue_changed() {
            if (_changed_idle != 0) return;
            _changed_idle = Timeout.add(250, () => {
                _changed_idle = 0;
                try {
                    _conn.emit_signal(null, "/org/freedesktop/portal/desktop", INTERFACE,
                        "RunningApplicationsChanged", null);
                } catch (Error e) {
                    warning("BackgroundPortal: %s", e.message);
                }
                return Source.REMOVE;
            });
        }
    }
}
