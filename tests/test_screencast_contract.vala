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

    public string[] list_outputs () {
        return { "WL-1" };
    }

    public ScreenCastCapture? create_capture (string output_name) {
        if (output_name != "WL-1")
            return null;
        var capture = new FakeCapture ();
        captures += capture;
        return capture;
    }
}

private class FakeChooser : Object, ScreenCastChooser {
    public async string? choose (string[] outputs, Cancellable cancellable) {
        Idle.add (choose.callback);
        yield;
        return cancellable.is_cancelled () || outputs.length == 0
            ? null : outputs[0];
    }
}

private class PendingChooser : Object, ScreenCastChooser {
    public bool was_cancelled { get; private set; default = false; }

    public async string? choose (string[] outputs, Cancellable cancellable) {
        ulong cancelled_id = cancellable.cancelled.connect (() => {
            was_cancelled = true;
            Idle.add (choose.callback);
        });
        if (!cancellable.is_cancelled ())
            yield;
        cancellable.disconnect (cancelled_id);
        return null;
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

    public string[] list_outputs () {
        return { "WL-1" };
    }

    public ScreenCastCapture? create_capture (string output_name) {
        capture = new PendingCapture ();
        return capture;
    }
}

private void test_versions_match_returned_stream_properties () {
    var manager = new FakeCaptureManager ();
    var portal = new ScreenCastPortal.with_adapters (manager, new FakeChooser ());
    var session = new ScreenCastSession (portal,
        "/org/freedesktop/portal/desktop/session/test/one");

    assert (portal.version == 3u);
    assert (portal.AvailableSourceTypes == 1u);
    assert (portal.AvailableCursorModes == 1u);
    assert (session.version == 1u);
}

private void test_create_session_has_no_nonstandard_results () {
    var manager = new FakeCaptureManager ();
    var portal = new ScreenCastPortal.with_adapters (manager, new FakeChooser ());
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
    return Test.run ();
}
