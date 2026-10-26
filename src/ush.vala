using GLib;

namespace Singularity.Portal {

    /**
     * Implements dev.sinty.ush.Portal1.
     *
     * Delegates permission dialogs to the Singularity desktop shell
     * (dev.sinty.desktop) which owns the GDK/Wayland display and can
     * create layer-shell windows without crashing.
     *
     * Also exposes AllowApp/DenyApp/IsAppTrusted methods mirroring
     * the Broker D-Bus interface so the shell can directly trust apps.
     */
    [DBus (name = "dev.sinty.ush.Portal1")]
    public class UshPortal : Object {
        private const int PROMPT_TIMEOUT_MS = 300000;

        public async void show_permission(string category, string resource, string reason, out string decision) throws Error {
            try {
                var shell = yield Bus.get_proxy<Singularity.Shell.ShellService>(
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                ((DBusProxy) shell).set_default_timeout(PROMPT_TIMEOUT_MS);
                decision = yield shell.show_permission(category, resource, reason);
            } catch (Error e) {
                warning("ush portal: failed to call desktop shell: %s", e.message);
                decision = "deny";
            }
        }

        public async void show_confirm(string title, string body, out bool confirmed) throws Error {
            try {
                var shell = yield Bus.get_proxy<Singularity.Shell.ShellService>(
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                ((DBusProxy) shell).set_default_timeout(PROMPT_TIMEOUT_MS);
                confirmed = yield shell.show_confirm(title, body);
            } catch (Error e) {
                warning("ush portal: show_confirm failed: %s", e.message);
                confirmed = false;
            }
        }

        public async void show_choice(string title, string body, string allow_label, string block_label, out bool allowed) throws Error {
            try {
                var conn = yield Bus.get(BusType.SESSION);
                var reply = yield conn.call("dev.sinty.desktop", "/dev/sinty/Shell/Choice",
                    "dev.sinty.Shell.Choice", "ShowChoice",
                    new Variant("(ssss)", title, body, allow_label, block_label),
                    new VariantType("(b)"), DBusCallFlags.NONE, PROMPT_TIMEOUT_MS);
                reply.get("(b)", out allowed);
                return;
            } catch (Error e) {
                warning("ush portal: show_choice unavailable, using show_confirm: %s", e.message);
            }
            bool confirmed = false;
            yield show_confirm(title, body + "\n\n" + allow_label + ": Confirm", out confirmed);
            allowed = confirmed;
        }

        /**
         * Grant blanket permission for an app (all categories).
         * Delegates to the USH broker D-Bus interface.
         */
        public void allow_app(string app_name) throws Error {
            try {
                var broker = Bus.get_proxy_sync<Singularity.Portal.Broker1>(
                    BusType.SESSION, "dev.sinty.ush.Broker",
                    "/dev/sinty/ush/Broker");
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
                    BusType.SESSION, "dev.sinty.ush.Broker",
                    "/dev/sinty/ush/Broker");
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
                    BusType.SESSION, "dev.sinty.ush.Broker",
                    "/dev/sinty/ush/Broker");
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
    [DBus (name = "dev.sinty.ush.Broker1")]
    public interface Broker1 : Object {
        public abstract void allow_app(string app_name) throws IOError;
        public abstract void deny_app(string app_name) throws IOError;
        public abstract bool is_app_trusted(string app_name) throws IOError;
    }
}