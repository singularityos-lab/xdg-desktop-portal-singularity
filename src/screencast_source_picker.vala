using GLib;
using Gtk;

namespace Singularity.Portal {

    public class ScreenCastSourceOption : Object {
        public uint32 source_type;
        public string source_id;
        public string label;
        public string app_id;
        public Gtk.CheckButton? check;

        public ScreenCastSourceOption (uint32 source_type, string source_id,
                                       string label, string app_id) {
            this.source_type = source_type;
            this.source_id = source_id;
            this.label = label;
            this.app_id = app_id;
        }
    }

    /**
     * Screen-share output chooser. Built on the same Singularity.Shell.ShellDialog
     * base as the logout / power-confirm dialog, so it looks like a native
     * Singularity modal (dimmed full-screen overlay with a centered card).
     *
     * Signals:
     *   selected(type, id) - emitted when the user clicks "Share"
     *   cancelled()        - emitted when the user dismisses the dialog
     */
    public class ScreenCastSourcePicker : Singularity.Shell.ShellDialog {

        public signal void selected  (uint32 source_type, string source_id);
        public signal void cancelled ();

        private ScreenCastSourceOption[] _sources;
        private ScreenCastSourceOption?  _chosen_source;
        private Gtk.Box                  _output_list_box;
        private Gtk.Button               _share_btn;

        public ScreenCastSourcePicker (GLib.Application? app, ScreenCastSourceOption[] sources) {
            Object (
                application:   app as Gtk.Application,
                anchor_top:    true,
                anchor_bottom: true,
                anchor_left:   true,
                anchor_right:  true
            );
            _sources = sources;
            add_css_class ("screencast-picker-dialog");
            _build ();
            hide ();
        }

        private void _build () {
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

            var subtitle = new Gtk.Label (_("Choose what to share"));
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

            _share_btn = new Gtk.Button.with_label (_("Share"));
            _share_btn.add_css_class ("pill");
            _share_btn.add_css_class ("suggested-action");
            _share_btn.width_request = 128;
            _share_btn.clicked.connect (_on_share_clicked);
            btn_row.append (_share_btn);

            _populate ();
        }

        private void _populate () {
            if (_sources.length == 0) {
                var lbl = new Gtk.Label (_("No sources available"));
                lbl.add_css_class ("dim-label");
                _output_list_box.append (lbl);
                _share_btn.sensitive = false;
                return;
            }

            _chosen_source = _sources[0];
            foreach (unowned ScreenCastSourceOption source in _sources)
                _add_source_row (source);
        }

        private void _add_source_row (ScreenCastSourceOption source) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            row.add_css_class ("card");
            row.margin_top    = 2;
            row.margin_bottom = 2;

            string icon_name = source.source_type == 2u
                ? "window-symbolic" : "video-display-symbolic";
            var source_icon = new Gtk.Image.from_icon_name (icon_name);
            source_icon.pixel_size = 24;
            row.append (source_icon);

            var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            labels.hexpand = true;
            labels.halign = Gtk.Align.START;
            row.append (labels);

            var title = new Gtk.Label (source.label);
            title.halign = Gtk.Align.START;
            labels.append (title);

            if (source.app_id != "") {
                var app = new Gtk.Label (source.app_id);
                app.halign = Gtk.Align.START;
                app.add_css_class ("dim-label");
                labels.append (app);
            }

            var check = new Gtk.CheckButton ();
            check.active = (_chosen_source == source);
            source.check = check;
            row.append (check);

            var gesture = new Gtk.GestureClick ();
            gesture.released.connect ((n, x, y) => {
                _set_chosen (source);
            });
            row.add_controller (gesture);

            check.toggled.connect (() => {
                if (check.active) _set_chosen (source);
            });

            _output_list_box.append (row);
        }

        private void _set_chosen (ScreenCastSourceOption source) {
            _chosen_source = source;
            foreach (unowned ScreenCastSourceOption candidate in _sources) {
                if (candidate.check != null)
                    candidate.check.active = (candidate == source);
            }
        }

        private void _on_share_clicked () {
            ScreenCastSourceOption? source = _chosen_source;
            close_dialog ();
            if (source != null)
                selected (source.source_type, source.source_id);
            else
                cancelled ();
        }

        private void _on_cancel_clicked () {
            close_dialog ();
            cancelled ();
        }
    }
}
