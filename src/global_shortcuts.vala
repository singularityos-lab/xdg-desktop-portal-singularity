using GLib;

namespace Singularity.Portal {

    public struct ShortcutSpec {
        public string id;
        public HashTable<string, Variant> props;
    }

    public class ShortcutStore : Object {
        public const string KEY = "portal-global-shortcuts";

        public signal void changed();

        private GLib.Settings? _settings = null;
        private StoredShortcut[] _memory = {};

        public ShortcutStore() {
            unowned SettingsSchemaSource? source = SettingsSchemaSource.get_default();
            SettingsSchema? schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema == null || !schema.has_key(KEY)) return;
            _settings = new GLib.Settings.full(schema, null, null);
            _settings.changed[KEY].connect(() => changed());
            _settings.get_value(KEY);
        }

        public ShortcutStore.in_memory() {
        }

        public StoredShortcut[] all() {
            if (_settings == null) return _memory;
            return ShortcutTriggers.parse_stored(_settings.get_value(KEY));
        }

        public StoredShortcut[] for_app(string app_id) {
            StoredShortcut[] result = {};
            foreach (var s in all()) {
                if (s.app_id == app_id) result += s;
            }
            return result;
        }

        public StoredShortcut? find(string app_id, string id) {
            foreach (var s in all()) {
                if (s.app_id == app_id && s.id == id) return s;
            }
            return null;
        }

