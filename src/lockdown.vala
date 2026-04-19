using GLib;

namespace Singularity.Portal {

    /**
     * Implements org.freedesktop.impl.portal.Lockdown.
     *
     * All lockdowns are disabled by default. A future iteration should
     * read these from the Singularity desktop GSettings schema.
     */
    [DBus (name = "org.freedesktop.impl.portal.Lockdown")]
    public class LockdownPortal : Object {
        public bool disable_printing { get { return false; } }
        public bool disable_save_to_disk { get { return false; } }
        public bool disable_application_handlers { get { return false; } }
        public bool disable_location { get { return false; } }
        public bool disable_camera { get { return false; } }
        public bool disable_microphone { get { return false; } }
        public bool disable_sound_output { get { return false; } }
        public LockdownPortal() {}
    }
}