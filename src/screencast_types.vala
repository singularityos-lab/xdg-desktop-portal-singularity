using GLib;

namespace Singularity.Portal {

    public const uint32 SCREENCAST_SOURCE_MONITOR = 1u;
    public const uint32 SCREENCAST_SOURCE_WINDOW = 2u;
    public const uint32 SCREENCAST_CURSOR_HIDDEN = 1u;
    public const uint32 SCREENCAST_CURSOR_EMBEDDED = 2u;

    public class ScreenCastSource : Object {
        public uint32 source_type { get; construct; }
        public string source_id { get; construct; }
        public string label { get; construct; }
        public string app_id { get; construct; }

        public ScreenCastSource (uint32 source_type,
                                 string source_id,
                                 string label,
                                 string app_id) {
            Object (
                source_type: source_type,
                source_id: source_id,
                label: label,
                app_id: app_id
            );
        }
    }

    public class ScreenCastSelection : Object {
        public uint32 source_type { get; construct; }
        public string source_id { get; construct; }

        public ScreenCastSelection (uint32 source_type, string source_id) {
            Object (source_type: source_type, source_id: source_id);
        }
    }

    public enum ScreenCastChooserStatus {
        SELECTED,
        CANCELLED,
        FAILED,
    }

    public class ScreenCastChooserResult : Object {
        public ScreenCastChooserStatus status { get; construct; }
        public ScreenCastSelection? selection { get; construct; }

        public ScreenCastChooserResult (ScreenCastChooserStatus status,
                                        ScreenCastSelection? selection = null) {
            Object (status: status, selection: selection);
        }
    }

    public class ScreenCastJson : Object {
        private const int64 PROTOCOL_VERSION = 1;

        public static string encode_sources (ScreenCastSource[] sources) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("version");
            builder.add_int_value (PROTOCOL_VERSION);
            builder.set_member_name ("sources");
            builder.begin_array ();
            foreach (unowned ScreenCastSource source in sources) {
                builder.begin_object ();
                builder.set_member_name ("type");
                builder.add_int_value (source.source_type);
                builder.set_member_name ("id");
                builder.add_string_value (source.source_id);
                builder.set_member_name ("label");
                builder.add_string_value (source.label);
                builder.set_member_name ("app_id");
                builder.add_string_value (source.app_id);
                builder.end_object ();
            }
            builder.end_array ();
            builder.end_object ();
            return generate (builder.get_root ());
        }

        public static ScreenCastSource[] decode_sources (string data) {
            ScreenCastSource[] sources = {};
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (data);
                Json.Node root_node = parser.get_root ();
                if (root_node.get_node_type () != Json.NodeType.OBJECT)
                    return sources;
                Json.Object root = root_node.get_object ();
                if (!valid_version (root) ||
                    !member_has_node_type (
                        root, "sources", Json.NodeType.ARRAY))
                    return sources;
                Json.Array array = root.get_array_member ("sources");
                for (uint index = 0; index < array.get_length (); index++) {
                    Json.Node item_node = array.get_element (index);
                    if (item_node.get_node_type () != Json.NodeType.OBJECT)
                        continue;
                    Json.Object item = item_node.get_object ();
                    if (!member_is_integer (item, "type") ||
                        !member_is_string (item, "id") ||
                        !member_is_string (item, "label") ||
                        (item.has_member ("app_id") &&
                         !member_is_string (item, "app_id")))
                        continue;
                    int64 raw_source_type = item.get_int_member ("type");
                    if (raw_source_type < 0 || raw_source_type > uint32.MAX)
                        continue;
                    uint32 source_type = (uint32) raw_source_type;
                    string source_id = item.get_string_member ("id");
                    string label = item.get_string_member ("label");
                    string app_id = item.has_member ("app_id")
                        ? item.get_string_member ("app_id") : "";
                    if ((source_type == SCREENCAST_SOURCE_MONITOR ||
                         source_type == SCREENCAST_SOURCE_WINDOW) &&
                        source_id != "") {
                        sources += new ScreenCastSource (
                            source_type, source_id, label, app_id);
                    }
                }
            } catch (Error caught) {
                warning ("ScreenCastJson: invalid source document: %s",
                    caught.message);
            }
            return sources;
        }

        public static string encode_selection (ScreenCastSelection selection) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("version");
            builder.add_int_value (PROTOCOL_VERSION);
            builder.set_member_name ("type");
            builder.add_int_value (selection.source_type);
            builder.set_member_name ("id");
            builder.add_string_value (selection.source_id);
            builder.end_object ();
            return generate (builder.get_root ());
        }

        public static ScreenCastSelection? decode_selection (string data) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (data);
                Json.Node root_node = parser.get_root ();
                if (root_node.get_node_type () != Json.NodeType.OBJECT)
                    return null;
                Json.Object root = root_node.get_object ();
                if (!valid_version (root) ||
                    !member_is_integer (root, "type") ||
                    !member_is_string (root, "id"))
                    return null;
                int64 raw_source_type = root.get_int_member ("type");
                if (raw_source_type < 0 || raw_source_type > uint32.MAX)
                    return null;
                uint32 source_type = (uint32) raw_source_type;
                string source_id = root.get_string_member ("id");
                if ((source_type != SCREENCAST_SOURCE_MONITOR &&
                     source_type != SCREENCAST_SOURCE_WINDOW) ||
                    source_id == "")
                    return null;
                return new ScreenCastSelection (source_type, source_id);
            } catch (Error caught) {
                return null;
            }
        }

        private static bool valid_version (Json.Object root) {
            return member_is_integer (root, "version") &&
                root.get_int_member ("version") == PROTOCOL_VERSION;
        }

        private static bool member_has_node_type (Json.Object object,
                                                  string name,
                                                  Json.NodeType node_type) {
            unowned Json.Node? node = object.get_member (name);
            return node != null && node.get_node_type () == node_type;
        }

        private static bool member_is_integer (Json.Object object,
                                               string name) {
            unowned Json.Node? node = object.get_member (name);
            return node != null &&
                node.get_node_type () == Json.NodeType.VALUE &&
                node.get_value_type () == typeof (int64);
        }

        private static bool member_is_string (Json.Object object,
                                              string name) {
            unowned Json.Node? node = object.get_member (name);
            return node != null &&
                node.get_node_type () == Json.NodeType.VALUE &&
                node.get_value_type () == typeof (string);
        }

        private static string generate (Json.Node root) {
            var generator = new Json.Generator ();
            generator.set_root (root);
            return generator.to_data (null);
        }
    }
}
