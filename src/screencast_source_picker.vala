using GLib;
using Gtk;
using GtkLayerShell;

namespace Singularity.Portal {

    /**
     * A layer-shell OVERLAY window that lists available Wayland outputs
     * and lets the user choose one to share via ScreenCast.
     *
     * Signals:
     *   selected(output_name)  - emitted when the user clicks "Share"
     *   cancelled()            - emitted when the user dismisses the dialog
     */
    public class ScreenCastSourcePicker : Gtk.Window {

        public signal void selected  (string output_name);
        public signal void cancelled ();

        private string?   _chosen_output;
        private Gtk.Box   _output_list_box;

        public ScreenCastSourcePicker (GLib.Application? app, string[] outputs) {
            Object (application: app as Gtk.Application);
            _populate (outputs);
        }

        construct {
            GtkLayerShell.init_for_window (this);
            GtkLayerShell.set_layer (this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_keyboard_mode (this,
                GtkLayerShell.KeyboardMode.ON_DEMAND);

            add_css_class ("singularity");
            add_css_class ("singularity-shell");
            add_css_class ("dialog");

            var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 16);
            root.margin_top    = 24;
            root.margin_bottom = 24;
            root.margin_start  = 24;
            root.margin_end    = 24;
            set_child (root);

            // Title row
            var title_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            var icon = new Gtk.Image.from_icon_name ("video-display-symbolic");
            icon.pixel_size = 20;
            var title_lbl = new Gtk.Label ("Share a Screen");
            title_lbl.add_css_class ("title-4");
            title_row.append (icon);
            title_row.append (title_lbl);
            root.append (title_row);

            var subtitle = new Gtk.Label ("Choose a monitor to share");
            subtitle.add_css_class ("dim-label");
            subtitle.halign = Gtk.Align.START;
            root.append (subtitle);

            // Monitor list
            _output_list_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            root.append (_output_list_box);

            // Buttons
            var btn_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
            btn_row.halign = Gtk.Align.END;
            root.append (btn_row);

            var cancel_btn = new Gtk.Button.with_label ("Cancel");
            cancel_btn.clicked.connect (_on_cancel_clicked);
            btn_row.append (cancel_btn);

            var share_btn = new Gtk.Button.with_label ("Share");
            share_btn.add_css_class ("suggested-action");
            share_btn.clicked.connect (_on_share_clicked);
            btn_row.append (share_btn);

            // Close on Escape
            var key_ctrl = new Gtk.EventControllerKey ();
            key_ctrl.key_pressed.connect ((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    _on_cancel_clicked ();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget) this).add_controller (key_ctrl);
        }

        private void _populate (string[] outputs) {
            if (outputs.length == 0) {
                var lbl = new Gtk.Label ("No monitors detected");
                lbl.add_css_class ("dim-label");
                _output_list_box.append (lbl);
                return;
            }

            // Pre-select first output before building rows
            _chosen_output = outputs[0];

            foreach (unowned string name in outputs) {
                _add_output_row (name);
            }
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
            // Sync all checkboxes
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
            close ();
            if (out_name != null)
                selected (out_name);
            else
                cancelled ();
        }

        private void _on_cancel_clicked () {
            close ();
            cancelled ();
        }
    }
}