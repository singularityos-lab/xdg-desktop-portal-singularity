using GLib;

namespace Singularity.Portal {

    public struct UsbDeviceRequest {
        public string id;
        public HashTable<string, Variant> info;
        public HashTable<string, Variant> access;
    }

    namespace UsbLogic {
        private string prop(HashTable<string, Variant>? dict, string key) {
            if (dict == null) return "";
            var value = dict.lookup(key);
            if (value == null || !value.is_of_type(VariantType.STRING)) return "";
            return value.get_string();
        }

        public string device_label(HashTable<string, Variant> info) {
            var props = info.lookup("properties");
            HashTable<string, Variant>? table = null;
            if (props != null && props.is_of_type(VariantType.VARDICT)) {
                table = new HashTable<string, Variant>(str_hash, str_equal);
                var iter = props.iterator();
                string key;
                Variant value;
                while (iter.next("{sv}", out key, out value)) table.insert(key, value);
            }
            string vendor = prop(table, "ID_VENDOR_FROM_DATABASE");
            if (vendor == "") vendor = prop(table, "ID_VENDOR");
            string model = prop(table, "ID_MODEL_FROM_DATABASE");
            if (model == "") model = prop(table, "ID_MODEL");
            string label = (vendor + " " + model).strip().replace("_", " ");
            if (label != "") return label;
            string node = prop(info, "device-file");
            return node != "" ? node : _("USB Device");
        }

        public Variant selected_devices(UsbDeviceRequest[] devices, ConsentResult consent) {
            var list = new VariantBuilder(new VariantType("a(sa{sv})"));
            foreach (var device in devices) {
                if (!consent.has_selected(device.id)) continue;
                var access = new VariantBuilder(new VariantType("a{sv}"));
                if (device.access != null) {
                    device.access.foreach((key, value) => access.add("{sv}", key, value));
                }
                list.add("(s@a{sv})", device.id, access.end());
            }
            return list.end();
        }
    }

    [DBus (name = "org.freedesktop.impl.portal.Usb")]
    public class UsbPortal : Object {
        [DBus (name = "version")]
        public uint32 version { get { return 1; } }

        private DBusConnection _conn;
        private ConsentRunner _runner;

        [DBus (visible = false)]
        public UsbPortal(DBusConnection conn, ConsentRunner? runner = null) {
            _conn = conn;
            _runner = runner ?? new SubprocessConsentRunner();
        }

        public async void acquire_devices(ObjectPath handle, string parent_window, string app_id,
                                          UsbDeviceRequest[] devices, HashTable<string, Variant> options,
                                          out uint32 response, out HashTable<string, Variant> results) throws Error {
            results = new HashTable<string, Variant>(str_hash, str_equal);
            var request = new ConsentRequest();
            request.kind = "usb";
            request.app_id = app_id;
            request.app_name = portal_app_name(app_id);
            request.icon = "drive-harddisk-usb-symbolic";
            request.title = request.app_name != ""
                ? _("Allow %s to Use USB Devices?").printf(request.app_name)
                : _("Allow an App to Use USB Devices?");
            request.subtitle = _("The app gets direct access to the devices you choose.");
            request.body = _("Access ends when the app releases the device or quits.");
            foreach (var device in devices) {
                bool writable = false;
                var w = device.access != null ? device.access.lookup("writable") : null;
                if (w != null && w.is_of_type(VariantType.BOOLEAN)) writable = w.get_boolean();
                request.add_item(new ConsentItem(device.id, UsbLogic.device_label(device.info),
                    writable ? _("Read and write") : _("Read only")));
            }

            var portal_request = new PortalRequest(_conn, handle);
            var consent = yield _runner.ask(request, portal_request.cancellable);
            portal_request.unexport();
            if (!consent.granted) {
                response = consent.response == 2 ? 2 : 1;
                return;
            }
            results.insert("devices", UsbLogic.selected_devices(devices, consent));
            response = 0;
        }
    }
}
