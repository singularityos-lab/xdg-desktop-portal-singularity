using GLib;
using Gtk;
using Singularity.Widgets;

namespace Singularity.Portal {

    public class ConsentDialog : Singularity.Shell.ShellDialog {
        public signal void finished(ConsentResult result);

        private ConsentRequest _request;
        private bool _done = false;
        private HashTable<string, SwitchRow> _switches = new HashTable<string, SwitchRow>(str_hash, str_equal);
        private Button? _grant_button = null;
        private bool _options_only = false;
        private string _choice = "";

        public ConsentDialog(GLib.Application? app, ConsentRequest request) {
            Object(
                application: app as Gtk.Application,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            _request = request;
            add_css_class("permission-dialog");
            add_css_class("consent-dialog");
            build();
            close_request.connect(() => {
                finish(new ConsentResult(1));
                return false;
            });
        }

        public override void close_dialog() {
            finish(new ConsentResult(1));
        }

        private void build() {
            var card = new Box(Orientation.VERTICAL, 16);
            card.halign = Align.CENTER;
            card.valign = Align.CENTER;
            card.add_css_class("power-card");
            card.margin_top = 28;
            card.margin_bottom = 28;
            card.margin_start = 40;
            card.margin_end = 40;
            card.width_request = 360;
            content_box.append(card);

            var icon = new Image.from_icon_name(large_icon_name(_request.icon != "" ? _request.icon : "dialog-question-symbolic"));
            icon.pixel_size = 64;
            card.append(icon);

            var title = new Label(_request.title);
            title.add_css_class("title-2");
            title.wrap = true;
            title.max_width_chars = 32;
            title.justify = Justification.CENTER;
            card.append(title);

            if (_request.subtitle != "") {
                var subtitle = new Label(_request.subtitle);
                subtitle.add_css_class("dim-label");
                subtitle.add_css_class("body");
                subtitle.wrap = true;
                subtitle.max_width_chars = 40;
                subtitle.justify = Justification.CENTER;
                card.append(subtitle);
            }

            switch (_request.kind) {
                case "background":
                    build_choices(card);
                    break;
                case "shortcuts":
                case "usb":
                    build_selection(card);
                    break;
                case "remote":
                    _options_only = true;
                    build_selection(card, true);
                    break;
                default:
                    build_buttons(card, false);
                    break;
            }

            if (_request.body != "") {
                var body = new Label(_request.body);
                body.add_css_class("dim-label");
                body.add_css_class("caption");
                body.wrap = true;
                body.max_width_chars = 44;
                body.justify = Justification.CENTER;
                card.append(body);
            }
        }

        private void build_choices(Box card) {
            var group = new PreferencesGroup();
            foreach (var item in _request.get_items()) {
                var row = new ActionRow(item.label, item.detail != "" ? item.detail : null);
                row.activatable = true;
                var chevron = new Image.from_icon_name("go-next-symbolic");
                chevron.pixel_size = 12;
                chevron.add_css_class("dim-label");
                chevron.valign = Align.CENTER;
                row.add_suffix(chevron);
                string choice = item.id;
                row.activated.connect(() => finish(new ConsentResult(0, choice)));
                group.add_row(row);
            }
            card.append(group);

            var deny = new Button.with_label(_request.deny_label != "" ? _request.deny_label : _("Don't Allow"));
            deny.add_css_class("pill");
            deny.add_css_class("destructive-action");
            deny.width_request = 128;
            deny.halign = Align.CENTER;
            deny.clicked.connect(() => finish(new ConsentResult(0, "forbid")));
            card.append(deny);
        }

        private void build_selection(Box card, bool with_choices = false) {
            var group = new PreferencesGroup();
            foreach (var item in _request.get_items()) {
                var row = new SwitchRow(item.label, item.detail != "" ? item.detail : null, item.selected);
                _switches.insert(item.id, row);
                row.notify["active"].connect(() => update_grant_sensitivity());
                group.add_row(row);
            }
            card.append(group);
            if (with_choices && _request.get_choices().length > 0) build_choice_row(card);
            build_buttons(card, true);
            update_grant_sensitivity();
        }

        private void build_choice_row(Box card) {
            foreach (var item in _request.get_choices()) {
                if (item.id == _request.choice) _choice = item.id;
            }
            if (_choice == "") _choice = _request.get_choices()[0].id;
            var group = new PreferencesGroup(_request.choice_title != "" ? _request.choice_title : null);
            var marks = new HashTable<string, Image>(str_hash, str_equal);
            foreach (var item in _request.get_choices()) {
                var row = new ActionRow(item.label, item.detail != "" ? item.detail : null);
                row.activatable = true;
                var mark = new Image.from_icon_name("object-select-symbolic");
                mark.valign = Align.CENTER;
                mark.visible = item.id == _choice;
                row.add_suffix(mark);
                marks.insert(item.id, mark);
                string id = item.id;
                row.activated.connect(() => {
                    _choice = id;
                    marks.foreach((key, image) => image.visible = key == id);
                });
                group.add_row(row);
            }
            card.append(group);
        }

        private void build_buttons(Box card, bool selection) {
            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 4;

            string deny_text = _request.deny_label != "" ? _request.deny_label : (selection ? _("Cancel") : _("Deny"));
            var deny = new Button.with_label(deny_text);
            deny.add_css_class("pill");
            deny.width_request = 128;
            deny.clicked.connect(() => finish(new ConsentResult(1)));
            buttons.append(deny);

            _grant_button = new Button.with_label(_request.grant_label != "" ? _request.grant_label : _("Allow"));
            _grant_button.add_css_class("pill");
            _grant_button.add_css_class("suggested-action");
            _grant_button.width_request = 128;
            _grant_button.clicked.connect(() => {
                var result = new ConsentResult(0, _choice);
                foreach (var item in _request.get_items()) {
                    var row = _switches.lookup(item.id);
                    if (row != null && row.active) result.select(item.id);
                }
                finish(result);
            });
            buttons.append(_grant_button);
            card.append(buttons);
        }

        private void update_grant_sensitivity() {
            if (_grant_button == null || _switches.size() == 0 || _options_only) return;
            bool any = false;
            _switches.foreach((id, row) => { if (row.active) any = true; });
            _grant_button.sensitive = any;
        }

        private void finish(ConsentResult result) {
            if (_done) return;
            _done = true;
            hide();
            finished(result);
        }
    }
}
