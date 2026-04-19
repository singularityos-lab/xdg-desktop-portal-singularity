using GLib;
using Gtk;
using GtkLayerShell;
using Singularity.Widgets;
using Singularity.Shell;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.AppChooser and OpenURI.
     */
    [DBus (name = "org.freedesktop.impl.portal.AppChooser")]
    public class AppChooserPortal : Object {
        private GLib.Application? _app;

        public AppChooserPortal(GLib.Application? app = null) {
            _app = app;
        }

        /** presents the application chooser dialog and returns the selected choice id */
        public async string? open_uri_dialog(string uri, string heading_text = "Choose Application") {
            string? selected_choice = null;
            bool done = false;

            // Get choices for this URI
            string? content_type = null;
            try {
                var file = File.new_for_uri(uri);
                var info = file.query_info(FileAttribute.STANDARD_CONTENT_TYPE, 0);
                content_type = info.get_content_type();
            } catch (Error e) {}

            string[] choices = {};
            if (content_type != null) {
                var app_infos = AppInfo.get_all_for_type(content_type);
                foreach (var info in app_infos) {
                    choices += info.get_id();
                }
            }

            if (choices.length == 0) return null;
            if (choices.length == 1) return choices[0];

            var dialog = new ShellDialog(_app);
            dialog.add_css_class("run-dialog");

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 28; box.margin_bottom = 24; box.margin_start = 24; box.margin_end = 24;

            var icon = new Image.from_icon_name("application-x-executable-symbolic");
            icon.pixel_size = 48; icon.add_css_class("dim-label");
            box.append(icon);

            var title_lbl = new Label(heading_text);
            title_lbl.add_css_class("title-2");
            title_lbl.wrap = true; title_lbl.justify = Justification.CENTER;
            box.append(title_lbl);

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER; scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.min_content_height = 200; scroll.max_content_height = 400;

            var list = new ListBox();
            list.selection_mode = SelectionMode.NONE; list.add_css_class("boxed-list");

            foreach (string choice_id in choices) {
                var info = AppInfo.create_from_commandline(choice_id, null, AppInfoCreateFlags.NONE);
                // Try to find proper desktop info
                foreach (var ai in AppInfo.get_all()) {
                    if (ai.get_id() == choice_id || ai.get_id() == choice_id + ".desktop") { info = ai; break; }
                }

                var row = new Box(Orientation.HORIZONTAL, 12);
                row.margin_top = 8; row.margin_bottom = 8; row.margin_start = 12; row.margin_end = 12;

                var gicon = info != null ? info.get_icon() : null;
                var app_icon = (gicon != null) ? new Image.from_gicon(gicon) : new Image.from_icon_name("application-x-executable");
                app_icon.pixel_size = 32;
                row.append(app_icon);

                var name_lbl = new Label(info != null ? info.get_display_name() : choice_id);
                name_lbl.hexpand = true; name_lbl.xalign = 0;
                row.append(name_lbl);

                var list_row = new ListBoxRow();
                list_row.set_child(row);
                list_row.set_data<string>("choice-id", choice_id);
                list.append(list_row);
            }

            list.row_activated.connect((row) => {
                selected_choice = row.get_data<string>("choice-id");
                done = true;
                dialog.close_dialog();
            });

            scroll.set_child(list);
            box.append(scroll);

            var cancel_btn = new Button.with_label("Cancel");
            cancel_btn.halign = Align.CENTER; cancel_btn.width_request = 120;
            cancel_btn.clicked.connect(() => { done = true; dialog.close_dialog(); });
            box.append(cancel_btn);

            dialog.content_box.append(box);
            dialog.open_dialog();

            while (!done) {
                Idle.add(open_uri_dialog.callback, Priority.DEFAULT_IDLE);
                yield;
            }

            return selected_choice;
        }

        /** Presents the application chooser dialog. */
        public async void choose_application(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string[] choices,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            if (choices.length == 0) {
                response = 1;
                return;
            }

            // Single choice: skip the dialog
            if (choices.length == 1) {
                string choice = choices[0];
                if (choice.has_suffix(".desktop"))
                    choice = choice.substring(0, choice.length - 8);
                results.insert("choice", new Variant.string(choice));
                response = 0;
                return;
            }

            string? selected_choice = null;
            bool done = false;

            var dialog = new ShellDialog(_app);
            dialog.add_css_class("run-dialog");

            var box = new Box(Orientation.VERTICAL, 16);
            box.margin_top = 28; box.margin_bottom = 24; box.margin_start = 24; box.margin_end = 24;

            var icon = new Image.from_icon_name("application-x-executable-symbolic");
            icon.pixel_size = 48; icon.add_css_class("dim-label");
            box.append(icon);

            string heading = "Choose Application";
            if (options.contains("heading"))
                heading = options.get("heading").get_string();
            var title_lbl = new Label(heading);
            title_lbl.add_css_class("title-2");
            title_lbl.wrap = true; title_lbl.justify = Justification.CENTER;
            box.append(title_lbl);

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER; scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.min_content_height = 200; scroll.max_content_height = 400;

            var list = new ListBox();
            list.selection_mode = SelectionMode.NONE; list.add_css_class("boxed-list");

            foreach (string choice_id in choices) {
                string desktop_id = choice_id;
                if (!desktop_id.has_suffix(".desktop"))
                    desktop_id = desktop_id + ".desktop";

                var info = new DesktopAppInfo(desktop_id);

                var row = new Box(Orientation.HORIZONTAL, 12);
                row.margin_top = 8; row.margin_bottom = 8; row.margin_start = 12; row.margin_end = 12;

                if (info != null && info.get_icon() != null) {
                    var app_icon = new Image.from_gicon(info.get_icon());
                    app_icon.pixel_size = 32;
                    row.append(app_icon);
                } else {
                    var app_icon = new Image.from_icon_name("application-x-executable");
                    app_icon.pixel_size = 32;
                    row.append(app_icon);
                }

                string display_name = (info != null) ? info.get_display_name() : choice_id;
                var name_lbl = new Label(display_name);
                name_lbl.hexpand = true; name_lbl.xalign = 0;
                row.append(name_lbl);

                var list_row = new ListBoxRow();
                list_row.set_child(row);
                // Strip .desktop suffix for matching
                string clean_id = choice_id;
                if (clean_id.has_suffix(".desktop"))
                    clean_id = clean_id.substring(0, clean_id.length - 8);
                list_row.set_data<string>("choice-id", clean_id);
                list.append(list_row);
            }

            list.row_activated.connect((row) => {
                selected_choice = row.get_data<string>("choice-id");
                done = true;
                dialog.close_dialog();
            });

            scroll.set_child(list);
            box.append(scroll);

            var cancel_btn = new Button.with_label("Cancel");
            cancel_btn.halign = Align.CENTER; cancel_btn.width_request = 120;
            cancel_btn.margin_top = 4;
            cancel_btn.clicked.connect(() => { done = true; dialog.close_dialog(); });
            box.append(cancel_btn);

            dialog.content_box.append(box);

            dialog.close_request.connect(() => {
                if (!done) done = true;
                return false;
            });

            dialog.open_dialog();

            while (!done) {
                Idle.add(choose_application.callback, Priority.DEFAULT_IDLE);
                yield;
            }

            if (selected_choice != null) {
                results.insert("choice", new Variant.string(selected_choice));
                response = 0;
            } else {
                response = 1;
            }
        }

        /* ─── OpenURI implementation ─── */

        public async void open_file(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            UnixInputStream fd,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            
            try {
                // Get path from fd
                string path = "/proc/self/fd/%d".printf(fd.get_fd());
                char[] buf = new char[4096];
                ssize_t len = Posix.readlink(path, buf);
                if (len < 0) {
                    response = 1;
                    return;
                }
                string real_path = ((string)buf).substring(0, (int)len);
                string uri = File.new_for_path(real_path).get_uri();
                
                string? choice = yield open_uri_dialog(uri, title != "" ? title : "Open File");
                if (choice != null) {
                    _launch_app_for_uri(choice, uri);
                    response = 0;
                } else {
                    response = 1;
                }
            } catch (Error e) {
                warning("AppChooserPortal: OpenFile failed: %s", e.message);
                response = 2;
            }
        }

        public async void open_uri(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string uri,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            
            try {
                string? choice = yield open_uri_dialog(uri, "Open Link");
                if (choice != null) {
                    _launch_app_for_uri(choice, uri);
                    response = 0;
                } else {
                    response = 1;
                }
            } catch (Error e) {
                warning("AppChooserPortal: OpenURI failed: %s", e.message);
                response = 2;
            }
        }

        private void _launch_app_for_uri(string choice_id, string uri) {
            try {
                var app_info = AppInfo.create_from_commandline(choice_id, null, AppInfoCreateFlags.NONE);
                foreach (var ai in AppInfo.get_all()) {
                    if (ai.get_id() == choice_id || ai.get_id() == choice_id + ".desktop") { 
                        app_info = ai; 
                        break; 
                    }
                }
                
                List<File> files = new List<File>();
                files.append(File.new_for_uri(uri));
                app_info.launch(files, null);
            } catch (Error e) {
                warning("AppChooserPortal: failed to launch app %s: %s", choice_id, e.message);
            }
        }

        /** Dynamic choice updates (not yet implemented). */
        public void update_choices(ObjectPath handle, string[] choices) throws Error {
        }
    }
}
