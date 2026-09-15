using GLib;
using Singularity.Portal;

private class FakeCapture : Object, ScreenCastCapture {
    public uint32 node_id { get { return 42u; } }
    public bool failed { get { return false; } }
    public bool stopped { get; private set; default = false; }

    public void stop () {
        stopped = true;
    }
}

private class FakeCaptureManager : Object, ScreenCastCaptureManager {
    public FakeCapture[] captures = {};
    public uint32 last_source_type { get; private set; default = 0u; }
    public string last_source_id { get; private set; default = ""; }
    public bool last_paint_cursors { get; private set; default = false; }
    public uint32 available_source_types {
        get { return SCREENCAST_SOURCE_MONITOR | SCREENCAST_SOURCE_WINDOW; }
    }

    public ScreenCastSource[] list_sources (uint32 requested_types) {
        ScreenCastSource[] sources = {};
        if ((requested_types & SCREENCAST_SOURCE_MONITOR) != 0)
            sources += new ScreenCastSource (
                SCREENCAST_SOURCE_MONITOR, "WL-1", "WL-1", "");
        if ((requested_types & SCREENCAST_SOURCE_WINDOW) != 0)
            sources += new ScreenCastSource (
                SCREENCAST_SOURCE_WINDOW, "window-1", "Editor", "test.app");
        return sources;
    }

    public ScreenCastCapture? create_capture (uint32 source_type,
                                              string source_id,
                                              bool paint_cursors) {
        bool valid_monitor = source_type == SCREENCAST_SOURCE_MONITOR &&
            source_id == "WL-1";
        bool valid_window = source_type == SCREENCAST_SOURCE_WINDOW &&
            source_id == "window-1";
        if (!valid_monitor && !valid_window)
            return null;
        last_source_type = source_type;
        last_source_id = source_id;
        last_paint_cursors = paint_cursors;
        var capture = new FakeCapture ();
        captures += capture;
        return capture;
    }
}

private class FakeChooser : Object, ScreenCastChooser {
    public async ScreenCastChooserResult choose (ScreenCastSource[] sources,
                                                 Cancellable cancellable) {
        Idle.add (choose.callback);
        yield;
        return cancellable.is_cancelled () || sources.length == 0
            ? new ScreenCastChooserResult (ScreenCastChooserStatus.CANCELLED)
            : new ScreenCastChooserResult (
                ScreenCastChooserStatus.SELECTED,
                new ScreenCastSelection (
                    sources[0].source_type, sources[0].source_id));
    }
}

private class PendingChooser : Object, ScreenCastChooser {
    public bool was_cancelled { get; private set; default = false; }

    public async ScreenCastChooserResult choose (
        ScreenCastSource[] sources, Cancellable cancellable) {
        ulong cancelled_id = cancellable.cancelled.connect (() => {
            was_cancelled = true;
            Idle.add (choose.callback);
        });
        if (!cancellable.is_cancelled ())
            yield;
        cancellable.disconnect (cancelled_id);
        return new ScreenCastChooserResult (ScreenCastChooserStatus.CANCELLED);
    }
}

private class PendingCapture : Object, ScreenCastCapture {
    public uint32 node_id { get { return 0xffffffffu; } }
    public bool failed { get { return false; } }
    public bool stopped { get; private set; default = false; }

    public void stop () {
        stopped = true;
    }
}

private class PendingCaptureManager : Object, ScreenCastCaptureManager {
    public PendingCapture? capture { get; private set; }
    public uint32 available_source_types {
        get { return SCREENCAST_SOURCE_MONITOR; }
    }

    public ScreenCastSource[] list_sources (uint32 requested_types) {
        return (requested_types & SCREENCAST_SOURCE_MONITOR) != 0
            ? new ScreenCastSource[] {
                new ScreenCastSource (
                    SCREENCAST_SOURCE_MONITOR, "WL-1", "WL-1", "")
            }
            : new ScreenCastSource[0];
    }

    public ScreenCastCapture? create_capture (uint32 source_type,
                                              string source_id,
                                              bool paint_cursors) {
        capture = new PendingCapture ();
        return capture;
    }
}

