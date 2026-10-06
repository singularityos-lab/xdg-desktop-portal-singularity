using GLib;

namespace Singularity.Portal {

    [DBus (name = "org.freedesktop.impl.portal.Lockdown")]
    public class LockdownPortal : Object {
        public const string KEY_LOCATION = "privacy-location-enabled";
        public const string KEY_CAMERA = "privacy-camera-enabled";
        public const string KEY_MICROPHONE = "privacy-microphone-enabled";

        private GLib.Settings? _settings = null;
        private DBusConnection? _conn = null;

        [DBus (name = "disable-printing")]
        public bool disable_printing { get { return false; } }
        [DBus (name = "disable-save-to-disk")]
        public bool disable_save_to_disk { get { return false; } }
        [DBus (name = "disable-application-handlers")]
        public bool disable_application_handlers { get { return false; } }
        [DBus (name = "disable-location")]
        public bool disable_location { get { return !enabled(KEY_LOCATION); } }
        [DBus (name = "disable-camera")]
        public bool disable_camera { get { return !enabled(KEY_CAMERA); } }
        [DBus (name = "disable-microphone")]
        public bool disable_microphone { get { return !enabled(KEY_MICROPHONE); } }
        [DBus (name = "disable-sound-output")]
        public bool disable_sound_output { get { return false; } }

        public LockdownPortal(DBusConnection? conn = null) {
            _conn = conn;
            unowned SettingsSchemaSource? source = SettingsSchemaSource.get_default();
            SettingsSchema? schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema == null || !schema.has_key(KEY_LOCATION)) return;
            _settings = new GLib.Settings.full(schema, null, null);
            _settings.changed.connect((key) => {
                switch (key) {
                    case KEY_LOCATION: announce("disable-location", disable_location); break;
                    case KEY_CAMERA: announce("disable-camera", disable_camera); break;
                    case KEY_MICROPHONE: announce("disable-microphone", disable_microphone); break;
                }
            });
            _settings.get_boolean(KEY_LOCATION);
            _settings.get_boolean(KEY_CAMERA);
            _settings.get_boolean(KEY_MICROPHONE);
        }

        private void announce(string property, bool value) {
            if (_conn == null) return;
            var changed = new VariantBuilder(new VariantType("a{sv}"));
            changed.add("{sv}", property, new Variant.boolean(value));
            try {
                _conn.emit_signal(null, "/org/freedesktop/portal/desktop", "org.freedesktop.DBus.Properties",
                    "PropertiesChanged", new Variant("(sa{sv}as)", "org.freedesktop.impl.portal.Lockdown", changed, null));
            } catch (Error e) {
                warning("LockdownPortal: %s", e.message);
            }
        }

        private bool enabled(string key) {
            if (_settings == null) return true;
            return _settings.get_boolean(key);
        }
    }
}
