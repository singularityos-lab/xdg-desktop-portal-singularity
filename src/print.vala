using GLib;
using Gtk;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Print with the Singularity
     * print dialog. PreparePrint shows the dialog parented to the
     * calling window and returns GTK print settings plus a token; Print
     * receives the rendered document and submits it with the options
     * chosen for that token, or saves it when "Save as PDF" was picked.
     */
    [DBus (name = "org.freedesktop.impl.portal.Print")]
    public class PrintPortal : Object {
        private class Prepared : Object {
            public Singularity.Print.JobOptions options;
            public Singularity.Print.PrinterCapabilities? caps;
        }

        private HashTable<uint32, Prepared> prepared = new HashTable<uint32, Prepared>(direct_hash, direct_equal);
        private uint32 next_token = 1;
        private static bool gtk_ready;

        public PrintPortal(GLib.Application? app = null) {
        }

        [DBus (name = "version")]
        public uint32 version { get { return 3; } }

        public async void prepare_print(
            ObjectPath handle,
            string app_id,
            string parent_window,
            string title,
            HashTable<string, Variant> settings_in,
            HashTable<string, Variant> page_setup_in,
            HashTable<string, Variant> options,
            out uint32 response,
            out HashTable<string, Variant> results
        ) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            var initial = Singularity.Print.PresetStore.get_default().last_used(app_id) ?? new Singularity.Print.JobOptions();
            try {
                var gtk_settings = new Gtk.PrintSettings.from_gvariant(to_vardict(settings_in));
                initial.from_gtk_settings(gtk_settings);
                if (page_setup_in.size() > 0) {
                    var ps = new Gtk.PageSetup.from_gvariant(to_vardict(page_setup_in));
                    initial.media = Singularity.Print.Media.keyword_for_paper(ps.get_paper_size());
                    initial.landscape = ps.get_orientation() == PageOrientation.LANDSCAPE
                        || ps.get_orientation() == PageOrientation.REVERSE_LANDSCAPE;
                }
            } catch (Error e) {
                debug("Print portal settings ignored: %s", e.message);
            }
            initial.output_path = "";
            initial.copies = int.max(initial.copies, 1);

            var dialog = yield show_dialog(handle, app_id, parent_window, title, initial);
            if (dialog == null || dialog.result != Singularity.Print.DialogResult.APPLIED) {
                response = 1;
                return;
            }
            var chosen = dialog.options;
            var p = new Prepared();
            p.options = chosen.copy();
            p.caps = dialog.capabilities;
            uint32 token = next_token++;
            prepared.insert(token, p);

            var settings = chosen.to_gtk_settings();
            settings.set_n_copies(1);
            settings.set_collate(false);
            settings.set_print_pages(PrintPages.ALL);
            var format = Singularity.Print.PageFormat.from_options(chosen, dialog.capabilities);
            results.insert("settings", settings.to_gvariant());
            results.insert("page-setup", format.to_page_setup().to_gvariant());
            results.insert("token", new Variant.uint32(token));
            response = 0;
        }

        public async void print(
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
            Prepared? job = null;
            var token_v = options.lookup("token");
            if (token_v != null && token_v.is_of_type(VariantType.UINT32)) {
                job = prepared.lookup(token_v.get_uint32());
                prepared.remove(token_v.get_uint32());
            }
            if (job == null) {
                var initial = Singularity.Print.PresetStore.get_default().last_used(app_id)
                    ?? new Singularity.Print.JobOptions();
                var dialog = yield show_dialog(handle, app_id, parent_window, title, initial);
                if (dialog == null || dialog.result != Singularity.Print.DialogResult.APPLIED) {
                    response = 1;
                    return;
                }
                job = new Prepared();
                job.options = dialog.options.copy();
                job.caps = dialog.capabilities;
            }

            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity", "print");
            DirUtils.create_with_parents(dir, 0700);
            string path = Path.build_filename(dir, "portal-%s".printf(Uuid.string_random()));
            var file = File.new_for_path(path);
            try {
                var out_stream = yield file.replace_async(null, false, FileCreateFlags.PRIVATE, Priority.DEFAULT, null);
                yield out_stream.splice_async(fd, OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET,
                                              Priority.DEFAULT, null);
                string format = sniff(path);
                if (job.options.printer == Singularity.Print.Printer.PDF_PRINTER || job.options.printer == "") {
                    if (job.options.output_path == "") {
                        response = 1;
                        FileUtils.remove(path);
                        return;
                    }
                    var target = File.new_for_path(job.options.output_path);
                    yield file.move_async(target, FileCopyFlags.OVERWRITE, Priority.DEFAULT, null, null);
                } else {
                    var backend = Singularity.Print.PrinterBackend.get_default();
                    int id = yield backend.submit(job.options.printer, path, title, job.options, job.caps, format);
                    var printer = new Singularity.Print.Printer();
                    printer.name = job.options.printer;
                    Singularity.Print.JobWatcher.get_default().watch(printer, id, title);
                    FileUtils.remove(path);
                }
                response = 0;
            } catch (Error e) {
                FileUtils.remove(path);
                warning("Print portal could not print: %s", e.message);
                response = 2;
            }
        }

        private static string sniff(string path) {
            try {
                var stream = File.new_for_path(path).read();
                uint8 buf[8];
                size_t n;
                stream.read_all(buf, out n);
                string head = ((string) buf).substring(0, (long) int.min((int) n, 5));
                if (head.has_prefix("%PDF")) return "application/pdf";
                if (head.has_prefix("%!")) return "application/postscript";
            } catch (Error e) {
            }
            return "application/octet-stream";
        }

        private static Variant to_vardict(HashTable<string, Variant> table) {
            var b = new VariantBuilder(VariantType.VARDICT);
            table.foreach((k, v) => b.add("{sv}", k, v));
            return b.end();
        }

        private async Singularity.Print.PrintDialog? show_dialog(ObjectPath handle, string app_id, string parent_window,
                                                                  string title, Singularity.Print.JobOptions initial) {
            if (!gtk_ready && !(gtk_ready = Gtk.init_check())) {
                warning("Print portal: no display for the print dialog");
                return null;
            }
            PortalRequest? request = null;
            try {
                request = new PortalRequest(Bus.get_sync(BusType.SESSION), handle);
            } catch (Error e) {
                request = null;
            }
            var dialog = new Singularity.Print.PrintDialog(null, null, initial, app_id);
            dialog.apply_only = true;
            parent_to(dialog, parent_window);
            bool done = false;
            dialog.finished.connect((r) => {
                done = true;
                Idle.add(show_dialog.callback);
            });
            if (request != null) {
                request.cancellable.cancelled.connect(() => {
                    if (!done) dialog.close();
                });
            }
            dialog.open_dialog();
            yield;
            if (request != null) request.unexport();
            return dialog;
        }

        private static void parent_to(Gtk.Window window, string parent_window) {
            if (!parent_window.has_prefix("wayland:")) return;
            string handle = parent_window.substring("wayland:".length);
            ((Gtk.Widget) window).realize.connect(() => {
                var toplevel = window.get_surface() as Gdk.Wayland.Toplevel;
                if (toplevel != null && !toplevel.set_transient_for_exported(handle))
                    debug("Cannot parent print dialog to %s", handle);
            });
            window.modal = true;
        }
    }
}
