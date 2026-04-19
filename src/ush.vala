using GLib;

namespace Singularity.Portal {

    /**
     * Implements io.github.mirkobrombin.ush.Portal1.
     *
     * Delegates permission dialogs to the Singularity desktop shell
     * (dev.sinty.desktop) which owns the GDK/Wayland display and can
     * create layer-shell windows without crashing.
     *
     * Also exposes AllowApp/DenyApp/IsAppTrusted methods mirroring
     * the Broker D-Bus interface so the shell can directly trust apps.
     */
    [DBus (name = "io.github.mirkobrombin.ush.Portal1")]
    public class UshPortal : Object {

        public async void show_permission(string category, string resource, string reason, out string decision) throws Error {
            try {
                var shell = Bus.get_proxy_sync<Singularity.Shell.ShellService>(
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                decision = shell.show_permission(category, resource, reason);
            } catch (Error e) {
                warning("ush portal: failed to call desktop shell: %s", e.message);
                decision = "deny";
            }
        }

        /**
         * Grant blanket permission for an app (all categories).
         * Delegates to the USH broker D-Bus interface.
         */
        public void allow_app(string app_name) throws Error {
            try {
                var broker = Bus.get_proxy_sync<Singularity.Portal.Broker1>(
                    BusType.SESSION, "io.github.mirkobrombin.ush.Broker",
                    "/io/github/mirkobrombin/ush/Broker");
                broker.allow_app(app_name);
            } catch (Error e) {
                warning("ush portal: allow_app failed: %s", e.message);
                throw e;
            }
        }

        /**
         * Revoke blanket permission for an app.
         */
        public void deny_app(string app_name) throws Error {
            try {
                var broker = Bus.get_proxy_sync<Singularity.Portal.Broker1>(
                    BusType.SESSION, "io.github.mirkobrombin.ush.Broker",
                    "/io/github/mirkobrombin/ush/Broker");
                broker.deny_app(app_name);
            } catch (Error e) {
                warning("ush portal: deny_app failed: %s", e.message);
                throw e;
            }
        }

        /**
         * Check if an app has blanket permission.
         */
        public bool is_app_trusted(string app_name) throws DBusError, IOError {
            try {
                var broker = Bus.get_proxy_sync<Singularity.Portal.Broker1>(
                    BusType.SESSION, "io.github.mirkobrombin.ush.Broker",
                    "/io/github/mirkobrombin/ush/Broker");
                return broker.is_app_trusted(app_name);
            } catch (Error e) {
                warning("ush portal: is_app_trusted failed: %s", e.message);
                return false;
            }
        }
    }

    /**
     * D-Bus proxy for the USH Broker interface.
     */
    [DBus (name = "io.github.mirkobrombin.ush.Broker1")]
    public interface Broker1 : Object {
        public abstract void allow_app(string app_name) throws IOError;
        public abstract void deny_app(string app_name) throws IOError;
        public abstract bool is_app_trusted(string app_name) throws IOError;
    }
}