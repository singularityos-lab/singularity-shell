namespace Singularity {

    public class ProcessTerminator : GLib.Object {
        private const uint POLL_MS = 100;

        public uint grace_ms { get; construct; }
        public string proc_root { get; construct; }
        public string cgroup_root { get; construct; }

        private GLib.HashTable<int, uint64?> targets =
            new GLib.HashTable<int, uint64?>(GLib.direct_hash, GLib.direct_equal);

        public ProcessTerminator(uint grace_ms = 3000, string proc_root = "/proc",
                string cgroup_root = "/sys/fs/cgroup") {
            Object(grace_ms: grace_ms, proc_root: proc_root, cgroup_root: cgroup_root);
        }

        public int[] list_pids() {
            int[] list = {};
            foreach (int p in targets.get_keys()) list += p;
            return list;
        }

        public uint64 start_time(int pid) {
            string stat;
            try {
                if (!GLib.FileUtils.get_contents("%s/%d/stat".printf(proc_root, pid), out stat)) return 0;
            } catch (GLib.Error e) {
                return 0;
            }
            int close = stat.last_index_of_char(')');
            if (close < 0) return 0;
            string[] fields = stat.substring(close + 2).split(" ");
            if (fields.length < 20) return 0;
            return uint64.parse(fields[19]);
        }

        private int parent_of(int pid) {
            string stat;
            try {
                if (!GLib.FileUtils.get_contents("%s/%d/stat".printf(proc_root, pid), out stat)) return 0;
            } catch (GLib.Error e) {
                return 0;
            }
            int close = stat.last_index_of_char(')');
            if (close < 0) return 0;
            string[] fields = stat.substring(close + 2).split(" ");
            return fields.length > 1 ? int.parse(fields[1]) : 0;
        }

        private bool is_ancestor_of_self(int pid) {
            int current = Posix.getpid();
            for (int depth = 0; depth < 64 && current > 1; depth++) {
                if (current == pid) return true;
                current = parent_of(current);
            }
            return false;
        }

        public bool may_signal(int pid) {
            if (pid <= 1 || is_ancestor_of_self(pid)) return false;
            Posix.Stat st;
            if (Posix.stat("%s/%d".printf(proc_root, pid), out st) != 0) return false;
            return st.st_uid == Posix.getuid() && start_time(pid) != 0;
        }

        public string? cgroup_of(int pid) {
            string contents;
            try {
                if (!GLib.FileUtils.get_contents("%s/%d/cgroup".printf(proc_root, pid), out contents)) return null;
            } catch (GLib.Error e) {
                return null;
            }
            foreach (string line in contents.split("\n")) {
                if (line.has_prefix("0::")) return line.substring(3).strip();
            }
            return null;
        }

        public string? app_scope_of(int pid) {
            string? path = cgroup_of(pid);
            if (path == null || path == "" || path == "/") return null;
            string leaf = GLib.Path.get_basename(path);
            if (!leaf.has_prefix("app-") || !leaf.has_suffix(".scope")) return null;
            if (path == cgroup_of(Posix.getpid())) return null;
            return path;
        }

        public int[] scope_members(string scope) {
            int[] members = {};
            string contents;
            try {
                if (!GLib.FileUtils.get_contents(cgroup_root + scope + "/cgroup.procs", out contents)) return members;
            } catch (GLib.Error e) {
                return members;
            }
            foreach (string line in contents.split("\n")) {
                int p = int.parse(line.strip());
                if (p > 0) members += p;
            }
            return members;
        }

        public bool add(int pid, bool include_scope = true) {
            if (!may_signal(pid)) return false;
            targets.insert(pid, start_time(pid));
            if (!include_scope) return true;
            string? scope = app_scope_of(pid);
            if (scope == null) return true;
            foreach (int member in scope_members(scope)) {
                if (!targets.contains(member) && may_signal(member))
                    targets.insert(member, start_time(member));
            }
            return true;
        }

        private bool same_process(int pid) {
            uint64? recorded = targets.lookup(pid);
            return recorded != null && recorded != 0 && start_time(pid) == recorded;
        }

        private int signal_all(int sig) {
            int sent = 0;
            foreach (int p in list_pids()) {
                if (!same_process(p) || is_zombie(p)) {
                    targets.remove(p);
                    continue;
                }
                if (Posix.kill((Posix.pid_t) p, sig) == 0) sent++;
            }
            return sent;
        }

        private bool any_alive() {
            foreach (int p in list_pids()) {
                if (same_process(p) && !is_zombie(p)) return true;
            }
            return false;
        }

        private bool is_zombie(int pid) {
            string stat;
            try {
                if (!GLib.FileUtils.get_contents("%s/%d/stat".printf(proc_root, pid), out stat)) return true;
            } catch (GLib.Error e) {
                return true;
            }
            int close = stat.last_index_of_char(')');
            return close < 0 || stat.get_char(close + 2) == 'Z';
        }

        public async int terminate() {
            if (targets.size() == 0) return 0;
            signal_all(Posix.Signal.TERM);
            uint waited = 0;
            while (waited < grace_ms && any_alive()) {
                GLib.Timeout.add(POLL_MS, terminate.callback);
                yield;
                waited += POLL_MS;
            }
            if (!any_alive()) return 0;
            return signal_all(Posix.Signal.KILL);
        }
    }
}
