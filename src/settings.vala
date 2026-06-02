using GLib;

[CCode (cname = "portal_register_object", cheader_filename = "dbus_helper.h")]
extern uint portal_register_object(
    GLib.DBusConnection connection, string path,
    GLib.DBusInterfaceInfo info,
    [CCode (type = "GDBusInterfaceMethodCallFunc")] SettingsMethodCallFunc method_call,
    [CCode (type = "GDBusInterfaceGetPropertyFunc")] SettingsGetPropertyFunc get_property,
    void* user_data) throws GLib.Error;

[CCode (has_target = false)]
delegate void SettingsMethodCallFunc(
    GLib.DBusConnection connection, string sender,
    string object_path, string interface_name, string method_name,
    GLib.Variant parameters, GLib.DBusMethodInvocation invocation, void* user_data);

[CCode (has_target = false)]
delegate GLib.Variant? SettingsGetPropertyFunc(
    GLib.DBusConnection connection, string sender,
    string object_path, string interface_name, string property_name,
    void* error, void* user_data);

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Settings.
     *
     * Exposes desktop settings (color scheme, accent color) over D-Bus.
     * Uses manual C registration because Vala's [DBus] codegen cannot
     * handle this interface's read-only property correctly.
     */
    public class SettingsPortal : Object {
        private GLib.Settings _desktop_settings;
        // Real org.gnome.desktop.interface settings, proxied so GTK clients that
        // read interface settings through the portal (the default path on
        // Wayland) get the full namespace, including icon-theme. Omitting
        // icon-theme made GTK fall back to hicolor and lose symbolic icons.
        private GLib.Settings? _iface_settings = null;
        private unowned DBusConnection? _conn;
        private DBusNodeInfo _node_info;

        // org.gnome.desktop.interface keys to proxy verbatim from GSettings.
        // color-scheme and accent-color are handled separately (derived).
        private const string[] IFACE_STRING_KEYS = {
            "gtk-theme", "icon-theme", "cursor-theme", "font-name",
            "monospace-font-name", "document-font-name"
        };

        private const string IFACE_XML =
            "<node>" +
            "  <interface name='org.freedesktop.impl.portal.Settings'>" +
            "    <method name='ReadAll'>" +
            "      <arg name='namespaces' type='as' direction='in'/>" +
            "      <arg name='value' type='a{sa{sv}}' direction='out'/>" +
            "    </method>" +
            "    <method name='Read'>" +
            "      <arg name='namespace' type='s' direction='in'/>" +
            "      <arg name='key' type='s' direction='in'/>" +
            "      <arg name='value' type='v' direction='out'/>" +
            "    </method>" +
            "    <signal name='SettingChanged'>" +
            "      <arg name='namespace' type='s'/>" +
            "      <arg name='key' type='s'/>" +
            "      <arg name='value' type='v'/>" +
            "    </signal>" +
            "    <property name='version' type='u' access='read'/>" +
            "  </interface>" +
            "</node>";

        public SettingsPortal() {
            _desktop_settings = new GLib.Settings("dev.sinty.desktop");
            _desktop_settings.changed.connect(_on_setting_changed);
            // Bind the real interface settings only if the schema is installed,
            // so the portal degrades gracefully where it is absent.
            var src = GLib.SettingsSchemaSource.get_default();
            if (src != null && src.lookup("org.gnome.desktop.interface", true) != null) {
                _iface_settings = new GLib.Settings("org.gnome.desktop.interface");
                _iface_settings.changed.connect(_on_iface_changed);
            }
            _node_info = new DBusNodeInfo.for_xml(IFACE_XML);
        }

        // Propagate live changes of proxied interface keys to clients.
        private void _on_iface_changed(string key) {
            if (_conn == null || _iface_settings == null) return;
            if (!(key in IFACE_STRING_KEYS)) return;
            try {
                _conn.emit_signal(null,
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.impl.portal.Settings",
                    "SettingChanged",
                    new Variant("(ssv)",
                        "org.gnome.desktop.interface", key,
                        new Variant.string(_iface_settings.get_string(key))));
            } catch (Error e) {
                warning("SettingsPortal: failed to emit SettingChanged for %s: %s", key, e.message);
            }
        }

        // Adds the proxied org.gnome.desktop.interface string keys (icon-theme,
        // gtk-theme, fonts, ...) to a builder, skipping any the schema lacks.
        private void _add_iface_string_keys(VariantBuilder inner) {
            if (_iface_settings == null) return;
            var schema = _iface_settings.settings_schema;
            foreach (var key in IFACE_STRING_KEYS) {
                if (!schema.has_key(key)) continue;
                inner.add("{sv}", key, new Variant.string(_iface_settings.get_string(key)));
            }
        }

        public uint register_on(DBusConnection connection) throws GLib.Error {
            _conn = connection;
            var iface = _node_info.lookup_interface("org.freedesktop.impl.portal.Settings");
            return portal_register_object(connection,
                "/org/freedesktop/portal/desktop", iface,
                _on_method_call_cb, _on_get_property_cb, this);
        }

        private static void _on_method_call_cb(DBusConnection connection, string sender,
                string object_path, string interface_name, string method_name,
                Variant parameters, DBusMethodInvocation invocation, void* user_data) {
            var self = (SettingsPortal) user_data;
            if (method_name == "ReadAll") {
                self._handle_read_all(parameters, invocation);
            } else if (method_name == "Read") {
                self._handle_read(parameters, invocation);
            } else {
                invocation.return_error_literal(
                    DBusError.quark(), DBusError.UNKNOWN_METHOD,
                    "Unknown method: %s".printf(method_name));
            }
        }

        private static Variant? _on_get_property_cb(DBusConnection connection, string sender,
                string object_path, string interface_name, string property_name,
                void* error, void* user_data) {
            if (property_name == "version") return new Variant.uint32(2);
            return null;
        }

        private void _handle_read_all(Variant parameters, DBusMethodInvocation invocation) {
            string[] namespaces = {};
            var ns_variant = parameters.get_child_value(0);
            for (size_t i = 0; i < ns_variant.n_children(); i++) {
                namespaces += ns_variant.get_child_value(i).get_string();
            }

            bool want_all = namespaces.length == 0;
            if (!want_all) {
                foreach (var ns in namespaces) {
                    if (ns == "" || ns == "*") { want_all = true; break; }
                }
            }
            bool include_appearance = want_all;
            bool include_gnome_desktop = want_all;
            if (!include_appearance || !include_gnome_desktop) {
                foreach (var ns in namespaces) {
                    if (ns == "org.freedesktop.appearance") include_appearance = true;
                    if (ns == "org.gnome.desktop.interface") include_gnome_desktop = true;
                }
            }

            var builder = new VariantBuilder(new VariantType("a{sa{sv}}"));
            if (include_appearance) {
                var inner = new VariantBuilder(new VariantType("a{sv}"));
                inner.add("{sv}", "color-scheme", new Variant.uint32(_get_color_scheme()));
                builder.add("{s@a{sv}}", "org.freedesktop.appearance", inner.end());
            }
            if (include_gnome_desktop) {
                var inner = new VariantBuilder(new VariantType("a{sv}"));
                inner.add("{sv}", "color-scheme", new Variant.string(_get_gnome_color_scheme()));
                inner.add("{sv}", "accent-color", new Variant.string(_get_accent_color()));
                // Proxy the real interface keys so GTK clients reading this
                // namespace through the portal (the default on Wayland) get a
                // complete dict, including icon-theme. Omitting icon-theme made
                // GTK fall back to hicolor and lose symbolic icons.
                _add_iface_string_keys(inner);
                builder.add("{s@a{sv}}", "org.gnome.desktop.interface", inner.end());
            }
            invocation.return_value(new Variant.tuple({ builder.end() }));
        }

        private void _handle_read(Variant parameters, DBusMethodInvocation invocation) {
            string ns, key;
            parameters.get("(ss)", out ns, out key);

            if (ns == "org.freedesktop.appearance" && key == "color-scheme") {
                invocation.return_value(new Variant.tuple({
                    new Variant.variant(new Variant.uint32(_get_color_scheme()))
                }));
                return;
            }
            if (ns == "org.gnome.desktop.interface") {
                if (key == "color-scheme") {
                    invocation.return_value(new Variant.tuple({
                        new Variant.variant(new Variant.string(_get_gnome_color_scheme()))
                    }));
                    return;
                }
                if (key == "accent-color") {
                    invocation.return_value(new Variant.tuple({
                        new Variant.variant(new Variant.string(_get_accent_color()))
                    }));
                    return;
                }
                // Proxy the real interface string keys (icon-theme, gtk-theme,
                // fonts, ...) so clients reading them through the portal get the
                // actual value instead of a NotFound error.
                if (_iface_settings != null && key in IFACE_STRING_KEYS
                        && _iface_settings.settings_schema.has_key(key)) {
                    invocation.return_value(new Variant.tuple({
                        new Variant.variant(new Variant.string(_iface_settings.get_string(key)))
                    }));
                    return;
                }
            }
            invocation.return_error_literal(
                Quark.from_string("XDGDesktopPortal"), 2, "Setting not found");
        }

        private void _on_setting_changed(string key) {
            if (_conn == null) return;
            if (key == "dark-mode") {
                try {
                    _conn.emit_signal(null,
                        "/org/freedesktop/portal/desktop",
                        "org.freedesktop.impl.portal.Settings",
                        "SettingChanged",
                        new Variant("(ssv)",
                            "org.freedesktop.appearance",
                            "color-scheme",
                            new Variant.uint32(_get_color_scheme())));
                } catch (Error e) {
                    warning("SettingsPortal: failed to emit SettingChanged for color-scheme: %s", e.message);
                }
                try {
                    _conn.emit_signal(null,
                        "/org/freedesktop/portal/desktop",
                        "org.freedesktop.impl.portal.Settings",
                        "SettingChanged",
                        new Variant("(ssv)",
                            "org.gnome.desktop.interface",
                            "color-scheme",
                            new Variant.string(_get_gnome_color_scheme())));
                } catch (Error e) {
                    warning("SettingsPortal: failed to emit SettingChanged for gnome color-scheme: %s", e.message);
                }
            }
            if (key == "accent-color") {
                try {
                    _conn.emit_signal(null,
                        "/org/freedesktop/portal/desktop",
                        "org.freedesktop.impl.portal.Settings",
                        "SettingChanged",
                        new Variant("(ssv)",
                            "org.gnome.desktop.interface",
                            "accent-color",
                            new Variant.string(_get_accent_color())));
                } catch (Error e) {
                    warning("SettingsPortal: failed to emit SettingChanged for accent-color: %s", e.message);
                }
            }
        }

        private uint32 _get_color_scheme() {
            bool dark = _desktop_settings.get_boolean("dark-mode");
            return dark ? 1 : 2;
        }

        // org.gnome.desktop.interface uses "prefer-dark"/"default" strings
        private string _get_gnome_color_scheme() {
            bool dark = _desktop_settings.get_boolean("dark-mode");
            return dark ? "prefer-dark" : "default";
        }

        // Falls back to "blue" for wallpaper-derived colors
        private string _get_accent_color() {
            string color = _desktop_settings.get_string("accent-color");
            return color == "wallpaper" ? "blue" : color;
        }
    }
}