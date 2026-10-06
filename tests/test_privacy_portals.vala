using Singularity.Portal;

void test_consent_request_round_trip() {
    var request = new ConsentRequest();
    request.kind = "usb";
    request.app_id = "org.example.Flasher";
    request.title = "Allow Flasher to Use USB Devices?";
    request.add_item(new ConsentItem("dev1", "Acme Stick", "Read only"));
    request.add_item(new ConsentItem("dev2", "Acme Board", "Read and write", false));
    var decoded = ConsentJson.decode_request(ConsentJson.encode_request(request));
    assert(decoded != null);
    assert(decoded.kind == "usb");
    assert(decoded.app_id == "org.example.Flasher");
    assert(decoded.title == request.title);
    assert(decoded.get_items().length == 2);
    assert(decoded.get_items()[0].id == "dev1" && decoded.get_items()[0].selected);
    assert(decoded.get_items()[1].detail == "Read and write" && !decoded.get_items()[1].selected);
    assert(ConsentJson.decode_request("{}") == null);
    assert(ConsentJson.decode_request("garbage") == null);
}

void test_consent_result_round_trip() {
    var result = new ConsentResult(0, "allow");
    result.select("a");
    result.select("b");
    var decoded = ConsentJson.decode_result(ConsentJson.encode_result(result));
    assert(decoded != null && decoded.granted && decoded.choice == "allow");
    assert(decoded.has_selected("a") && decoded.has_selected("b") && !decoded.has_selected("c"));
    assert(ConsentJson.decode_result("{\"response\": 7}") == null);
    assert(ConsentJson.decode_result("{\"response\": \"0\"}") == null);
    assert(ConsentJson.decode_result("[]") == null);
    assert(SubprocessConsentRunner.last_line("debug noise\n{\"response\": 0}\n") == "{\"response\": 0}");
    assert(SubprocessConsentRunner.last_line("no json") == "");
}

void test_triggers() {
    assert(ShortcutTriggers.to_accelerator("CTRL+ALT+k") == "<Control><Alt>k");
    assert(ShortcutTriggers.to_accelerator("LOGO+SHIFT+F5") == "<Super><Shift>F5");
    assert(ShortcutTriggers.to_accelerator("CTRL+plus") == "<Control>plus");
    assert(ShortcutTriggers.to_accelerator("<Super>space") == "<Super>space");
    assert(ShortcutTriggers.to_accelerator("") == "");
    assert(ShortcutTriggers.to_accelerator("HYPER+x") == "");
    assert(ShortcutTriggers.to_trigger_description("<Control><Alt>k") == "Ctrl+Alt+K");
    assert(ShortcutTriggers.to_trigger_description("<Super>F5") == "Super+F5");
    assert(ShortcutTriggers.to_trigger_description("") == "");
}

void test_stored_shortcuts() {
    StoredShortcut[] list = {
        new StoredShortcut("org.example.Player", "play", "Play or pause", "<Super>p"),
        new StoredShortcut("org.example.Talk", "mute", "Mute", "")
    };
    var parsed = ShortcutTriggers.parse_stored(ShortcutTriggers.serialize(list));
    assert(parsed.length == 2);
    assert(parsed[0].app_id == "org.example.Player" && parsed[0].accelerator == "<Super>p");
    assert(parsed[1].id == "mute" && parsed[1].accelerator == "");
    assert(ShortcutTriggers.parse_stored(new Variant.string("x")).length == 0);
}

void test_shortcut_store_memory() {
    var store = new ShortcutStore.in_memory();
    int changes = 0;
    store.changed.connect(() => changes++);
    store.add({ new StoredShortcut("a.b.C", "one", "One", "<Super>1") });
    store.add({ new StoredShortcut("a.b.C", "one", "One again", "<Super>2"),
                new StoredShortcut("a.b.D", "two", "Two", "") });
    assert(changes == 2);
    assert(store.all().length == 2);
    assert(store.find("a.b.C", "one").accelerator == "<Super>2");
    assert(store.for_app("a.b.D").length == 1);
    assert(store.find("a.b.D", "one") == null);
}

