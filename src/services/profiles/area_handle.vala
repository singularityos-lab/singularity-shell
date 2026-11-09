using GLib;
using Singularity.Profiles;

namespace Singularity.ProfilesService {

    public class AreaHandle : Object {
        public string id { get; private set; }
        public AreaInfo info { get; set; }
        public string owner { get; private set; default = ""; }
        public bool system_bus { get; private set; default = false; }
        public int rank { get; private set; default = 0; }

        private AreaProxy? _proxy = null;
        private Area? _local = null;

        public signal void changed(string[] keys);

        public AreaHandle.remote(string id, AreaProxy proxy, string owner, bool system_bus, int rank) {
            this.id = id;
            this.owner = owner;
            this.system_bus = system_bus;
            this.rank = rank;
            _proxy = proxy;
            info = new AreaInfo(id, id, "");
            _proxy.changed.connect((keys) => changed(keys));
        }

        public AreaHandle.local(Area area) {
            id = area.info.id;
            _local = area;
            info = area.info;
            rank = 1;
            _local.changed.connect((keys) => changed(keys));
        }

        public async bool refresh() {
            if (_local != null) return true;
            try {
                var parsed = AreaInfo.from_data(yield _proxy.describe());
                if (parsed == null) return false;
                info = parsed;
                return true;
            } catch (Error e) {
                warning("profiles: area %s does not describe itself: %s", id, e.message);
                return false;
            }
        }

        public async HashTable<string, string> snapshot(string[] keys) {
            try {
                if (_local != null) return _local.snapshot(keys);
                return yield _proxy.snapshot(keys);
            } catch (Error e) {
                warning("profiles: snapshot of %s failed: %s", id, e.message);
                return new HashTable<string, string>(str_hash, str_equal);
            }
        }

        public async bool apply(HashTable<string, string> values) {
            if (values.size() == 0) return true;
            try {
                if (_local != null) _local.apply(values);
                else yield _proxy.apply(values);
                return true;
            } catch (Error e) {
                warning("profiles: apply on %s failed: %s", id, e.message);
                return false;
            }
        }

        public static async AreaHandle? connect_remote(string id, BusType bus, string name, string path, string owner, int rank) {
            try {
                var proxy = yield Bus.get_proxy<AreaProxy>(bus, name, path, DBusProxyFlags.DO_NOT_AUTO_START);
                var handle = new AreaHandle.remote(id, proxy, owner, bus == BusType.SYSTEM, rank);
                if (!(yield handle.refresh())) return null;
                return handle;
            } catch (Error e) {
                debug("profiles: no area %s at %s: %s", id, name, e.message);
                return null;
            }
        }
    }
}
