using GLib;
using Gtk;
using GtkLayerShell;
using Singularity.Widgets;
using Singularity.Shell;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.DynamicLauncher.
     *
     * Shows a confirmation dialog and grants a one-time install token
     * that the frontend can use to create a .desktop file.
     */
    [DBus (name = "org.freedesktop.impl.portal.DynamicLauncher")]
    public class DynamicLauncherPortal : Object {
        private GLib.Application? _app;

        public DynamicLauncherPortal(GLib.Application? app = null) {
            _app = app;
        }

        /** Prompts the user to confirm and optionally rename a launcher. */
        public async void prepare_install(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string name,
            Variant icon_v,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            bool user_accepted = false;
            bool done = false;

            string final_name = name;

            var dialog = new ShellDialog(_app);
            dialog.add_css_class("run-dialog");

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 28;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            var icon = new Image.from_icon_name("list-add-symbolic");
            icon.pixel_size = 48;
            icon.add_css_class("dim-label");
            box.append(icon);

            var title_lbl = new Label(_("Install Launcher"));
            title_lbl.add_css_class("title-2");
            box.append(title_lbl);

            string desc = "<b>%s</b> wants to add <b>%s</b> to your applications.".printf(
                GLib.Markup.escape_text(app_id), GLib.Markup.escape_text(name));
            var desc_lbl = new Label(desc);
            desc_lbl.use_markup = true;
            desc_lbl.wrap = true;
            desc_lbl.max_width_chars = 42;
            desc_lbl.justify = Justification.CENTER;
            desc_lbl.add_css_class("dim-label");
            box.append(desc_lbl);

            var name_entry = new Entry();
            name_entry.text = name;
            name_entry.placeholder_text = _("Launcher name");
            box.append(name_entry);

            var btn_box = new Box(Orientation.HORIZONTAL, 12);
            btn_box.halign = Align.CENTER;
            btn_box.margin_top = 8;

            var cancel_btn = new Button.with_label(_("Cancel"));
            cancel_btn.width_request = 120;
            cancel_btn.clicked.connect(() => {
                done = true;
                dialog.close_dialog();
            });
            btn_box.append(cancel_btn);

            var install_btn = new Button.with_label(_("Install"));
            install_btn.width_request = 120;
            install_btn.add_css_class("suggested-action");
            install_btn.clicked.connect(() => {
                final_name = name_entry.text.strip();
                if (final_name == "") final_name = name;
                user_accepted = true;
                done = true;
                dialog.close_dialog();
            });
            btn_box.append(install_btn);

            name_entry.activate.connect(() => install_btn.clicked());

            box.append(btn_box);
            dialog.content_box.append(box);

            dialog.close_request.connect(() => {
                if (!done) done = true;
                return false;
            });

            dialog.open_dialog();
            name_entry.grab_focus();

            while (!done) {
                Idle.add(prepare_install.callback, Priority.DEFAULT_IDLE);
                yield;
            }

            if (user_accepted) {
                results.insert("name", new Variant.string(final_name));
                results.insert("token", new Variant.uint32(1));
                response = 0;
            } else {
                response = 1;
            }
        }

        /**
         * Grants a one-time install token.
         *
         * The token is required by the xdg-desktop-portal frontend before
         * it writes the .desktop file. We always grant it here because
         * the user has already confirmed via prepare_install.
         */
        public void request_install_token(
            string app_id,
            HashTable<string, Variant> options,
            out uint32 response
        ) throws Error {
            // Token always granted; user confirmation happened in prepare_install
            response = 0;
        }
    }
}
