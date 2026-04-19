using GLib;
using Gtk;
using GtkLayerShell;
using Singularity.Widgets;
using Singularity.Shell;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Access.
     *
     * Shows a permission dialog (allow/deny) using a layer-shell window.
     */
    [DBus (name = "org.freedesktop.impl.portal.Access")]
    public class AccessPortal : Object {
        private GLib.Application? _app;

        public AccessPortal(GLib.Application? app = null) {
            _app = app;
        }

        public async void access_dialog(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            string subtitle,
            string body,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            string grant_label = "Allow";
            string deny_label = "Deny";
            if (options.contains("grant_label"))
                grant_label = options.get("grant_label").get_string();
            if (options.contains("deny_label"))
                deny_label = options.get("deny_label").get_string();

            string? icon_name = null;
            if (options.contains("icon"))
                icon_name = options.get("icon").get_string();

            uint32 user_response = 1;
            bool done = false;

            var dialog = new ShellDialog(_app);
            dialog.add_css_class("run-dialog");

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 28;
            box.margin_bottom = 24;
            box.margin_start = 24;
            box.margin_end = 24;

            if (icon_name != null) {
                var icon = new Image.from_icon_name(icon_name);
                icon.pixel_size = 48;
                icon.add_css_class("dim-label");
                box.append(icon);
            } else {
                var icon = new Image.from_icon_name("dialog-question-symbolic");
                icon.pixel_size = 48;
                icon.add_css_class("dim-label");
                box.append(icon);
            }

            var title_lbl = new Label(title);
            title_lbl.add_css_class("title-2");
            title_lbl.wrap = true;
            title_lbl.max_width_chars = 42;
            title_lbl.justify = Justification.CENTER;
            box.append(title_lbl);

            if (subtitle != "") {
                var sub_lbl = new Label(subtitle);
                sub_lbl.add_css_class("dim-label");
                sub_lbl.wrap = true;
                sub_lbl.max_width_chars = 42;
                sub_lbl.justify = Justification.CENTER;
                box.append(sub_lbl);
            }

            if (body != "") {
                var body_lbl = new Label(body);
                body_lbl.wrap = true;
                body_lbl.max_width_chars = 42;
                body_lbl.justify = Justification.CENTER;
                box.append(body_lbl);
            }

            var btn_box = new Box(Orientation.HORIZONTAL, 12);
            btn_box.halign = Align.CENTER;
            btn_box.margin_top = 8;

            var deny_btn = new Button.with_label(deny_label);
            deny_btn.width_request = 120;
            deny_btn.clicked.connect(() => {
                user_response = 1;
                done = true;
                dialog.close_dialog();
            });
            btn_box.append(deny_btn);

            var allow_btn = new Button.with_label(grant_label);
            allow_btn.width_request = 120;
            allow_btn.add_css_class("suggested-action");
            allow_btn.clicked.connect(() => {
                user_response = 0;
                done = true;
                dialog.close_dialog();
            });
            btn_box.append(allow_btn);

            box.append(btn_box);
            dialog.content_box.append(box);

            dialog.close_request.connect(() => {
                if (!done) {
                    user_response = 1;
                    done = true;
                }
                return false;
            });

            dialog.open_dialog();

            while (!done) {
                Idle.add(access_dialog.callback, Priority.DEFAULT_IDLE);
                yield;
            }

            response = user_response;
        }
    }
}
