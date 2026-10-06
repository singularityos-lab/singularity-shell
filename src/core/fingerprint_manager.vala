namespace Singularity {

    [DBus (name = "net.reactivated.Fprint.Manager")]
    public interface FprintManager : Object {
        public abstract async ObjectPath get_default_device() throws Error;
    }

    [DBus (name = "net.reactivated.Fprint.Device")]
    public interface FprintDevice : Object {
        public abstract async string[] list_enrolled_fingers(string username) throws Error;
        public abstract async void claim(string username) throws Error;
        public abstract async void release() throws Error;
        public abstract async void enroll_start(string finger_name) throws Error;
        public abstract async void enroll_stop() throws Error;
        public abstract async void delete_enrolled_fingers2() throws Error;
        public signal void enroll_status(string result, bool done);
    }

    public class FingerprintManager : Object {
        private const string[] FINGERS = {
            "right-index-finger", "left-index-finger", "right-thumb", "left-thumb",
            "right-middle-finger", "left-middle-finger", "right-ring-finger", "left-ring-finger",
            "right-little-finger", "left-little-finger",
        };

        public signal void started(int stages);
        public signal void scanning();
        public signal void stage_passed(int stage, int stages);
        public signal void retry(string message);
        public signal void finished(bool success, string message);

        private FprintDevice? device = null;
        private string user = Environment.get_user_name();
        private int stage = 0;
        private int stages = 0;
        private bool busy = false;
        private bool claimed = false;
        private bool enrolling = false;
        private bool cancelled = false;

        public async bool probe() {
            try {
                FprintManager manager = yield Bus.get_proxy(BusType.SYSTEM, "net.reactivated.Fprint",
                    "/net/reactivated/Fprint/Manager", DBusProxyFlags.DO_NOT_AUTO_START);
                ObjectPath path = yield manager.get_default_device();
                device = yield Bus.get_proxy(BusType.SYSTEM, "net.reactivated.Fprint", path);
                ((DBusProxy) device).set_default_timeout(int.MAX);
                device.enroll_status.connect(on_enroll_status);
                return true;
            } catch (Error e) {
                device = null;
                return false;
            }
        }

        public static string? unsupported_sensor() {
            string[] vendors = { "10a5", "27c6", "06cb", "138a", "04f3", "1c7a", "2808", "298d", "147e", "08ff" };
            try {
                var dir = Dir.open("/sys/bus/usb/devices");
                string? entry;
                while ((entry = dir.read_name()) != null) {
                    string base_path = Path.build_filename("/sys/bus/usb/devices", entry);
                    string vendor, product, name = "";
                    try {
                        FileUtils.get_contents(Path.build_filename(base_path, "idVendor"), out vendor);
                        FileUtils.get_contents(Path.build_filename(base_path, "idProduct"), out product);
                    } catch (FileError e) {
                        continue;
                    }
                    vendor = vendor.strip();
                    if (!(vendor in vendors)) continue;
                    try {
                        FileUtils.get_contents(Path.build_filename(base_path, "product"), out name);
                    } catch (FileError e) {
                    }
                    string label = name.strip();
                    if (!label.down().contains("finger") && !label.down().contains("fpc")
                            && !label.down().contains("sensor") && !label.down().contains("match")) {
                        continue;
                    }
                    return "%s:%s".printf(vendor, product.strip());
                }
            } catch (FileError e) {
            }
            return null;
        }

        public async string[] enrolled() {
            if (device == null) return {};
            try {
                return yield device.list_enrolled_fingers(user);
            } catch (Error e) {
                return {};
            }
        }

        public async void enroll() {
            if (device == null || busy) return;
            busy = true;
            cancelled = false;
            string[] taken = yield enrolled();
            string? finger = null;
            foreach (string name in FINGERS) {
                if (!(name in taken)) {
                    finger = name;
                    break;
                }
            }
            if (finger == null) {
                busy = false;
                finished(false, _("All fingers are already enrolled"));
                return;
            }
            try {
                yield device.claim(user);
                claimed = true;
                if (cancelled) {
                    yield release();
                    return;
                }
                stages = yield read_stages();
                stage = 0;
                enrolling = true;
                started(stages);
                yield device.enroll_start(finger);
                if (enrolling) scanning();
            } catch (Error e) {
                if (cancelled) return;
                enrolling = false;
                yield release();
                finished(false, describe(e));
            }
        }

        public async void cancel() {
            if (!busy || cancelled) return;
            cancelled = true;
            if (enrolling) {
                enrolling = false;
                try {
                    yield device.enroll_stop();
                } catch (Error e) {
                }
            }
            if (claimed) yield release();
        }

        public async bool remove_all() {
            if (device == null || busy) return false;
            busy = true;
            try {
                yield device.claim(user);
                claimed = true;
                yield device.delete_enrolled_fingers2();
                yield release();
                return true;
            } catch (Error e) {
                yield release();
                return false;
            }
        }

        private async int read_stages() {
            try {
                var reply = yield ((DBusProxy) device).get_connection().call("net.reactivated.Fprint",
                    ((DBusProxy) device).get_object_path(), "org.freedesktop.DBus.Properties", "Get",
                    new Variant("(ss)", "net.reactivated.Fprint.Device", "num-enroll-stages"),
                    new VariantType("(v)"), DBusCallFlags.NONE, -1);
                Variant value = reply.get_child_value(0).get_variant();
                return value.is_of_type(VariantType.INT32) ? value.get_int32() : 0;
            } catch (Error e) {
                return 0;
            }
        }

        private static string describe(Error e) {
            string? remote = DBusError.get_remote_error(e);
            if (remote != null && remote.has_suffix("PermissionDenied")) {
                return _("Authentication is required to add a fingerprint");
            }
            if (remote != null && remote.has_suffix("NoSuchDevice")) {
                return _("The fingerprint reader was disconnected");
            }
            if (remote != null && remote.has_suffix("AlreadyInUse")) {
                return _("The fingerprint reader is in use by another application");
            }
            DBusError.strip_remote_error(e);
            return e.message;
        }

        private async void release() {
            enrolling = false;
            busy = false;
            if (!claimed) return;
            claimed = false;
            try {
                yield device.release();
            } catch (Error e) {
            }
        }

        private void finish(bool success, string message) {
            enrolling = false;
            release.begin();
            finished(success, message);
        }

        private void on_enroll_status(string result, bool done) {
            if (!enrolling) return;
            switch (result) {
                case "enroll-stage-passed":
                    stage++;
                    stage_passed(stage, stages);
                    break;
                case "enroll-retry-scan":
                    retry(_("The scan was not clear. Touch the sensor again."));
                    break;
                case "enroll-swipe-too-short":
                    retry(_("The swipe was too short. Swipe your finger again."));
                    break;
                case "enroll-finger-not-centered":
                    retry(_("Your finger was not centered. Touch the sensor again."));
                    break;
                case "enroll-remove-and-retry":
                    retry(_("Lift your finger, then touch the sensor again."));
                    break;
                case "enroll-completed":
                    finish(true, _("Fingerprint added"));
                    break;
                case "enroll-data-full":
                    finish(false, _("The sensor has no room for more fingerprints"));
                    break;
                case "enroll-duplicate":
                    finish(false, _("This finger is already enrolled"));
                    break;
                case "enroll-disconnected":
                    finish(false, _("The fingerprint reader was disconnected"));
                    break;
                default:
                    if (done) finish(false, _("The fingerprint could not be added"));
                    break;
            }
        }
    }
}
