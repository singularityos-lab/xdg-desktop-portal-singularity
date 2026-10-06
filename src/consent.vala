using GLib;

namespace Singularity.Portal {

    public class ConsentItem : Object {
        public string id { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string detail { get; set; default = ""; }
        public bool selected { get; set; default = true; }

        public ConsentItem(string id, string label, string detail = "", bool selected = true) {
            this.id = id;
            this.label = label;
            this.detail = detail;
            this.selected = selected;
        }
    }

    public class ConsentRequest : Object {
        public string kind { get; set; default = "access"; }
        public string app_id { get; set; default = ""; }
        public string app_name { get; set; default = ""; }
        public string icon { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string subtitle { get; set; default = ""; }
        public string body { get; set; default = ""; }
        public string grant_label { get; set; default = ""; }
        public string deny_label { get; set; default = ""; }
        public string choice_title { get; set; default = ""; }
        public string choice { get; set; default = ""; }
        private ConsentItem[] _items = {};
        private ConsentItem[] _choices = {};

        public void add_item(ConsentItem item) {
            _items += item;
        }

        public void add_choice(ConsentItem choice) {
            _choices += choice;
        }

        public ConsentItem[] get_choices() {
            return _choices;
        }

        public ConsentItem[] get_items() {
            return _items;
        }
    }

    public class ConsentResult : Object {
        public uint32 response { get; set; default = 1; }
        public string choice { get; set; default = ""; }
        private string[] _selected = {};

        public ConsentResult(uint32 response = 1, string choice = "") {
            this.response = response;
            this.choice = choice;
        }

        public bool granted {
            get { return response == 0; }
        }

        public void select(string id) {
            _selected += id;
        }

        public string[] get_selected() {
            return _selected;
        }

        public bool has_selected(string id) {
            foreach (unowned string s in _selected) {
                if (s == id) return true;
            }
            return false;
        }
    }

    namespace ConsentJson {
        public string encode_request(ConsentRequest request) {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("version").add_int_value(1);
            builder.set_member_name("kind").add_string_value(request.kind);
            builder.set_member_name("app_id").add_string_value(request.app_id);
            builder.set_member_name("app_name").add_string_value(request.app_name);
            builder.set_member_name("icon").add_string_value(request.icon);
            builder.set_member_name("title").add_string_value(request.title);
            builder.set_member_name("subtitle").add_string_value(request.subtitle);
            builder.set_member_name("body").add_string_value(request.body);
            builder.set_member_name("grant_label").add_string_value(request.grant_label);
            builder.set_member_name("deny_label").add_string_value(request.deny_label);
            builder.set_member_name("items");
            builder.begin_array();
            foreach (var item in request.get_items()) {
                builder.begin_object();
                builder.set_member_name("id").add_string_value(item.id);
                builder.set_member_name("label").add_string_value(item.label);
                builder.set_member_name("detail").add_string_value(item.detail);
                builder.set_member_name("selected").add_boolean_value(item.selected);
                builder.end_object();
            }
            builder.end_array();
            if (request.get_choices().length > 0) {
                builder.set_member_name("choice_title").add_string_value(request.choice_title);
                builder.set_member_name("choice").add_string_value(request.choice);
                builder.set_member_name("choices");
                builder.begin_array();
                foreach (var item in request.get_choices()) {
                    builder.begin_object();
                    builder.set_member_name("id").add_string_value(item.id);
                    builder.set_member_name("label").add_string_value(item.label);
                    builder.set_member_name("detail").add_string_value(item.detail);
                    builder.end_object();
                }
                builder.end_array();
            }
            builder.end_object();
            var generator = new Json.Generator();
            generator.root = builder.get_root();
            return generator.to_data(null);
        }

        private string text(Json.Object obj, string key) {
            if (!obj.has_member(key)) return "";
            var node = obj.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(string)) return "";
            return node.get_string();
        }

