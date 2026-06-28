using Gtk;

namespace Singularity.Portal {

    /**
     * Standalone helper that shows the screencast source chooser and prints the
     * chosen source as JSON to stdout (nothing on cancel). The portal runs it as a
     * separate process: GTK is never initialised inside the portal daemon, which
     * would otherwise deadlock querying its own Settings portal during Gtk.init.
     * The source list is passed as JSON on stdin.
     */
    public class ScreenCastChooserApp : Gtk.Application {

        private ScreenCastSourceOption[] _sources;

        public ScreenCastChooserApp (ScreenCastSourceOption[] sources) {
            Object (application_id: "dev.sinty.screencast.chooser",
                    flags: ApplicationFlags.NON_UNIQUE);
            _sources = sources;
        }

        protected override void activate () {
            // Inherit the Singularity look (same theme/accent as the shell).
            var gs = Gtk.Settings.get_default ();
            if (gs != null) gs.gtk_theme_name = "Singularity";
            var sm = Singularity.Style.StyleManager.get_default ();
            sm.load_theme ();
            try {
                var ds = new GLib.Settings ("dev.sinty.desktop");
                sm.apply_color_scheme (ds.get_boolean ("dark-mode"));
                string color_name = ds.get_string ("accent-color");
                string? wallpaper_path = null;
                if (color_name == "wallpaper") {
                    string uri = ds.get_string ("background-picture-uri");
                    if (uri != "")
                        wallpaper_path = GLib.File.new_for_uri (uri).get_path ();
                } else if (color_name == "custom") {
                    string hex = ds.get_string ("custom-accent-color");
                    if (hex == null || hex == "") hex = "#3584e4";
                    color_name = hex;
                }
                sm.apply_accent_color (color_name, wallpaper_path);
            } catch (Error e) {
                // desktop schema unavailable: keep StyleManager defaults
            }

            // Force symbolic (monochrome, theme-coloured) rendering for the
            // dialog's icons; some icon themes ship coloured variants under the
            // -symbolic name, which would otherwise show up coloured.
            var icon_css = new Gtk.CssProvider ();
            icon_css.load_from_string (
                ".screencast-picker-dialog image { -gtk-icon-style: symbolic; }");
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), icon_css,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            hold ();
            var picker = new ScreenCastSourcePicker (this, _sources);
            picker.selected.connect ((source_type, source_id) => {
                string json = _selection_to_json (source_type, source_id);
                stdout.printf ("%s\n", json);
                stdout.flush ();
                quit ();
            });
            picker.cancelled.connect (() => {
                quit ();
            });
            picker.open_dialog ();
        }

        private static string _read_stdin () {
            string data = "";
            string? line;
            while ((line = stdin.read_line ()) != null)
                data += line;
            return data;
        }

        private static ScreenCastSourceOption[] _parse_sources (string data) {
            ScreenCastSourceOption[] sources = {};
            if (data.strip () == "") return sources;

            try {
                var parser = new Json.Parser ();
                parser.load_from_data (data);
                Json.Object root = parser.get_root ().get_object ();
                Json.Array arr = root.get_array_member ("sources");
                for (uint i = 0; i < arr.get_length (); i++) {
                    Json.Object obj = arr.get_object_element (i);
                    uint32 type = (uint32) obj.get_int_member ("type");
                    string id = obj.get_string_member ("id");
                    string label = obj.get_string_member ("label");
                    string app_id = obj.get_string_member ("app_id");
                    if (id != "")
                        sources += new ScreenCastSourceOption (type, id, label, app_id);
                }
            } catch (Error e) {
                warning ("ScreenCastChooserApp: failed to parse sources: %s", e.message);
            }
            return sources;
        }

        private static string _selection_to_json (uint32 source_type, string source_id) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("type");
            builder.add_int_value (source_type);
            builder.set_member_name ("id");
            builder.add_string_value (source_id);
            builder.end_object ();

            var generator = new Json.Generator ();
            Json.Node root = builder.get_root ();
            generator.set_root (root);
            string data = generator.to_data (null);
            return data;
        }

        public static int main (string[] argv) {
        Intl.setlocale(GLib.LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = GLib.FileUtils.read_link("/proc/self/exe");
            locale_dir = GLib.Path.build_filename(GLib.Path.get_dirname(GLib.Path.get_dirname(exe)), "share", "locale");
        } catch (GLib.Error e) { }
        Intl.bindtextdomain("xdg-desktop-portal-singularity", locale_dir);
        Intl.bind_textdomain_codeset("xdg-desktop-portal-singularity", "UTF-8");
        Intl.textdomain("xdg-desktop-portal-singularity");

            ScreenCastSourceOption[] sources = _parse_sources (_read_stdin ());
            var app = new ScreenCastChooserApp (sources);
            return app.run ({ argv[0] });
        }
    }
}
