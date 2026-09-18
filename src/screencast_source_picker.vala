using GLib;
using Gtk;

namespace Singularity.Portal {

    public class ScreenCastSourcePicker : Singularity.Shell.ShellDialog {
        public signal void selected (uint32 source_type, string source_id);
        public signal void cancelled ();

        private ScreenCastSource[] _sources;
        private ScreenCastSource? _selected_source;
        private Gtk.Box _source_list;
        private Gtk.Button _share_button;
        private HashTable<ScreenCastSource, Gtk.CheckButton> _checks;
        private bool _finished = false;

        public ScreenCastSourcePicker (GLib.Application? app,
                                       ScreenCastSource[] sources) {
            Object (
                application: app as Gtk.Application,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            _sources = sources;
            _checks = new HashTable<ScreenCastSource, Gtk.CheckButton> (
                direct_hash, direct_equal);
            add_css_class ("screencast-picker-dialog");
            _build ();
            close_request.connect (() => {
                _cancel ();
                return false;
            });
            hide ();
        }

        private void _build () {
            var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 14);
            card.halign = Gtk.Align.CENTER;
            card.valign = Gtk.Align.CENTER;
            card.add_css_class ("power-card");
            card.margin_top = 28;
            card.margin_bottom = 28;
            card.margin_start = 40;
            card.margin_end = 40;
            content_box.append (card);

            var icon = new Gtk.Image.from_icon_name ("video-display-symbolic");
            icon.pixel_size = 48;
            card.append (icon);

            var title = new Gtk.Label (_("Share your screen"));
            title.add_css_class ("title-1");
            card.append (title);

            var subtitle = new Gtk.Label (_("Choose what to share"));
            subtitle.add_css_class ("dim-label");
            subtitle.add_css_class ("body");
            card.append (subtitle);

            _source_list = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);
            _source_list.margin_top = 6;
            card.append (_source_list);

            var buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            buttons.halign = Gtk.Align.CENTER;
            buttons.margin_top = 4;
            card.append (buttons);

            var cancel_button = new Gtk.Button.with_label (_("Cancel"));
            cancel_button.add_css_class ("pill");
            cancel_button.width_request = 128;
            cancel_button.clicked.connect (() => {
                _cancel ();
            });
            buttons.append (cancel_button);

            _share_button = new Gtk.Button.with_label (_("Share"));
            _share_button.add_css_class ("pill");
            _share_button.add_css_class ("suggested-action");
            _share_button.width_request = 128;
            _share_button.clicked.connect (_share);
            buttons.append (_share_button);

            _populate ();
        }

        private void _populate () {
            if (_sources.length == 0) {
                var empty = new Gtk.Label (_("No sources available"));
                empty.add_css_class ("dim-label");
                _source_list.append (empty);
                _share_button.sensitive = false;
                return;
            }

            _selected_source = _sources[0];
            foreach (unowned ScreenCastSource source in _sources)
                _add_source (source);
        }

        private void _add_source (ScreenCastSource source) {
            var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
            row.add_css_class ("card");
            row.margin_top = 2;
            row.margin_bottom = 2;

            string icon_name = source.source_type == SCREENCAST_SOURCE_WINDOW
                ? "window-symbolic" : "video-display-symbolic";
            var icon = new Gtk.Image.from_icon_name (icon_name);
            icon.pixel_size = 24;
            row.append (icon);

            var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
            labels.hexpand = true;
            labels.halign = Gtk.Align.START;
            row.append (labels);

            var label = new Gtk.Label (source.label);
            label.halign = Gtk.Align.START;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.max_width_chars = 48;
            labels.append (label);

            if (source.app_id != "") {
                var app = new Gtk.Label (source.app_id);
                app.halign = Gtk.Align.START;
                app.add_css_class ("dim-label");
                labels.append (app);
            }

            var check = new Gtk.CheckButton ();
            check.active = source == _selected_source;
            _checks.insert (source, check);
            check.toggled.connect (() => {
                if (check.active)
                    _select (source);
            });
            row.append (check);

            var gesture = new Gtk.GestureClick ();
            gesture.released.connect (() => {
                _select (source);
            });
            row.add_controller (gesture);
            _source_list.append (row);
        }

        private void _select (ScreenCastSource source) {
            _selected_source = source;
            foreach (unowned ScreenCastSource candidate in _sources) {
                Gtk.CheckButton? check = _checks.lookup (candidate);
                if (check != null)
                    check.active = candidate == source;
            }
        }

        private void _share () {
            ScreenCastSource? source = _selected_source;
            if (source == null) {
                _cancel ();
                return;
            }
            if (_finished)
                return;
            _finished = true;
            base.close_dialog ();
            selected (source.source_type, source.source_id);
        }

        private void _cancel () {
            if (_finished)
                return;
            _finished = true;
            base.close_dialog ();
            cancelled ();
        }

        public override void close_dialog () {
            _cancel ();
        }
    }
}
