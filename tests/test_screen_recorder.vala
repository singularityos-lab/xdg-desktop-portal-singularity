using GLib;
using Singularity.Portal;

private class RecorderCapture : Object, ScreenCastCapture {
    public uint32 node_id { get { return ready ? 57u : 0xffffffffu; } }
    public bool failed { get { return broken; } }
    public bool ready { get; set; default = true; }
    public bool broken { get; set; default = false; }
    public bool stopped { get; private set; default = false; }

    public void stop () {
        stopped = true;
    }
}

private class RecorderCaptureManager : Object, ScreenCastCaptureManager {
    public RecorderCapture[] captures = {};
    public bool never_ready = false;
    public bool paint_cursors = false;
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
        if (source_id != "WL-1" && source_id != "window-1")
            return null;
        this.paint_cursors = paint_cursors;
        var capture = new RecorderCapture ();
        capture.ready = !never_ready;
        captures += capture;
        return capture;
    }
}

private void run_start (ScreenRecorderService service,
                        uint32 source_type,
                        string source_id,
                        string sender,
                        out uint32 handle,
                        out uint32 node_id,
                        out Error? error) {
    var loop = new MainLoop ();
    uint32 result_handle = 0;
    uint32 result_node = 0;
    Error? result_error = null;
    service.start_capture.begin (source_type, source_id, true,
        new BusName (sender), (obj, res) => {
        try {
            service.start_capture.end (res, out result_handle, out result_node);
        } catch (Error caught) {
            result_error = caught;
        }
        loop.quit ();
    });
    loop.run ();
    handle = result_handle;
    node_id = result_node;
    error = result_error;
}

private void test_start_returns_node_and_stop_releases () {
    var manager = new RecorderCaptureManager ();
    var service = new ScreenRecorderService (manager);
    uint32 handle, node_id;
    Error? error;
    run_start (service, SCREENCAST_SOURCE_MONITOR, "WL-1", ":1.5",
        out handle, out node_id, out error);
    assert (error == null);
    assert (handle != 0);
    assert (node_id == 57u);
    assert (manager.paint_cursors);
    assert (service.active_captures == 1);

    bool denied = false;
    try {
        service.stop_capture (handle, new BusName (":1.9"));
    } catch (Error caught) {
        denied = true;
    }
    assert (denied);
    assert (!manager.captures[0].stopped);

    try {
        service.stop_capture (handle, new BusName (":1.5"));
    } catch (Error caught) {
        assert_not_reached ();
    }
    assert (manager.captures[0].stopped);
    assert (service.active_captures == 0);
}

private void test_unknown_source_is_an_error () {
    var service = new ScreenRecorderService (new RecorderCaptureManager ());
    uint32 handle, node_id;
    Error? error;
    run_start (service, SCREENCAST_SOURCE_MONITOR, "HDMI-9", ":1.5",
        out handle, out node_id, out error);
    assert (error != null);
    assert (service.active_captures == 0);
}

private void test_capture_without_frames_times_out () {
    var manager = new RecorderCaptureManager ();
    manager.never_ready = true;
    var service = new ScreenRecorderService (manager);
    uint32 handle, node_id;
    Error? error;
    run_start (service, SCREENCAST_SOURCE_WINDOW, "window-1", ":1.5",
        out handle, out node_id, out error);
    assert (error != null);
    assert (manager.captures[0].stopped);
    assert (service.active_captures == 0);
}

private void test_owner_exit_releases_its_captures () {
    var manager = new RecorderCaptureManager ();
    var service = new ScreenRecorderService (manager);
    uint32 handle, node_id;
    Error? error;
    run_start (service, SCREENCAST_SOURCE_MONITOR, "WL-1", ":1.5",
        out handle, out node_id, out error);
    run_start (service, SCREENCAST_SOURCE_WINDOW, "window-1", ":1.6",
        out handle, out node_id, out error);
    service.release_owner (":1.5");
    assert (manager.captures[0].stopped);
    assert (!manager.captures[1].stopped);
    assert (service.active_captures == 1);
}

private void test_list_windows_encodes_window_sources () {
    var service = new ScreenRecorderService (new RecorderCaptureManager ());
    string json = "";
    try {
        json = service.list_windows (new BusName (":1.5"));
    } catch (Error caught) {
        assert_not_reached ();
    }
    var sources = ScreenCastJson.decode_sources (json);
    assert (sources.length == 1);
    assert (sources[0].source_id == "window-1");
    assert (sources[0].label == "Editor");
    assert (sources[0].app_id == "test.app");
}

public static int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/screen-recorder/start-stop",
        test_start_returns_node_and_stop_releases);
    Test.add_func ("/screen-recorder/unknown-source",
        test_unknown_source_is_an_error);
    Test.add_func ("/screen-recorder/no-frames",
        test_capture_without_frames_times_out);
    Test.add_func ("/screen-recorder/owner-exit",
        test_owner_exit_releases_its_captures);
    Test.add_func ("/screen-recorder/list-windows",
        test_list_windows_encodes_window_sources);
    return Test.run ();
}