private class EmptyCaptureManager : Object, ScreenCastCaptureManager {
    public uint32 available_source_types {
        get { return SCREENCAST_SOURCE_MONITOR; }
    }

    public ScreenCastSource[] list_sources (uint32 requested_types) {
        return new ScreenCastSource[0];
    }

    public ScreenCastCapture? create_capture (uint32 source_type,
                                              string source_id,
                                              bool paint_cursors) {
        return null;
    }
}

private class CountingChooser : Object, ScreenCastChooser {
    public uint calls { get; private set; default = 0u; }

    public async ScreenCastChooserResult choose (
        ScreenCastSource[] sources, Cancellable cancellable) {
        calls++;
        return new ScreenCastChooserResult (ScreenCastChooserStatus.CANCELLED);
    }
}

private class FailedChooser : Object, ScreenCastChooser {
    public async ScreenCastChooserResult choose (
        ScreenCastSource[] sources, Cancellable cancellable) {
        return new ScreenCastChooserResult (ScreenCastChooserStatus.FAILED);
    }
}

private void test_versions_match_returned_stream_properties () {
    var portal = new ScreenCastPortal ();
    var session = new ScreenCastSession (portal,
        "/org/freedesktop/portal/desktop/session/test/one");

    assert (portal.version == 3u);
    assert (session.version == 1u);
}

private void test_create_session_has_no_nonstandard_results () {
    var portal = new ScreenCastPortal ();
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    var loop = new MainLoop ();

    portal.create_session.begin (
        new ObjectPath ("/org/freedesktop/portal/desktop/request/test/one"),
        new ObjectPath ("/org/freedesktop/portal/desktop/session/test/one"),
        "test.app",
        options,
        (obj, result) => {
            try {
                uint32 response;
                HashTable<string, Variant> results;
                portal.create_session.end (result, out response, out results);
                assert (response == 0u);
                assert (results.size () == 0u);
            } catch (Error caught) {
                critical ("CreateSession failed: %s", caught.message);
                assert_not_reached ();
            }
            loop.quit ();
        });

    loop.run ();
}

private async void create_and_start_session (ScreenCastPortal portal,
                                             string suffix) throws Error {
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    var request = new ObjectPath (
        "/org/freedesktop/portal/desktop/request/test/" + suffix);
    var session = new ObjectPath (
        "/org/freedesktop/portal/desktop/session/test/" + suffix);
    uint32 response;
    HashTable<string, Variant> results;

    yield portal.create_session (request, session, "test.app", options,
        out response, out results);
    assert (response == 0u);

    yield portal.select_sources (request, session, "test.app", options,
        out response, out results);
    assert (response == 0u);

    yield portal.start (request, session, "test.app", "", options,
        out response, out results);
    assert (response == 0u);
}

private void test_closing_one_session_does_not_stop_another () {
    var manager = new FakeCaptureManager ();
    var portal = new ScreenCastPortal.with_adapters (manager, new FakeChooser ());
    var loop = new MainLoop ();

    create_and_start_session.begin (portal, "a", (obj, first_result) => {
        try {
            create_and_start_session.end (first_result);
            create_and_start_session.begin (portal, "b", (obj2, second_result) => {
                try {
                    create_and_start_session.end (second_result);
                    assert (manager.captures.length == 2);

                    var session_a = new ScreenCastSession (portal,
                        "/org/freedesktop/portal/desktop/session/test/a");
                    session_a.close ();

                    assert (manager.captures[0].stopped);
                    assert (!manager.captures[1].stopped);
                } catch (Error caught) {
                    critical ("session isolation failed: %s", caught.message);
                    assert_not_reached ();
                }
                loop.quit ();
            });
        } catch (Error caught) {
            critical ("first session failed: %s", caught.message);
            assert_not_reached ();
        }
    });

    loop.run ();
}

private async void repeat_start_close (ScreenCastPortal portal,
                                       FakeCaptureManager manager)
                                       throws Error {
    for (uint index = 0; index < 100; index++) {
        string suffix = "repeat_%u".printf (index);
        yield create_and_start_session (portal, suffix);
        var session = new ScreenCastSession (portal,
            "/org/freedesktop/portal/desktop/session/test/" + suffix);
        session.close ();
        assert (manager.captures[index].stopped);
    }
}

