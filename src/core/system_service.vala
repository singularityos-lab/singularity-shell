namespace Singularity {

    public class SystemService : Object {
        public static string[] service_dirs = {
            "/usr/share/dbus-1/system-services",
            "/usr/local/share/dbus-1/system-services",
            "/opt/local/share/dbus-1/system-services",
        };

        public static bool activatable(string name) {
            foreach (string dir in service_dirs) {
                if (FileUtils.test(Path.build_filename(dir, name + ".service"), FileTest.IS_REGULAR)) return true;
            }
            return false;
        }

        public static async void call(string name, string path, string method, Variant? parameters,
                                      string missing) throws Error {
            if (!activatable(name)) throw new IOError.NOT_FOUND(missing);
            var bus = yield Bus.get(BusType.SYSTEM);
            try {
                yield bus.call(name, path, name, method, parameters, null,
                    DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION, -1, null);
            } catch (Error e) {
                string? remote = DBusError.get_remote_error(e);
                DBusError.strip_remote_error(e);
                if (remote == "org.freedesktop.DBus.Error.AccessDenied") {
                    throw new IOError.PERMISSION_DENIED(_("The change was not authorized"));
                }
                if (remote == "org.freedesktop.DBus.Error.ServiceUnknown") throw new IOError.NOT_FOUND(missing);
                throw new IOError.FAILED(e.message);
            }
        }
    }
}
