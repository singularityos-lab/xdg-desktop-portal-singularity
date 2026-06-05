using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.OpenURI.
     */
    [DBus (name = "org.freedesktop.impl.portal.OpenURI")]
    public class OpenURIPortal : Object {
        private AppChooserPortal _chooser;

        public OpenURIPortal(AppChooserPortal chooser) {
            _chooser = chooser;
        }

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
                string real_path = FileUtils.read_link(path);
                string uri = File.new_for_path(real_path).get_uri();
                
                string? choice = yield _chooser.open_uri_dialog(uri, title != "" ? title : "Open File");
                if (choice != null) {
                    _launch_app_for_uri(choice, uri);
                    response = 0;
                } else {
                    response = 1;
                }
            } catch (Error e) {
                warning("OpenURIPortal: OpenFile failed: %s", e.message);
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
                string? choice = yield _chooser.open_uri_dialog(uri, "Open Link");
                if (choice != null) {
                    _launch_app_for_uri(choice, uri);
                    response = 0;
                } else {
                    response = 1;
                }
            } catch (Error e) {
                warning("OpenURIPortal: OpenURI failed: %s", e.message);
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
                warning("OpenURIPortal: failed to launch app %s: %s", choice_id, e.message);
            }
        }
    }
}
