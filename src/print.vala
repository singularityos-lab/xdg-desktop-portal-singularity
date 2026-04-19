using GLib;
using Gtk;
using GtkLayerShell;
using Singularity.Widgets;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Print.
     *
     * Uses Gtk.PrintUnixDialog for print setup. This is currently a
     * regular toplevel rather than a layer-shell dialog because
     * Gtk.PrintUnixDialog provides its own window management.
     */
    [DBus (name = "org.freedesktop.impl.portal.Print")]
    public class PrintPortal : Object {
        public PrintPortal(GLib.Application? app = null) {
        }

        public async void prepare_print(
            ObjectPath handle,
            string app_id,
            string parent_window,
            HashTable<string, Variant> settings_in,
            HashTable<string, Variant> page_setup_in,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);

            bool done = false;
            uint32 user_response = 1;
            Gtk.PrintSettings? final_settings = null;
            Gtk.PageSetup? final_page_setup = null;

            var print_settings = new Gtk.PrintSettings();
            settings_in.foreach((key, val) => {
                print_settings.set(key, val.get_string());
            });

            var page_setup = new Gtk.PageSetup();
            if (page_setup_in.contains("PPDName")) {
                var paper = Gtk.PaperSize.get_default();
                page_setup.set_paper_size(new Gtk.PaperSize(paper));
            }
            if (page_setup_in.contains("Orientation")) {
                string orient = page_setup_in.get("Orientation").get_string();
                if (orient == "landscape")
                    page_setup.set_orientation(PageOrientation.LANDSCAPE);
                else if (orient == "reverse-landscape")
                    page_setup.set_orientation(PageOrientation.REVERSE_LANDSCAPE);
                else if (orient == "reverse-portrait")
                    page_setup.set_orientation(PageOrientation.REVERSE_PORTRAIT);
            }

            var print_dialog = new Gtk.PrintUnixDialog("Print", null);
            print_dialog.set_settings(print_settings);
            print_dialog.set_page_setup(page_setup);
            print_dialog.manual_capabilities =
                PrintCapabilities.PAGE_SET |
                PrintCapabilities.COPIES |
                PrintCapabilities.COLLATE |
                PrintCapabilities.REVERSE |
                PrintCapabilities.SCALE |
                PrintCapabilities.NUMBER_UP;

            print_dialog.response.connect((resp) => {
                if (resp == ResponseType.OK) {
                    final_settings = print_dialog.get_settings();
                    final_page_setup = print_dialog.get_page_setup();
                    user_response = 0;
                } else {
                    user_response = 1;
                }
                done = true;
                print_dialog.close();
            });

            print_dialog.close_request.connect(() => {
                if (!done) {
                    user_response = 1;
                    done = true;
                }
                return false;
            });

            print_dialog.present();

            while (!done) {
                Idle.add(prepare_print.callback, Priority.DEFAULT_IDLE);
                yield;
            }

            if (user_response == 0 && final_settings != null) {
                var settings_builder = new VariantBuilder(new VariantType("a{sv}"));
                final_settings.@foreach((key, val) => {
                    settings_builder.add("{sv}", key, new Variant.string(val));
                });
                results.insert("settings", settings_builder.end());

                var ps_builder = new VariantBuilder(new VariantType("a{sv}"));
                if (final_page_setup != null) {
                    var paper = final_page_setup.get_paper_size();
                    ps_builder.add("{sv}", "PPDName",
                        new Variant.string(paper.get_ppd_name() ?? paper.get_name()));
                    ps_builder.add("{sv}", "Name",
                        new Variant.string(paper.get_display_name()));
                    ps_builder.add("{sv}", "Width",
                        new Variant.string("%.2f".printf(paper.get_width(Unit.MM))));
                    ps_builder.add("{sv}", "Height",
                        new Variant.string("%.2f".printf(paper.get_height(Unit.MM))));
                    string orient_str = "portrait";
                    switch (final_page_setup.get_orientation()) {
                        case PageOrientation.LANDSCAPE: orient_str = "landscape"; break;
                        case PageOrientation.REVERSE_LANDSCAPE: orient_str = "reverse-landscape"; break;
                        case PageOrientation.REVERSE_PORTRAIT: orient_str = "reverse-portrait"; break;
                    }
                    ps_builder.add("{sv}", "Orientation", new Variant.string(orient_str));
                    ps_builder.add("{sv}", "MarginTop",
                        new Variant.string("%.2f".printf(final_page_setup.get_top_margin(Unit.MM))));
                    ps_builder.add("{sv}", "MarginBottom",
                        new Variant.string("%.2f".printf(final_page_setup.get_bottom_margin(Unit.MM))));
                    ps_builder.add("{sv}", "MarginLeft",
                        new Variant.string("%.2f".printf(final_page_setup.get_left_margin(Unit.MM))));
                    ps_builder.add("{sv}", "MarginRight",
                        new Variant.string("%.2f".printf(final_page_setup.get_right_margin(Unit.MM))));
                }
                results.insert("page-setup", ps_builder.end());
                results.insert("token", new Variant.uint32(1));
            }

            response = user_response;
        }

        public async void print(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            // Frontend handles the actual print using the token
            response = 0;
        }
    }
}
