using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PinSecurityKey : Object {
        public string index { get; construct; }
        public string name { get; construct; }

        public PinSecurityKey(string index, string name) {
            Object(index: index, name: name);
        }
    }

    public errordomain PinKeyError {
        FAILED
    }

    public class PinKeys : Object {
        public const string SOCKET = "/run/sinty-pind.sock";

        public static bool available() {
            return Singularity.Runtime.is_sinty_os() && FileUtils.test(SOCKET, FileTest.EXISTS);
        }

        public static string message(string reason) {
            switch (reason) {
                case "security-key-absent": return _("Plug in the security key.");
                case "security-key-untouched": return _("The security key was not touched in time.");
                case "security-key-unknown": return _("This security key does not belong to this account.");
                case "security-key-pin-required": return _("This security key has its own PIN. Enter it too.");
                case "security-key-pin-invalid": return _("The PIN of the security key is not correct.");
                case "security-key-pin-blocked": return _("The PIN of the security key is blocked.");
                case "security-key-unsupported": return _("This security key cannot keep a secret for the computer.");
                case "security-key-exists": return _("This security key already belongs to this account.");
                case "security-key-full": return _("This account already has as many security keys as it can hold.");
                case "security-key-failed": return _("The security key did not answer.");
            }
            return reason;
        }

        public static string[] exchange(string request) throws Error {
            var sock = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
            sock.set_timeout(150);
            sock.connect(new UnixSocketAddress(SOCKET), null);
            var conn = SocketConnection.factory_create_connection(sock);
            size_t written;
            conn.output_stream.write_all(request.data, out written, null);
            var reply = new DataInputStream(conn.input_stream);
            var lines = new GenericArray<string>();
            string? line;
            while ((line = reply.read_line_utf8(null, null)) != null) lines.add(line.strip());
            conn.close();
            return lines.data;
        }

        public static void check(string[] lines, string fallback) throws PinKeyError {
            if (lines.length > 0 && lines[lines.length - 1] == "OK") return;
            string reason = lines.length > 0 ? lines[lines.length - 1] : "";
            if (reason.has_prefix("FAIL:")) reason = reason.substring(5).strip();
            throw new PinKeyError.FAILED(reason != "" ? message(reason) : fallback);
        }

        public static Gee.ArrayList<PinSecurityKey> parse(string[] lines) {
            var keys = new Gee.ArrayList<PinSecurityKey>();
            foreach (var line in lines) {
                if (!line.has_prefix("KEY ")) continue;
                var parts = line.substring(4).split("\t", 2);
                if (parts.length == 2) keys.add(new PinSecurityKey(parts[0], parts[1]));
            }
            return keys;
        }

        static async string[] run(string request) throws Error {
            string[] result = {};
            Error? failure = null;
            SourceFunc resume = run.callback;
            new Thread<void>("pin-keys", () => {
                try {
                    result = exchange(request);
                } catch (Error e) {
                    failure = e;
                }
                Idle.add((owned) resume);
            });
            yield;
            if (failure != null) throw failure;
            return result;
        }

        public static async Gee.ArrayList<PinSecurityKey> list() throws Error {
            var lines = yield run("keys v1\n");
            check(lines, _("The security keys could not be read."));
            return parse(lines);
        }

        public static async void add(string pin, string name, string key_pin) throws Error {
            var lines = yield run("add-key v1\n%s\n%s\n%s\n".printf(pin, name, key_pin));
            check(lines, _("The PIN is not correct, or the security key was not added."));
        }

        public static async void remove(string pin, string index) throws Error {
            var lines = yield run("remove-key v1\n%s\n%s\n".printf(pin, index));
            check(lines, _("The PIN is not correct, or the security key was not removed."));
        }
    }

    public class PinSecurityKeysPage : SettingsPage {
        private PreferencesGroup keys_group;
        private PasswordRow pin_row;
        private Label status;
        private bool busy;

        public PinSecurityKeysPage(SettingsView view, string back) {
            base(_("Security Keys"));
            back_clicked.connect(() => view.navigate_to(back));

            var pin_group = new PreferencesGroup(_("PIN"),
                _("With a FIDO2 security key this account opens only when one of its security keys is touched, together with the PIN. Register a spare and keep it apart. The recovery code still opens the account without them."));
            pin_row = new PasswordRow(_("PIN"));
            pin_group.add_row(pin_row);
            add_group(pin_group);

            keys_group = new PreferencesGroup(_("Security Keys"));
            add_group(keys_group);

            status = status_label();
            add_widget(status);
            refresh.begin();
        }

        private void say(string text) {
            status.label = text;
            status.visible = text != "";
        }

        private async void refresh() {
            keys_group.clear();
            Gee.ArrayList<PinSecurityKey> keys;
            try {
                keys = yield PinKeys.list();
            } catch (Error e) {
                keys_group.add_row(new ActionRow(e.message, "", "dialog-warning-symbolic"));
                return;
            }
            foreach (var k in keys) {
                var row = new ActionRow(k.name, "", "security-high-symbolic");
                var remove = row_button(_("Remove"), false);
                remove.add_css_class("destructive-action");
                string index = k.index;
                remove.clicked.connect(() => remove_key.begin(index, keys.size == 1));
                row.add_suffix(remove);
                keys_group.add_row(row);
            }
            var name = new EntryRow(_("Name"));
            name.text = keys.size > 0 ? _("Spare") : _("Security Key");
            var key_pin = new PasswordRow(_("Security Key PIN, if It Has One"));
            var add = row_button(keys.size > 0 ? _("Add Spare") : _("Add"), false);
            key_pin.add_suffix(add);
            keys_group.add_row(name);
            keys_group.add_row(key_pin);
            bool strong = keys.size > 0;
            add.clicked.connect(() => add_key.begin(name, key_pin, strong));
        }

        private async void add_key(EntryRow name, PasswordRow key_pin, bool strong) {
            if (busy) return;
            if (pin_row.text == "") {
                say(_("Enter the PIN first."));
                return;
            }
            if (name.text.strip() == "") {
                say(_("Give the security key a name."));
                return;
            }
            busy = true;
            say(strong ? _("Touch a security key of this account, then touch the new one twice…")
                       : _("Plug in the security key and touch it when it blinks, up to two times…"));
            try {
                yield PinKeys.add(pin_row.text, name.text.strip().replace("\n", " "), key_pin.text);
                say(_("The security key was added."));
                yield refresh();
            } catch (Error e) {
                say(e.message);
            }
            busy = false;
        }

        private async void remove_key(string index, bool last) {
            if (busy) return;
            if (pin_row.text == "") {
                say(_("Enter the PIN first."));
                return;
            }
            busy = true;
            say(_("Touch a security key of this account…"));
            try {
                yield PinKeys.remove(pin_row.text, index);
                say(last ? _("The account opens with the PIN alone again.") : _("The security key was removed."));
                yield refresh();
            } catch (Error e) {
                say(e.message);
            }
            busy = false;
        }
    }
}
