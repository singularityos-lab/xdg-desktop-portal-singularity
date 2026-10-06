[CCode (cname = "ToplevelMonitor", free_function = "toplevel_monitor_free", cheader_filename = "toplevel_monitor.h")]
[Compact]
public class ToplevelMonitor {
    [CCode (cname = "ToplevelMonitorChanged")]
    public delegate void Changed();
    [CCode (cname = "toplevel_monitor_new")]
    public ToplevelMonitor(Changed changed);
    [CCode (cname = "toplevel_monitor_connect")]
    public bool connect();
    [CCode (cname = "toplevel_monitor_is_connected")]
    public bool is_connected();
    [CCode (cname = "toplevel_monitor_list_app_ids", array_length = false, array_null_terminated = true)]
    public string[] list_app_ids();
}
