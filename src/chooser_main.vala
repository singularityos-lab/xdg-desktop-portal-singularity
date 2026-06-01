using Gtk;

namespace Singularity.Portal {

    /**
     * Standalone helper that shows the screencast output chooser and prints the
     * chosen output name to stdout (nothing on cancel). The portal runs it as a
     * separate process: GTK is never initialised inside the portal daemon, which
     * would otherwise deadlock querying its own Settings portal during Gtk.init.
     * Output names are passed as command-line arguments.
     */
    public class ScreenCastChooserApp : Gtk.Application {

        private string[] _outputs;

        public ScreenCastChooserApp (string[] outputs) {
            Object (application_id: "dev.sinty.screencast.chooser",
                    flags: ApplicationFlags.NON_UNIQUE);
            _outputs = outputs;
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
            var picker = new ScreenCastSourcePicker (this, _outputs);
            picker.selected.connect ((name) => {
                stdout.printf ("%s\n", name);
                stdout.flush ();
                quit ();
            });
            picker.cancelled.connect (() => {
                quit ();
            });
            picker.open_dialog ();
        }

        public static int main (string[] argv) {
            string[] outs = {};
            for (int i = 1; i < argv.length; i++)
                outs += argv[i];
            var app = new ScreenCastChooserApp (outs);
            return app.run ({ argv[0] });
        }
    }
}
