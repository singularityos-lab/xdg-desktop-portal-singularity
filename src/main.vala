using GLib;
using Singularity.Portal;

namespace Singularity.Portal {

    /**
     * xdg-desktop-portal backend for Singularity Desktop.
     *
     * Registers all portal interfaces on the session bus under
     * ``org.freedesktop.impl.portal.desktop.singularity`` and owns that
     * name so the xdg-desktop-portal frontend discovers us automatically.
     *
     * Uses a raw main loop instead of GLib.Application so the daemon
     * stays alive as long as it owns the bus name. GTK windows are
     * created on-demand when D-Bus methods are called, by which time
     * the compositor is running and the display is open.
     */
    public class PortalApplication : Object {
        private SettingsPortal settings_portal;
        private ScreenshotPortal screenshot_portal;
        private FileChooserPortal file_chooser_portal;
        private NotificationPortal notification_portal;
        private InhibitPortal inhibit_portal;
        private AccessPortal access_portal;
        private AccountPortal account_portal;
        private EmailPortal email_portal;
        private LockdownPortal lockdown_portal;
        private WallpaperPortal wallpaper_portal;
        private AppChooserPortal app_chooser_portal;
        private OpenURIPortal open_uri_portal;
        private PrintPortal print_portal;
        private DynamicLauncherPortal dynamic_launcher_portal;
        private ScreenCastPortal screencast_portal;
        private ScreenRecorderService screen_recorder;
        private UshPortal ush_portal;
        private BackgroundPortal background_portal;
        private GlobalShortcutsPortal global_shortcuts_portal;
        private GlobalShortcutsBridge global_shortcuts_bridge;
        private UsbPortal usb_portal;
        private RemoteDesktopPortal remote_desktop_portal;
        private ClipboardPortal clipboard_portal;
        private RemoteSessionsMonitor remote_sessions;
        private DBusConnection _conn;
        private MainLoop _loop;
        private uint _bus_owner_id;
        private uint _ush_bus_owner_id;

        public void run() {
            _loop = new MainLoop(null, false);

            _bus_owner_id = Bus.own_name(BusType.SESSION,
                "org.freedesktop.impl.portal.desktop.singularity",
                BusNameOwnerFlags.NONE,
                (conn) => {
                    _conn = conn;
                    _register_portals();
                },
                (conn, name) => {
                    message("PortalApplication: acquired bus name %s", name);
                },
                (conn, name) => {
                    warning("PortalApplication: lost bus name %s", name);
                    _loop.quit();
                });

            _ush_bus_owner_id = Bus.own_name(BusType.SESSION,
                "dev.sinty.ush.Portal",
                BusNameOwnerFlags.NONE,
                (conn) => {
                    // Register on the connection that owns this name. It may be
                    // acquired before the main portal name initializes _conn.
                    try {
                        ush_portal = new UshPortal();
                        conn.register_object("/dev/sinty/ush/Portal", ush_portal);
                        message("PortalApplication: ush portal registered.");
                    } catch (GLib.Error e) {
                        warning("PortalApplication: failed to register ush portal: %s", e.message);
                    }
                },
                (conn, name) => {
                    message("PortalApplication: acquired ush bus name %s", name);
                },
                (conn, name) => {
                    warning("PortalApplication: lost ush bus name %s", name);
                });

            _loop.run();
            Bus.unown_name(_bus_owner_id);
            Bus.unown_name(_ush_bus_owner_id);
        }

        private void _register_portals() {
            try {
                settings_portal = new SettingsPortal();
                settings_portal.register_on(_conn);
                screenshot_portal = new ScreenshotPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", screenshot_portal);
                file_chooser_portal = new FileChooserPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", file_chooser_portal);
                notification_portal = new NotificationPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", notification_portal);
                inhibit_portal = new InhibitPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", inhibit_portal);
                access_portal = new AccessPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", access_portal);
                account_portal = new AccountPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", account_portal);
                email_portal = new EmailPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", email_portal);
                lockdown_portal = new LockdownPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", lockdown_portal);
                wallpaper_portal = new WallpaperPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", wallpaper_portal);
                app_chooser_portal = new AppChooserPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", app_chooser_portal);
                open_uri_portal = new OpenURIPortal(app_chooser_portal);
                _conn.register_object("/org/freedesktop/portal/desktop", open_uri_portal);
                print_portal = new PrintPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", print_portal);
                dynamic_launcher_portal = new DynamicLauncherPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", dynamic_launcher_portal);
                screencast_portal = new ScreenCastPortal();
                screencast_portal.register_on(_conn);
                // The generic xdg-desktop-portal frontend owns the public
                // OpenPipeWireRemote method and scopes its PipeWire remote to
                // the stream node IDs returned by this implementation.
                _conn.register_object("/org/freedesktop/portal/desktop", screencast_portal);
                screen_recorder = new ScreenRecorderService(screencast_portal.capture_manager, _conn);
                _conn.register_object(SCREEN_RECORDER_OBJECT_PATH, screen_recorder);
                background_portal = new BackgroundPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", background_portal);
                global_shortcuts_portal = new GlobalShortcutsPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", global_shortcuts_portal);
                global_shortcuts_bridge = new GlobalShortcutsBridge(global_shortcuts_portal);
                _conn.register_object("/org/freedesktop/portal/desktop", global_shortcuts_bridge);
                usb_portal = new UsbPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", usb_portal);
                remote_desktop_portal = new RemoteDesktopPortal(_conn, screencast_portal);
                _conn.register_object("/org/freedesktop/portal/desktop", remote_desktop_portal);
                clipboard_portal = new ClipboardPortal(remote_desktop_portal);
                _conn.register_object("/org/freedesktop/portal/desktop", clipboard_portal);
                remote_sessions = new RemoteSessionsMonitor(remote_desktop_portal);
                remote_desktop_portal.sessions_changed.connect(() => remote_sessions.changed());
                _conn.register_object("/dev/sinty/portal/RemoteSessions", remote_sessions);
                message("PortalApplication: all portals registered.");
            } catch (GLib.Error e) {
                warning("PortalApplication: failed to register portals: %s", e.message);
            }
        }
    }

    public static int main(string[] args) {
        var app = new PortalApplication();
        app.run();
        return 0;
    }
}
