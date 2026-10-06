using GLib;

namespace Singularity.Portal {

    public class StoredShortcut : Object {
        public string app_id { get; set; }
        public string id { get; set; }
        public string description { get; set; }
        public string accelerator { get; set; }

        public StoredShortcut(string app_id, string id, string description, string accelerator) {
            this.app_id = app_id;
            this.id = id;
            this.description = description;
            this.accelerator = accelerator;
        }
    }

    namespace ShortcutTriggers {
        public string to_accelerator(string trigger) {
            string value = trigger.strip();
            if (value == "") return "";
            if (value.has_prefix("<")) return value;
            string[] parts = value.split("+");
            var accel = new StringBuilder();
            string key = "";
            for (int i = 0; i < parts.length; i++) {
                string part = parts[i].strip();
                if (part == "" && i == parts.length - 1 && i > 0) {
                    key = "plus";
                    continue;
                }
                if (i == parts.length - 1) {
                    key = part;
                    continue;
                }
                switch (part.up()) {
                    case "CTRL":
                    case "CONTROL":
                    case "PRIMARY":
                        accel.append("<Control>");
                        break;
                    case "ALT":
                        accel.append("<Alt>");
                        break;
                    case "SHIFT":
                        accel.append("<Shift>");
                        break;
                    case "LOGO":
                    case "SUPER":
                    case "META":
                        accel.append("<Super>");
                        break;
                    case "NUM":
                        break;
                    default:
                        return "";
                }
            }
            if (key == "") return "";
            if (key.length == 1) key = key.down();
            accel.append(key);
            return accel.str;
        }

        public string to_trigger_description(string accelerator) {
            if (accelerator == "") return "";
            var parts = new GenericArray<string>();
            string rest = accelerator;
            while (rest.has_prefix("<")) {
                int end = rest.index_of(">");
                if (end < 0) break;
                string mod = rest.substring(1, end - 1);
                rest = rest.substring(end + 1);
                switch (mod) {
                    case "Control":
                    case "Primary":
                        parts.add("Ctrl");
                        break;
                    case "Super":
                        parts.add("Super");
                        break;
                    default:
                        parts.add(mod);
                        break;
                }
            }
            if (rest != "") parts.add(rest.length == 1 ? rest.up() : rest);
            return string.joinv("+", parts.data);
        }

        public StoredShortcut[] parse_stored(Variant value) {
            StoredShortcut[] result = {};
            if (!value.is_of_type(new VariantType("a(ssss)"))) return result;
            var iter = value.iterator();
            string app_id, id, description, accelerator;
            while (iter.next("(ssss)", out app_id, out id, out description, out accelerator))
                result += new StoredShortcut(app_id, id, description, accelerator);
            return result;
        }

        public Variant serialize(StoredShortcut[] shortcuts) {
            var builder = new VariantBuilder(new VariantType("a(ssss)"));
            foreach (var s in shortcuts)
                builder.add("(ssss)", s.app_id, s.id, s.description, s.accelerator);
            return builder.end();
        }
    }
}