void test_background_logic() {
    var states = BackgroundLogic.app_states({ "org.example.Editor", "org.example.Player.desktop", "" });
    assert(states.size() == 2);
    assert(states.lookup("org.example.Editor").get_uint32() == APP_STATE_RUNNING);
    assert(states.contains("org.example.Player"));
    assert(BackgroundLogic.choice_to_result(new ConsentResult(0, "allow")) == BACKGROUND_ALLOW);
    assert(BackgroundLogic.choice_to_result(new ConsentResult(0, "forbid")) == BACKGROUND_FORBID);
    assert(BackgroundLogic.choice_to_result(new ConsentResult(0, "once")) == BACKGROUND_ALLOW_ONCE);
    assert(BackgroundLogic.choice_to_result(new ConsentResult(1)) == BACKGROUND_ALLOW_ONCE);
    string contents = BackgroundLogic.autostart_contents("org.example.Player", "Player", { "player", "--hidden arg" }, true);
    var file = new KeyFile();
    try {
        file.load_from_data(contents, -1, KeyFileFlags.NONE);
        assert(file.get_string("Desktop Entry", "X-XDP-Autostart") == "org.example.Player");
        assert(file.get_string("Desktop Entry", "Exec") == "player \"--hidden arg\"");
        assert(file.get_boolean("Desktop Entry", "DBusActivatable"));
        assert(BackgroundLogic.exec_quote("a$b") == "\"a\\$b\"");
        assert(BackgroundLogic.exec_quote("") == "\"\"");
    } catch (Error e) {
        assert_not_reached();
    }
}

void test_usb_logic() {
    var props = new VariantBuilder(new VariantType("a{sv}"));
    props.add("{sv}", "ID_VENDOR_FROM_DATABASE", new Variant.string("Acme"));
    props.add("{sv}", "ID_MODEL", new Variant.string("Flash_Stick"));
    var info = new HashTable<string, Variant>(str_hash, str_equal);
    info.insert("properties", props.end());
    info.insert("device-file", new Variant.string("/dev/bus/usb/001/004"));
    assert(UsbLogic.device_label(info) == "Acme Flash Stick");
    var bare = new HashTable<string, Variant>(str_hash, str_equal);
    bare.insert("device-file", new Variant.string("/dev/bus/usb/001/005"));
    assert(UsbLogic.device_label(bare) == "/dev/bus/usb/001/005");

    var access = new HashTable<string, Variant>(str_hash, str_equal);
    access.insert("writable", new Variant.boolean(true));
    UsbDeviceRequest[] devices = {
        UsbDeviceRequest() { id = "one", info = info, access = access },
        UsbDeviceRequest() { id = "two", info = bare, access = new HashTable<string, Variant>(str_hash, str_equal) }
    };
    var consent = new ConsentResult(0);
    consent.select("one");
    var selected = UsbLogic.selected_devices(devices, consent);
    assert(selected.n_children() == 1);
    string id;
    Variant opts;
    selected.get_child(0, "(s@a{sv})", out id, out opts);
    assert(id == "one");
    bool writable = false;
    assert(opts.lookup("writable", "b", out writable) && writable);
}

class FakeRunner : Object, ConsentRunner {
    public ConsentResult answer;
    public ConsentRequest? last = null;

    public FakeRunner(ConsentResult answer) {
        this.answer = answer;
    }

    public async ConsentResult ask(ConsentRequest request, Cancellable? cancellable) {
        last = request;
        return answer;
    }
}

void test_access_portal() {
    var runner = new FakeRunner(new ConsentResult(0));
    var portal = new AccessPortal(null, runner);
    var loop = new MainLoop();
    uint32 response = 99;
    var options = new HashTable<string, Variant>(str_hash, str_equal);
    options.insert("icon", new Variant.string("find-location-symbolic"));
    options.insert("grant_label", new Variant.string("Grant Access"));
    portal.access_dialog.begin(new ObjectPath("/org/freedesktop/portal/desktop/request/1_1/t"), "org.example.Map", "",
        "Allow Map to Access Your Location?", "Map wants to use your location", "", options, (obj, res) => {
            HashTable<string, Variant> results;
            try {
                portal.access_dialog.end(res, out response, out results);
            } catch (Error e) {
                assert_not_reached();
            }
            loop.quit();
        });
    loop.run();
    assert(response == 0);
    assert(runner.last.kind == "access");
    assert(runner.last.icon == "find-location-symbolic");
    assert(runner.last.grant_label == "Grant Access");
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/privacy/consent/request", test_consent_request_round_trip);
    Test.add_func("/privacy/consent/result", test_consent_result_round_trip);
    Test.add_func("/privacy/shortcuts/triggers", test_triggers);
    Test.add_func("/privacy/shortcuts/stored", test_stored_shortcuts);
    Test.add_func("/privacy/shortcuts/store", test_shortcut_store_memory);
    Test.add_func("/privacy/background/logic", test_background_logic);
    Test.add_func("/privacy/usb/logic", test_usb_logic);
    Test.add_func("/privacy/access/portal", test_access_portal);
    return Test.run();
}
