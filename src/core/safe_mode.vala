namespace Singularity {

    /** Optional startup features suppressed while recovering from a crash loop. */
    public enum SafeFeature {
        TILING,
        PLUGINS,
        CUSTOM_WIDGETS,
        HAND_CONTROL,
        SESSION_RESTORE,
        AUTOSTART
    }

    /**
     * Process-wide recovery policy.
     *
     * Safe mode deliberately leaves the normal GSettings backend in place so
     * Settings can repair persisted values.  Callers use allows() for runtime
     * activation rather than replacing or rewriting the configured value.
     */
    public class SafeMode : Object {
        private static SafeMode? instance;

        public bool active { get; private set; }
        public string marker_path { get; private set; }
        public string reason { get; private set; }

        public static SafeMode get_default() {
            if (instance == null) {
                string? marker = Environment.get_variable(
                    "SINGULARITY_SAFE_MODE_MARKER");
                if (marker == null || marker == "") {
                    marker = Path.build_filename(Environment.get_user_state_dir(),
                        "singularity", "safe-mode");
                }
                string? configured_reason = Environment.get_variable(
                    "SINGULARITY_SAFE_MODE_REASON");
                instance = new SafeMode(
                    Environment.get_variable("SINGULARITY_SAFE_MODE") == "1",
                    marker,
                    configured_reason ?? "Repeated startup failures");
            }
            return instance;
        }

        public SafeMode(bool active, string marker_path,
                        string reason = "Repeated startup failures") {
            this.active = active;
            this.marker_path = marker_path;
            this.reason = reason;
        }

        public bool allows(SafeFeature feature) {
            return !active;
        }

        /** Remove the persistent recovery marker before ending this session. */
        public bool clear_marker() {
            if (!FileUtils.test(marker_path, FileTest.EXISTS)) return true;
            if (FileUtils.unlink(marker_path) == 0) return true;
            warning("SafeMode: could not remove recovery marker %s", marker_path);
            return false;
        }
    }
}
