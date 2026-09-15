using GLib;
using Gtk;

namespace Singularity.Portal {

    public class ScreenCastChooserApp : Gtk.Application {
        private ScreenCastSource[] _sources;

        public ScreenCastChooserApp (ScreenCastSource[] sources) {
            Object (
                application_id: "dev.sinty.screencast.chooser",
                flags: ApplicationFlags.NON_UNIQUE
            );
            _sources = sources;
        }

        protected override void activate () {
            var settings = Gtk.Settings.get_default ();
            if (settings != null)
                settings.gtk_theme_name = "Singularity";

            var style_manager = Singularity.Style.StyleManager.get_default ();
            style_manager.load_theme ();
            unowned GLib.SettingsSchemaSource? schema_source =
                GLib.SettingsSchemaSource.get_default ();
            GLib.SettingsSchema? desktop_schema = schema_source != null
                ? schema_source.lookup ("dev.sinty.desktop", true)
                : null;
            if (desktop_schema != null) {
                var desktop_settings = new GLib.Settings.full (
                    desktop_schema, null, null);
                style_manager.apply_color_scheme (
                    desktop_settings.get_boolean ("dark-mode"));
                string color = desktop_settings.get_string ("accent-color");
                string? wallpaper_path = null;
                if (color == "wallpaper") {
                    string uri = desktop_settings.get_string (
                        "background-picture-uri");
                    if (uri != "")
                        wallpaper_path = GLib.File.new_for_uri (uri).get_path ();
                } else if (color == "custom") {
                    color = desktop_settings.get_string ("custom-accent-color");
                    if (color == "")
                        color = "#3584e4";
                }
                style_manager.apply_accent_color (color, wallpaper_path);
            }

            var icon_css = new Gtk.CssProvider ();
            icon_css.load_from_string (
                ".screencast-picker-dialog image { -gtk-icon-style: symbolic; }");
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (),
                icon_css,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            hold ();
            var picker = new ScreenCastSourcePicker (this, _sources);
            picker.selected.connect ((source_type, source_id) => {
                var selection = new ScreenCastSelection (
                    source_type, source_id);
                stdout.printf ("%s\n", ScreenCastJson.encode_selection (selection));
                stdout.flush ();
                quit ();
            });
            picker.cancelled.connect (() => {
                quit ();
            });
            picker.open_dialog ();
        }

        private static string read_stdin () {
            var document = new StringBuilder ();
            string? line;
            while ((line = stdin.read_line ()) != null)
                document.append (line);
            return document.str;
        }

        public static int main (string[] arguments) {
            Intl.setlocale (LocaleCategory.ALL, "");
            string locale_directory = "/usr/share/locale";
            try {
                string executable = FileUtils.read_link ("/proc/self/exe");
                locale_directory = Path.build_filename (
                    Path.get_dirname (Path.get_dirname (executable)),
                    "share",
                    "locale");
            } catch (Error caught) {
                // Use the conventional locale path.
            }
            Intl.bindtextdomain (
                "xdg-desktop-portal-singularity", locale_directory);
            Intl.bind_textdomain_codeset (
                "xdg-desktop-portal-singularity", "UTF-8");
            Intl.textdomain ("xdg-desktop-portal-singularity");

            ScreenCastSource[] sources = ScreenCastJson.decode_sources (
                read_stdin ());
            var application = new ScreenCastChooserApp (sources);
            return application.run ({ arguments[0] });
        }
    }
}
