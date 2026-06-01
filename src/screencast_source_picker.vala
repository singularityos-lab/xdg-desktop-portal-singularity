using GLib;
using Gtk;

namespace Singularity.Portal {

    /**
     * Screen-share output chooser. Built on the same Singularity.Shell.ShellDialog
     * base as the logout / power-confirm dialog, so it looks like a native
     * Singularity modal (dimmed full-screen overlay with a centered card).
     *
     * Signals:
     *   selected(output_name)  - emitted when the user clicks "Share"
     *   cancelled()            - emitted when the user dismisses the dialog
     */
    public class ScreenCastSourcePicker : Singularity.Shell.ShellDialog {

        public signal void selected  (string output_name);
        public signal void cancelled ();

        private string?   _chosen_output;
        private Gtk.Box   _output_list_box;

        public ScreenCastSourcePicker (GLib.Application? app, string[] outputs) {
            Object (
                application:   app as Gtk.Application,
                anchor_top:    true,
                anchor_bottom: true,
                anchor_left:   true,
                anchor_right:  true
            );
            add_css_class ("screencast-picker-dialog");
            _build (outputs);
            hide ();
        }

        private void _build (string[] outputs) {
            var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
            card.halign = Gtk.Align.CENTER;
            card.valign = Gtk.Align.CENTER;
            card.add_css_class ("power-card");
            card.margin_top    = 28;
            card.margin_bottom = 28;
            card.margin_start  = 40;
            card.margin_end    = 40;
            content_box.append (card);

            var icon = new Gtk.Image.from_icon_name ("video-display-symbolic");
            icon.pixel_size = 48;
            card.append (icon);

            var title_lbl = new Gtk.Label (_("Share your screen"));
            title_lbl.add_css_class ("title-1");
            card.append (title_lbl);

            var subtitle = new Gtk.Label (_("Choose a monitor to share"));
            subtitle.add_css_class ("dim-label");
            subtitle.add_css_class ("body");
            card.append (subtitle);

            _output_list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            _output_list_box.margin_top = 6;
            card.append (_output_list_box);

            var btn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            btn_row.halign = Gtk.Align.CENTER;
            btn_row.margin_top = 4;
            card.append (btn_row);

            var cancel_btn = new Gtk.Button.with_label (_("Cancel"));
            cancel_btn.add_css_class ("pill");
            cancel_btn.width_request = 128;
            cancel_btn.clicked.connect (_on_cancel_clicked);
            btn_row.append (cancel_btn);

            var share_btn = new Gtk.Button.with_label (_("Share"));
            share_btn.add_css_class ("pill");
            share_btn.add_css_class ("suggested-action");
            share_btn.width_request = 128;
            share_btn.clicked.connect (_on_share_clicked);
            btn_row.append (share_btn);

            _populate (outputs);
        }

        private void _populate (string[] outputs) {
            if (outputs.length == 0) {
                var lbl = new Gtk.Label (_("No monitors detected"));
                lbl.add_css_class ("dim-label");
                _output_list_box.append (lbl);
                return;
            }

            _chosen_output = outputs[0];
            foreach (unowned string name in outputs)
                _add_output_row (name);
        }

        private void _add_output_row (string name) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            row.add_css_class ("card");
            row.margin_top    = 2;
            row.margin_bottom = 2;

            var mon_icon = new Gtk.Image.from_icon_name ("video-display-symbolic");
            mon_icon.pixel_size = 24;
            row.append (mon_icon);

            var lbl = new Gtk.Label (name);
            lbl.hexpand = true;
            lbl.halign  = Gtk.Align.START;
            row.append (lbl);

            var check = new Gtk.CheckButton ();
            check.active = (_chosen_output == name);
            row.append (check);

            var gesture = new Gtk.GestureClick ();
            gesture.released.connect ((n, x, y) => {
                _set_chosen (name);
            });
            row.add_controller (gesture);

            check.toggled.connect (() => {
                if (check.active) _set_chosen (name);
            });

            _output_list_box.append (row);
        }

        private void _set_chosen (string name) {
            _chosen_output = name;
            Gtk.Widget? child = _output_list_box.get_first_child ();
            while (child != null) {
                var row = child as Gtk.Box;
                if (row != null) {
                    Gtk.Widget? icon_w = row.get_first_child ();
                    Gtk.Widget? lbl_w  = icon_w != null ? icon_w.get_next_sibling () : null;
                    Gtk.Widget? chk_w  = lbl_w  != null ? lbl_w.get_next_sibling ()  : null;
                    var lbl = lbl_w as Gtk.Label;
                    var chk = chk_w as Gtk.CheckButton;
                    if (lbl != null && chk != null)
                        chk.set_active (lbl.label == name);
                }
                child = child.get_next_sibling ();
            }
        }

        private void _on_share_clicked () {
            string? out_name = _chosen_output;
            close_dialog ();
            if (out_name != null)
                selected (out_name);
            else
                cancelled ();
        }

        private void _on_cancel_clicked () {
            close_dialog ();
            cancelled ();
        }
    }
}
