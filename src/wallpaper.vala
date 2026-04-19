using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Wallpaper.
     *
     * Sets the wallpaper via the Singularity desktop GSettings schema
     * and also writes to the GNOME background schema when available.
     */
    [DBus (name = "org.freedesktop.impl.portal.Wallpaper")]
    public class WallpaperPortal : Object {

        /** Sets the desktop wallpaper to the given URI. */
        public async void set_wallpaper_uri(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string uri,
            HashTable<string, Variant> options,
            out uint32 response
        ) throws Error {
            string set_on = "both";
            var set_on_v = options.get("set-on");
            if (set_on_v != null) set_on = set_on_v.get_string();

            message("WallpaperPortal: uri=%s set-on=%s", uri, set_on);

            bool any_set = false;

            // Always set via our own schema
            var sinty_schema = GLib.SettingsSchemaSource.get_default()
                .lookup("dev.sinty.desktop", true);
            if (sinty_schema != null) {
                try {
                    var bg = new GLib.Settings("dev.sinty.desktop");
                    bg.set_string("background-picture-uri", uri);
                    bg.apply();
                    any_set = true;
                } catch (Error e) {
                    warning("WallpaperPortal: dev.sinty.desktop: %s", e.message);
                }
            }

            // Also forward to GNOME schema for compat
            var gnome_schema = GLib.SettingsSchemaSource.get_default()
                .lookup("org.gnome.desktop.background", true);
            if (gnome_schema != null) {
                try {
                    var bg = new GLib.Settings("org.gnome.desktop.background");
                    bg.set_string("picture-uri", uri);
                    bg.set_string("picture-uri-dark", uri);
                    bg.apply();
                    any_set = true;
                } catch (Error e) {
                    warning("WallpaperPortal: org.gnome.desktop.background: %s", e.message);
                }
            }

            response = any_set ? (uint32)0 : 2;
        }
    }
}