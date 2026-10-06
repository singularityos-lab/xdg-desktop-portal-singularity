using GLib;
using Gtk;

namespace Singularity.Portal {

    public class ConsentApp : Gtk.Application {
        private ConsentRequest _request;

        public ConsentApp(ConsentRequest request) {
            Object(application_id: "dev.sinty.portal.consent", flags: ApplicationFlags.NON_UNIQUE);
            _request = request;
        }

        protected override void activate() {
            var settings = Gtk.Settings.get_default();
            if (settings != null) settings.gtk_theme_name = "Singularity";
            Singularity.Style.StyleManager.pin_brand_themes();
            var style_manager = Singularity.Style.StyleManager.get_default();
            style_manager.load_theme();
            unowned SettingsSchemaSource? source = SettingsSchemaSource.get_default();
            SettingsSchema? schema = source != null ? source.lookup("dev.sinty.desktop", true) : null;
            if (schema != null) {
                var desktop = new GLib.Settings.full(schema, null, null);
                style_manager.apply_color_scheme(desktop.get_boolean("dark-mode"));
                string color = desktop.get_string("accent-color");
                string? wallpaper = null;
                if (color == "wallpaper") {
                    string uri = desktop.get_string("background-picture-uri");
                    if (uri != "") wallpaper = File.new_for_uri(uri).get_path();
                } else if (color == "custom") {
                    color = desktop.get_string("custom-accent-color");
                    if (color == "") color = "#3584e4";
                }
                style_manager.apply_accent_color(color, wallpaper);
            }

            hold();
            var dialog = new ConsentDialog(this, _request);
            dialog.finished.connect((result) => {
                stdout.printf("%s\n", ConsentJson.encode_result(result));
                stdout.flush();
                release();
                quit();
            });
            dialog.open_dialog();
        }

        private static string read_stdin() {
            var document = new StringBuilder();
            string? line;
            while ((line = stdin.read_line()) != null) document.append(line);
            return document.str;
        }

        public static int main(string[] args) {
            Intl.setlocale(LocaleCategory.ALL, "");
            string locale_dir = "/usr/share/locale";
            try {
                string executable = FileUtils.read_link("/proc/self/exe");
                locale_dir = Path.build_filename(Path.get_dirname(Path.get_dirname(executable)), "share", "locale");
            } catch (Error e) {
            }
            Intl.bindtextdomain("xdg-desktop-portal-singularity", locale_dir);
            Intl.bind_textdomain_codeset("xdg-desktop-portal-singularity", "UTF-8");
            Intl.textdomain("xdg-desktop-portal-singularity");

            var request = ConsentJson.decode_request(read_stdin());
            if (request == null) {
                stderr.printf("singularity-portal-consent: malformed request\n");
                return 2;
            }
            return new ConsentApp(request).run({ args[0] });
        }
    }
}