private void test_repeated_start_close_has_no_stale_session_state () {
    var manager = new FakeCaptureManager ();
    var portal = new ScreenCastPortal.with_adapters (manager, new FakeChooser ());
    var loop = new MainLoop ();

    repeat_start_close.begin (portal, manager, (obj, result) => {
        try {
            repeat_start_close.end (result);
            assert (manager.captures.length == 100);
        } catch (Error caught) {
            critical ("repeated sessions failed: %s", caught.message);
            assert_not_reached ();
        }
        loop.quit ();
    });

    loop.run ();
}

private void test_request_close_cancels_pending_chooser_once () {
    var chooser = new PendingChooser ();
    var portal = new ScreenCastPortal.with_adapters (
        new FakeCaptureManager (), chooser);
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    var loop = new MainLoop ();
    var create_request = new ObjectPath (
        "/org/freedesktop/portal/desktop/request/test/create_cancel");
    var select_request_path =
        "/org/freedesktop/portal/desktop/request/test/select_cancel";
    var session = new ObjectPath (
        "/org/freedesktop/portal/desktop/session/test/cancel");
    uint completions = 0;

    portal.create_session.begin (create_request, session, "test.app", options,
        (obj, create_result) => {
            try {
                uint32 create_response;
                HashTable<string, Variant> create_results;
                portal.create_session.end (create_result,
                    out create_response, out create_results);
                assert (create_response == 0u);

                portal.select_sources.begin (
                    new ObjectPath (select_request_path), session,
                    "test.app", options, (obj2, select_result) => {
                        try {
                            uint32 select_response;
                            HashTable<string, Variant> select_results;
                            portal.select_sources.end (select_result,
                                out select_response, out select_results);
                            completions++;
                            assert (select_response == 1u);
                            assert (chooser.was_cancelled);
                            assert (completions == 1u);
                        } catch (Error caught) {
                            critical ("SelectSources failed: %s", caught.message);
                            assert_not_reached ();
                        }
                        loop.quit ();
                    });

                Idle.add (() => {
                    try {
                        var request = new ScreenCastRequest (
                            portal, select_request_path);
                        request.close ();
                    } catch (Error caught) {
                        critical ("Request.Close failed: %s", caught.message);
                        assert_not_reached ();
                    }
                    return Source.REMOVE;
                });
            } catch (Error caught) {
                critical ("CreateSession failed: %s", caught.message);
                assert_not_reached ();
            }
        });

    loop.run ();
}

private void test_window_selection_propagates_embedded_cursor () {
    var manager = new FakeCaptureManager ();
    var portal = new ScreenCastPortal.with_adapters (manager, new FakeChooser ());
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    options.insert ("types", new Variant.uint32 (SCREENCAST_SOURCE_WINDOW));
    options.insert ("cursor_mode",
        new Variant.uint32 (SCREENCAST_CURSOR_EMBEDDED));
    var loop = new MainLoop ();
    var request = new ObjectPath (
        "/org/freedesktop/portal/desktop/request/test/window");
    var session = new ObjectPath (
        "/org/freedesktop/portal/desktop/session/test/window");

    portal.create_session.begin (request, session, "test.app", options,
        (obj, create_result) => {
            try {
                uint32 response;
                HashTable<string, Variant> results;
                portal.create_session.end (create_result,
                    out response, out results);
                assert (response == 0u);
                portal.select_sources.begin (
                    request, session, "test.app", options,
                    (obj2, select_result) => {
                        try {
                            portal.select_sources.end (select_result,
                                out response, out results);
                            assert (response == 0u);
                            portal.start.begin (
                                request, session, "test.app", "", options,
                                (obj3, start_result) => {
                                    try {
                                        portal.start.end (start_result,
                                            out response, out results);
                                        assert (response == 0u);
                                        assert (manager.last_source_type ==
                                            SCREENCAST_SOURCE_WINDOW);
                                        assert (manager.last_source_id ==
                                            "window-1");
                                        assert (manager.last_paint_cursors);
                                    } catch (Error caught) {
                                        critical ("Start failed: %s",
                                            caught.message);
                                        assert_not_reached ();
                                    }
                                    loop.quit ();
                                });
                        } catch (Error caught) {
                            critical ("SelectSources failed: %s",
                                caught.message);
                            assert_not_reached ();
                        }
                    });
            } catch (Error caught) {
                critical ("CreateSession failed: %s", caught.message);
                assert_not_reached ();
            }
        });

    loop.run ();
}