        public void add(StoredShortcut[] added) {
            StoredShortcut[] merged = {};
            foreach (var s in all()) {
                bool replaced = false;
                foreach (var a in added) {
                    if (a.app_id == s.app_id && a.id == s.id) replaced = true;
                }
                if (!replaced) merged += s;
            }
            foreach (var a in added) merged += a;
            if (_settings == null) {
                _memory = merged;
                changed();
                return;
            }
            _settings.set_value(KEY, ShortcutTriggers.serialize(merged));
        }
    }

    public class ShortcutSession : Object {
        public PortalSession session;
        public GenericArray<string> bound = new GenericArray<string>();

        public ShortcutSession(PortalSession session) {
            this.session = session;
        }

        public bool has(string id) {
            foreach (unowned string b in bound.data) {
                if (b == id) return true;
            }
            return false;
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.GlobalShortcuts")]
    public class GlobalShortcutsPortal : Object {
        public const string INTERFACE = "org.freedesktop.impl.portal.GlobalShortcuts";

        [DBus (name = "version")]
        public uint32 version { get { return 2; } }

        private DBusConnection _conn;
        private ConsentRunner _runner;
        private ShortcutStore _store;
        private HashTable<string, ShortcutSession> _sessions =
            new HashTable<string, ShortcutSession>(str_hash, str_equal);

        [DBus (visible = false)]
        public GlobalShortcutsPortal(DBusConnection conn, ShortcutStore? store = null, ConsentRunner? runner = null) {
            _conn = conn;
            _store = store ?? new ShortcutStore();
            _runner = runner ?? new SubprocessConsentRunner();
            _store.changed.connect(on_store_changed);
        }

        public async void create_session(ObjectPath handle, ObjectPath session_handle, string app_id,
                                         HashTable<string, Variant> options,
                                         out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            var session = new PortalSession(_conn, session_handle, app_id);
            var state = new ShortcutSession(session);
            string key = session_handle;
            session.ended.connect(() => _sessions.remove(key));
            _sessions.insert(key, state);
            response = 0;
        }

        public async void bind_shortcuts(ObjectPath handle, ObjectPath session_handle, ShortcutSpec[] shortcuts,
                                         string parent_window, HashTable<string, Variant> options,
                                         out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            var state = _sessions.lookup(session_handle);
            if (state == null) {
                response = 2;
                return;
            }
            string app_id = state.session.app_id;

            var request = new ConsentRequest();
            request.kind = "shortcuts";
            request.app_id = app_id;
            request.app_name = portal_app_name(app_id);
            request.icon = "input-keyboard-symbolic";
            request.title = request.app_name != ""
                ? _("Allow %s to Use Global Shortcuts?").printf(request.app_name)
                : _("Allow an App to Use Global Shortcuts?");
            request.subtitle = _("These shortcuts work even when the app is in the background.");
            request.body = _("You can change or remove them at any time in Settings, Privacy.");
            request.grant_label = _("Allow");

            StoredShortcut[] pending = {};
            foreach (var spec in shortcuts) {
                if (_store.find(app_id, spec.id) != null) continue;
                string description = text_prop(spec.props, "description");
                string accel = ShortcutTriggers.to_accelerator(text_prop(spec.props, "preferred_trigger"));
                pending += new StoredShortcut(app_id, spec.id, description != "" ? description : spec.id, accel);
                string trigger = ShortcutTriggers.to_trigger_description(accel);
                request.add_item(new ConsentItem(spec.id, description != "" ? description : spec.id,
                    trigger != "" ? trigger : _("No key assigned")));
            }

            if (pending.length > 0) {
                var portal_request = new PortalRequest(_conn, handle);
                var result = yield _runner.ask(request, portal_request.cancellable);
                portal_request.unexport();
                if (!result.granted && _store.for_app(app_id).length == 0) {
                    response = result.response == 2 ? 2 : 1;
                    return;
                }
                StoredShortcut[] accepted = {};
                foreach (var p in pending) {
                    if (result.granted && result.has_selected(p.id)) accepted += p;
                }
                if (accepted.length > 0) _store.add(accepted);
            }

            state.bound = new GenericArray<string>();
            foreach (var spec in shortcuts) {
                if (_store.find(app_id, spec.id) != null) state.bound.add(spec.id);
            }
            results.insert("shortcuts", describe(state));
            response = 0;
        }

        public async void list_shortcuts(ObjectPath handle, ObjectPath session_handle,
                                         out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            var state = _sessions.lookup(session_handle);
            if (state == null) {
                response = 2;
                return;
            }
            if (state.bound.length == 0) {
                foreach (var s in _store.for_app(state.session.app_id)) state.bound.add(s.id);
            }
            results.insert("shortcuts", describe(state));
            response = 0;
        }

        public async void configure_shortcuts(ObjectPath session_handle, string parent_window,
                                              HashTable<string, Variant> options) throws Error {
            try {
                yield _conn.call("dev.sinty.desktop", "/dev/sinty/Shell", "dev.sinty.Shell", "OpenSettings",
                    new Variant("(s)", "privacy-shortcuts"), null, DBusCallFlags.NO_AUTO_START, 3000, null);
            } catch (Error e) {
                warning("GlobalShortcutsPortal: settings unavailable: %s", e.message);
            }
        }

        [DBus (visible = false)]
        public uint activate(string app_id, string shortcut_id) {
            uint count = 0;
            uint64 timestamp = (uint64) (get_monotonic_time() / 1000);
            var options = new VariantBuilder(new VariantType("a{sv}"));
            Variant empty = options.end();
            foreach (var state in _sessions.get_values()) {
                if (state.session.app_id != app_id || !state.has(shortcut_id)) continue;
                emit("Activated", new Variant("(ost@a{sv})", state.session.handle, shortcut_id, timestamp, empty));
                emit("Deactivated", new Variant("(ost@a{sv})", state.session.handle, shortcut_id, timestamp, empty));
                count++;
            }
            return count;
        }

        private void on_store_changed() {
            foreach (var state in _sessions.get_values()) {
                var still = new GenericArray<string>();
                bool dropped = false;
                foreach (unowned string id in state.bound.data) {
                    if (_store.find(state.session.app_id, id) != null) still.add(id);
                    else dropped = true;
                }
                state.bound = still;
                if (dropped)
                    emit("ShortcutsChanged", new Variant("(o@a(sa{sv}))", state.session.handle, describe(state)));
            }
        }

        private Variant describe(ShortcutSession state) {
            var list = new VariantBuilder(new VariantType("a(sa{sv})"));
            foreach (unowned string id in state.bound.data) {
                var stored = _store.find(state.session.app_id, id);
                if (stored == null) continue;
                var props = new VariantBuilder(new VariantType("a{sv}"));
                props.add("{sv}", "description", new Variant.string(stored.description));
                props.add("{sv}", "trigger_description",
                    new Variant.string(ShortcutTriggers.to_trigger_description(stored.accelerator)));
                list.add("(s@a{sv})", id, props.end());
            }
            return list.end();
        }

        private void emit(string name, Variant parameters) {
            try {
                _conn.emit_signal(null, "/org/freedesktop/portal/desktop", INTERFACE, name, parameters);
            } catch (Error e) {
                warning("GlobalShortcutsPortal: cannot emit %s: %s", name, e.message);
            }
        }

        private static string text_prop(HashTable<string, Variant> props, string key) {
            var value = props.lookup(key);
            if (value == null || !value.is_of_type(VariantType.STRING)) return "";
            return value.get_string();
        }
    }

    [DBus (name = "dev.sinty.portal.GlobalShortcuts")]
    public class GlobalShortcutsBridge : Object {
        private GlobalShortcutsPortal _portal;

        public GlobalShortcutsBridge(GlobalShortcutsPortal portal) {
            _portal = portal;
        }

        public uint32 activate(string app_id, string shortcut_id) throws Error {
            return _portal.activate(app_id, shortcut_id);
        }
    }
}