        private Json.Object? parse_object(string data) {
            var parser = new Json.Parser();
            try {
                parser.load_from_data(data);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return null;
            return root.get_object();
        }

        public ConsentRequest? decode_request(string data) {
            var obj = parse_object(data);
            if (obj == null) return null;
            var request = new ConsentRequest();
            request.kind = text(obj, "kind");
            if (request.kind == "") return null;
            request.app_id = text(obj, "app_id");
            request.app_name = text(obj, "app_name");
            request.icon = text(obj, "icon");
            request.title = text(obj, "title");
            request.subtitle = text(obj, "subtitle");
            request.body = text(obj, "body");
            request.grant_label = text(obj, "grant_label");
            request.deny_label = text(obj, "deny_label");
            if (obj.has_member("items") && obj.get_member("items").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in obj.get_array_member("items").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var item_obj = node.get_object();
                    bool selected = !item_obj.has_member("selected") || item_obj.get_boolean_member("selected");
                    request.add_item(new ConsentItem(text(item_obj, "id"), text(item_obj, "label"),
                        text(item_obj, "detail"), selected));
                }
            }
            request.choice_title = text(obj, "choice_title");
            request.choice = text(obj, "choice");
            if (obj.has_member("choices") && obj.get_member("choices").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in obj.get_array_member("choices").get_elements()) {
                    if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                    var choice_obj = node.get_object();
                    string id = text(choice_obj, "id");
                    if (id != "") request.add_choice(new ConsentItem(id, text(choice_obj, "label"), text(choice_obj, "detail")));
                }
            }
            return request;
        }

        public string encode_result(ConsentResult result) {
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("response").add_int_value(result.response);
            builder.set_member_name("choice").add_string_value(result.choice);
            builder.set_member_name("selected");
            builder.begin_array();
            foreach (unowned string id in result.get_selected()) builder.add_string_value(id);
            builder.end_array();
            builder.end_object();
            var generator = new Json.Generator();
            generator.root = builder.get_root();
            return generator.to_data(null);
        }

        public ConsentResult? decode_result(string data) {
            var obj = parse_object(data);
            if (obj == null || !obj.has_member("response")) return null;
            var node = obj.get_member("response");
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(int64)) return null;
            int64 response = node.get_int();
            if (response < 0 || response > 2) return null;
            var result = new ConsentResult((uint32) response, text(obj, "choice"));
            if (obj.has_member("selected") && obj.get_member("selected").get_node_type() == Json.NodeType.ARRAY) {
                foreach (var element in obj.get_array_member("selected").get_elements()) {
                    if (element.get_node_type() == Json.NodeType.VALUE && element.get_value_type() == typeof(string))
                        result.select(element.get_string());
                }
            }
            return result;
        }
    }

    public interface ConsentRunner : Object {
        public abstract async ConsentResult ask(ConsentRequest request, Cancellable? cancellable);
    }

    public class SubprocessConsentRunner : Object, ConsentRunner {
        public const string BINARY = "singularity-portal-consent";

        public async ConsentResult ask(ConsentRequest request, Cancellable? cancellable) {
            try {
                var process = new Subprocess.newv({ resolve_binary() },
                    SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
                ulong cancelled_id = 0;
                if (cancellable != null)
                    cancelled_id = cancellable.cancelled.connect(() => process.force_exit());
                string? output = null;
                try {
                    yield process.communicate_utf8_async(ConsentJson.encode_request(request), null, out output, null);
                } finally {
                    if (cancellable != null) cancellable.disconnect(cancelled_id);
                }
                if (cancellable != null && cancellable.is_cancelled()) return new ConsentResult(2);
                if (!process.get_successful() || output == null || output.strip() == "") return new ConsentResult(2);
                var result = ConsentJson.decode_result(last_line(output));
                if (result == null) {
                    warning("ConsentRunner: malformed consent output");
                    return new ConsentResult(2);
                }
                return result;
            } catch (Error e) {
                warning("ConsentRunner: failed to run %s: %s", BINARY, e.message);
                return new ConsentResult(2);
            }
        }

        public static string last_line(string output) {
            string[] lines = output.strip().split("\n");
            for (int i = lines.length - 1; i >= 0; i--) {
                string line = lines[i].strip();
                if (line.has_prefix("{")) return line;
            }
            return "";
        }

        public static string resolve_binary() {
            try {
                string executable = FileUtils.read_link("/proc/self/exe");
                string candidate = Path.build_filename(Path.get_dirname(executable), BINARY);
                if (FileUtils.test(candidate, FileTest.IS_EXECUTABLE)) return candidate;
            } catch (Error e) {
            }
            return BINARY;
        }
    }

    public static string portal_app_name(string app_id) {
        if (app_id == "") return "";
        var info = new DesktopAppInfo(app_id + ".desktop");
        return info != null ? info.get_display_name() : app_id;
    }
}
