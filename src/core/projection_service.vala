namespace Singularity {
    [DBus (name = "dev.sinty.Projection1")]
    public class ProjectionService : Object {
        private class Lease {
            public void* handle;
            public string sender;
            public string output;
            public uint watch;
        }

        private static ProjectionService? instance;
        private HashTable<string, Lease> leases = new HashTable<string, Lease>(str_hash, str_equal);

        public signal void output_removed(string output_name);

        [DBus (visible = false)]
        public static ProjectionService get_default() {
            if (instance == null) instance = new ProjectionService();
            return instance;
        }

        [DBus (visible = false)]
        public void export() {
            Bus.own_name(BusType.SESSION, "dev.sinty.Projection1", BusNameOwnerFlags.NONE,
                (conn) => {
                    try {
                        conn.register_object<ProjectionService>("/dev/sinty/Projection1", this);
                    } catch (IOError e) {
                        warning("projection: %s", e.message);
                    }
                }, () => {}, () => {});
        }

        public bool available {
            get { return ProjectionBridge.available(); }
        }

        public void create_output(string name, int width, int height, int refresh, string form_factor,
                BusName sender, out string output_name, out int out_width, out int out_height) throws DBusError, IOError {
            FormFactorKind kind;
            if (!FormFactorKind.try_parse(form_factor, out kind)) {
                throw new DBusError.INVALID_ARGS("unknown form factor %s", form_factor);
            }
            if (leases.contains(name)) throw new DBusError.LIMITS_EXCEEDED("projection %s exists", name);
            string? created;
            void* handle = ProjectionBridge.create(name, width, height, refresh, form_factor,
                out created, out out_width, out out_height);
            if (handle == null || created == null) throw new DBusError.FAILED("compositor refused projection %s", name);
            var lease = new Lease();
            lease.handle = handle;
            lease.sender = sender;
            lease.output = created;
            lease.watch = Bus.watch_name(BusType.SESSION, sender, BusNameWatcherFlags.NONE, null, () => drop(name));
            leases.insert(name, lease);
            output_name = created;
        }

        public void map_touch(string name, string device_name, BusName sender) throws DBusError, IOError {
            ProjectionBridge.map_touch(owned_lease(name, sender).handle, device_name);
        }

        public void set_mode(string name, int width, int height, int refresh, BusName sender) throws DBusError, IOError {
            if (!ProjectionBridge.set_mode(owned_lease(name, sender).handle, width, height, refresh)) {
                throw new DBusError.FAILED("mode %dx%d refused", width, height);
            }
        }

        public void release(string name, BusName sender) throws DBusError, IOError {
            owned_lease(name, sender);
            drop(name);
        }

        private Lease owned_lease(string name, string sender) throws DBusError {
            var lease = leases.lookup(name);
            if (lease == null || lease.sender != sender) throw new DBusError.ACCESS_DENIED("projection %s not owned by caller", name);
            return lease;
        }

        private void drop(string name) {
            var lease = leases.lookup(name);
            if (lease == null) return;
            leases.remove(name);
            Bus.unwatch_name(lease.watch);
            ProjectionBridge.destroy(lease.handle);
            output_removed(lease.output);
        }
    }
}