private void test_request_close_cancels_pending_start_once () {
    var manager = new PendingCaptureManager ();
    var portal = new ScreenCastPortal.with_adapters (manager, new FakeChooser ());
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    var loop = new MainLoop ();
    var create_request = new ObjectPath (
        "/org/freedesktop/portal/desktop/request/test/create_start_cancel");
    string start_request_path =
        "/org/freedesktop/portal/desktop/request/test/start_cancel";
    var session = new ObjectPath (
        "/org/freedesktop/portal/desktop/session/test/start_cancel");
    uint completions = 0;

    portal.create_session.begin (create_request, session, "test.app", options,
        (obj, create_result) => {
            try {
                uint32 response;
                HashTable<string, Variant> results;
                portal.create_session.end (create_result,
                    out response, out results);
                assert (response == 0u);
                portal.select_sources.begin (
                    create_request, session, "test.app", options,
                    (obj2, select_result) => {
                        try {
                            portal.select_sources.end (select_result,
                                out response, out results);
                            assert (response == 0u);
                            portal.start.begin (
                                new ObjectPath (start_request_path),
                                session, "test.app", "", options,
                                (obj3, start_result) => {
                                    try {
                                        portal.start.end (start_result,
                                            out response, out results);
                                        completions++;
                                        assert (response == 1u);
                                        assert (manager.capture != null);
                                        assert (manager.capture.stopped);
                                        assert (completions == 1u);
                                    } catch (Error caught) {
                                        critical ("Start failed: %s",
                                            caught.message);
                                        assert_not_reached ();
                                    }
                                    loop.quit ();
                                });
                            Idle.add (() => {
                                try {
                                    var request = new ScreenCastRequest (
                                        portal, start_request_path);
                                    request.close ();
                                } catch (Error caught) {
                                    critical ("Request.Close failed: %s",
                                        caught.message);
                                    assert_not_reached ();
                                }
                                return Source.REMOVE;
                            });
                        } catch (Error caught) {
                            critical ("SelectSources failed: %s",
                                caught.message);
                            assert_not_reached ();
                        }
                    });
            } catch (Error caught) {
                critical ("CreateSession failed: %s", caught.message);
                assert_not_reached ();
            }
        });

    loop.run ();
}

private void test_empty_source_inventory_is_backend_failure () {
    var chooser = new CountingChooser ();
    var portal = new ScreenCastPortal.with_adapters (
        new EmptyCaptureManager (), chooser);
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    var loop = new MainLoop ();
    var request = new ObjectPath (
        "/org/freedesktop/portal/desktop/request/test/empty");
    var session = new ObjectPath (
        "/org/freedesktop/portal/desktop/session/test/empty");

    portal.create_session.begin (request, session, "test.app", options,
        (obj, create_result) => {
            try {
                uint32 response;
                HashTable<string, Variant> results;
                portal.create_session.end (create_result,
                    out response, out results);
                assert (response == 0u);
                portal.select_sources.begin (
                    request, session, "test.app", options,
                    (obj2, select_result) => {
                        try {
                            portal.select_sources.end (select_result,
                                out response, out results);
                            assert (response == 2u);
                            assert (chooser.calls == 0u);
                        } catch (Error caught) {
                            critical ("SelectSources failed: %s",
                                caught.message);
                            assert_not_reached ();
                        }
                        loop.quit ();
                    });
            } catch (Error caught) {
                critical ("CreateSession failed: %s", caught.message);
                assert_not_reached ();
            }
        });

    loop.run ();
}

