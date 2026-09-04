using GLib;

namespace Singularity {

    public class HandControlManager : Object {
        private static HandControlManager? instance;
        private GLib.Settings settings;
        private GLib.Subprocess? process;
        private uint generation;

        public signal void availability_changed();

        public static HandControlManager get_default() {
            if (instance == null) {
                instance = new HandControlManager();
            }
            return instance;
        }

        private HandControlManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["hand-control-enabled"].connect(sync);
            sync();
        }

        public bool available {
            get {
                string binary = resolve_binary();
                return GLib.Path.is_absolute(binary)
                    ? GLib.FileUtils.test(binary, GLib.FileTest.IS_EXECUTABLE)
                    : GLib.Environment.find_program_in_path(binary) != null;
            }
        }

        public void calibrate() {
            if (!SafeMode.get_default().allows(SafeFeature.HAND_CONTROL)) return;
            if (!available) return;
            launch_command({ resolve_binary(), "--calibrate" });
        }

        private string resolve_binary() {
            string? override_path = GLib.Environment.get_variable(
                "SINGULARITY_HAND_CONTROL");
            if (override_path != null && override_path != "") {
                return override_path;
            }
            return AppSystem.resolve_companion_bin("singularity-hand-control");
        }

        private void sync() {
            if (!SafeMode.get_default().allows(SafeFeature.HAND_CONTROL)) {
                if (process != null) process.force_exit();
                process = null;
                availability_changed();
                return;
            }
            if (settings.get_boolean("hand-control-enabled")) {
                start();
            } else {
                stop();
            }
            availability_changed();
        }

        private void start() {
            if (process != null || !available) return;
            try {
                uint current_generation = ++generation;
                int64 started_at = GLib.get_monotonic_time();
                process = new GLib.Subprocess.newv(
                    { resolve_binary() },
                    GLib.SubprocessFlags.STDOUT_SILENCE);
                var started = process;
                started.wait_async.begin(null, (obj, result) => {
                    try {
                        started.wait_async.end(result);
                    } catch (Error e) {
                        warning("Hand control process: %s", e.message);
                    }
                    if (current_generation != generation || process != started) {
                        return;
                    }
                    process = null;
                    bool failed = started.get_if_signaled() ||
                        (started.get_if_exited() &&
                         started.get_exit_status() != 0);
                    bool was_primary = GLib.get_monotonic_time() - started_at >
                        1000000;
                    if (SafeMode.get_default().allows(SafeFeature.HAND_CONTROL)
                        && settings.get_boolean("hand-control-enabled") &&
                        (failed || was_primary)) {
                        Timeout.add_seconds(1, () => {
                            start();
                            return Source.REMOVE;
                        });
                    }
                });
            } catch (Error e) {
                warning("Could not start hand control: %s", e.message);
                process = null;
            }
        }

        private void stop() {
            ++generation;
            if (!available) {
                if (process != null) process.force_exit();
                process = null;
                return;
            }
            launch_command({ resolve_binary(), "--quit" });
            process = null;
        }

        private void launch_command(string[] argv) {
            try {
                new GLib.Subprocess.newv(
                    argv,
                    GLib.SubprocessFlags.STDOUT_SILENCE |
                    GLib.SubprocessFlags.STDERR_SILENCE);
            } catch (Error e) {
                warning("Hand control command: %s", e.message);
            }
        }
    }
}
