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
        private UshPortal ush_portal;
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
                "io.github.mirkobrombin.ush.Portal",
                BusNameOwnerFlags.NONE,
                (conn) => {
                    // Register the ush portal object on the main portal connection,
                    // the same one used by all other portals. This ensures the
                    // D-Bus method calls arrive on the same connection that owns
                    // the GDK/Wayland display.
                    try {
                        ush_portal = new UshPortal();
                        _conn.register_object("/io/github/mirkobrombin/ush/Portal", ush_portal);
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
                access_portal = new AccessPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", access_portal);
                account_portal = new AccountPortal(_conn);
                _conn.register_object("/org/freedesktop/portal/desktop", account_portal);
                email_portal = new EmailPortal();
                _conn.register_object("/org/freedesktop/portal/desktop", email_portal);
                lockdown_portal = new LockdownPortal();
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

                // OpenPipeWireRemote needs manual fd passing via D-Bus filter
                _conn.add_filter((connection, message, incoming) => {
                    if (!incoming) return message;
                    if (message.get_interface() == "org.freedesktop.impl.portal.ScreenCast" &&
                        message.get_member() == "OpenPipeWireRemote") {
                        Variant body = message.get_body();
                        string session_handle = "";
                        body.get("(oa{sv})", &session_handle, null);
                        try {
                            int raw_fd = screencast_portal.open_pipewire_remote_fd(
                                new ObjectPath(session_handle));
                            var fd_list = new GLib.UnixFDList();
                            int idx = fd_list.append(raw_fd);
                            Posix.close(raw_fd);
                            var reply = new GLib.DBusMessage.method_reply(message);
                            reply.set_unix_fd_list(fd_list);
                            reply.set_body(new Variant("(h)", idx));
                            try { connection.send_message(reply, GLib.DBusSendMessageFlags.NONE, null); } catch (Error send_err) {
                                warning("PortalApplication: failed to send OpenPipeWireRemote reply: %s", send_err.message);
                            }
                        } catch (Error e) {
                            var err_reply = new GLib.DBusMessage.method_error_literal(
                                message, "org.freedesktop.DBus.Error.Failed", e.message);
                            try { connection.send_message(err_reply, GLib.DBusSendMessageFlags.NONE, null); } catch (Error send_err) {
                                warning("PortalApplication: failed to send OpenPipeWireRemote error: %s", send_err.message);
                            }
                        }
                        return null;
                    }
                    return message;
                });
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