private void test_chooser_failure_is_not_reported_as_user_cancel () {
    var portal = new ScreenCastPortal.with_adapters (
        new FakeCaptureManager (), new FailedChooser ());
    var options = new HashTable<string, Variant> (str_hash, str_equal);
    var loop = new MainLoop ();
    var request = new ObjectPath (
        "/org/freedesktop/portal/desktop/request/test/chooser_failure");
    var session = new ObjectPath (
        "/org/freedesktop/portal/desktop/session/test/chooser_failure");

    portal.create_session.begin (request, session, "test.app", options,
        (obj, create_result) => {
            try {
                uint32 response;
                HashTable<string, Variant> results;
                portal.create_session.end (create_result,
                    out response, out results);
                assert (response == 0u);
                portal.select_sources.begin (
                    request, session, "test.app", options,
                    (obj2, select_result) => {
                        try {
                            portal.select_sources.end (select_result,
                                out response, out results);
                            assert (response == 2u);
                        } catch (Error caught) {
                            critical ("SelectSources failed: %s",
                                caught.message);
                            assert_not_reached ();
                        }
                        loop.quit ();
                    });
            } catch (Error caught) {
                critical ("CreateSession failed: %s", caught.message);
                assert_not_reached ();
            }
        });

    loop.run ();
}

private void test_source_json_round_trip_preserves_text () {
    ScreenCastSource[] sources = {
        new ScreenCastSource (1u, "monitor-\"one\"", "Main\nDisplay — λ", ""),
        new ScreenCastSource (2u, "window/二", "Editor \"draft\"", "org.example.编辑器"),
    };

    string encoded = ScreenCastJson.encode_sources (sources);
    ScreenCastSource[] decoded = ScreenCastJson.decode_sources (encoded);

    assert (decoded.length == 2);
    assert (decoded[0].source_type == 1u);
    assert (decoded[0].source_id == "monitor-\"one\"");
    assert (decoded[0].label == "Main\nDisplay — λ");
    assert (decoded[1].source_type == 2u);
    assert (decoded[1].source_id == "window/二");
    assert (decoded[1].label == "Editor \"draft\"");
    assert (decoded[1].app_id == "org.example.编辑器");
}

private void test_selection_json_round_trip_is_typed () {
    var selection = new ScreenCastSelection (2u, "window/二");
    string encoded = ScreenCastJson.encode_selection (selection);
    ScreenCastSelection? decoded = ScreenCastJson.decode_selection (encoded);

    assert (decoded != null);
    assert (decoded.source_type == 2u);
    assert (decoded.source_id == "window/二");
    assert (ScreenCastJson.decode_selection ("{\"version\":9}") == null);
}

private void test_malformed_json_member_types_are_rejected () {
    assert (ScreenCastJson.decode_sources (
        "{\"version\":1,\"sources\":\"not-an-array\"}").length == 0);
    assert (ScreenCastJson.decode_sources (
        "{\"version\":1,\"sources\":[7]}").length == 0);
    assert (ScreenCastJson.decode_selection (
        "{\"version\":1,\"type\":\"window\",\"id\":7}") == null);
}

public static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/screencast/contract/versions",
        test_versions_match_returned_stream_properties);
    Test.add_func ("/screencast/contract/create-session-results",
        test_create_session_has_no_nonstandard_results);
    Test.add_func ("/screencast/lifecycle/session-isolation",
        test_closing_one_session_does_not_stop_another);
    Test.add_func ("/screencast/lifecycle/repeated-start-close",
        test_repeated_start_close_has_no_stale_session_state);
    Test.add_func ("/screencast/lifecycle/request-close",
        test_request_close_cancels_pending_chooser_once);
    Test.add_func ("/screencast/lifecycle/request-close-pending-start",
        test_request_close_cancels_pending_start_once);
    Test.add_func ("/screencast/options/window-embedded-cursor",
        test_window_selection_propagates_embedded_cursor);
    Test.add_func ("/screencast/options/empty-source-inventory",
        test_empty_source_inventory_is_backend_failure);
    Test.add_func ("/screencast/options/chooser-failure",
        test_chooser_failure_is_not_reported_as_user_cancel);
    Test.add_func ("/screencast/codec/sources",
        test_source_json_round_trip_preserves_text);
    Test.add_func ("/screencast/codec/selection",
        test_selection_json_round_trip_is_typed);
    Test.add_func ("/screencast/codec/malformed-member-types",
        test_malformed_json_member_types_are_rejected);
    return Test.run ();
}
