namespace Singularity {

    public delegate OnScreenKeyboard ScreenKeyboardAcquire();
    public delegate void ScreenKeyboardRelease();

    [DBus (name = "dev.sinty.ScreenKeyboard")]
    public class ScreenKeyboardService : Object {
        public signal void closed(bool accepted);

        private ScreenKeyboardAcquire acquire;
        private ScreenKeyboardRelease release;
        private OnScreenKeyboard? keyboard = null;
        private ulong done_handler = 0;
        private uint client_watch = 0;

        [DBus (visible = false)]
        public ScreenKeyboardService(owned ScreenKeyboardAcquire acquire, owned ScreenKeyboardRelease release) {
            this.acquire = (owned) acquire;
            this.release = (owned) release;
        }

        [DBus (visible = false)]
        public void own_bus() {
            Bus.own_name(BusType.SESSION, "dev.sinty.ScreenKeyboard",
                BusNameOwnerFlags.REPLACE | BusNameOwnerFlags.ALLOW_REPLACEMENT,
                (conn) => {
                    try {
                        conn.register_object("/dev/sinty/ScreenKeyboard", this);
                    } catch (IOError e) {
                        warning("ScreenKeyboardService: cannot register: %s", e.message);
                    }
                },
                null,
                () => warning("ScreenKeyboardService: name lost"));
        }

        public void open(string text, int cursor, BusName sender) throws DBusError, IOError {
            if (client_watch != 0) Bus.unwatch_name(client_watch);
            client_watch = Bus.watch_name(BusType.SESSION, sender, BusNameWatcherFlags.NONE, null, () => finish(false));
            if (keyboard == null) {
                keyboard = acquire();
                done_handler = keyboard.remote_done.connect(finish);
            }
            keyboard.start_remote(text, cursor);
        }

        public void set_text(string text, int cursor) throws DBusError, IOError {
            if (keyboard != null) keyboard.set_preview(text, cursor);
        }

        public void navigate(string direction) throws DBusError, IOError {
            if (keyboard != null) keyboard.navigate(direction);
        }

        public void activate() throws DBusError, IOError {
            if (keyboard != null) keyboard.activate_highlighted();
        }

        public void close() throws DBusError, IOError {
            finish(false);
        }

        private void finish(bool accepted) {
            if (client_watch != 0) {
                Bus.unwatch_name(client_watch);
                client_watch = 0;
            }
            if (keyboard == null) return;
            keyboard.disconnect(done_handler);
            done_handler = 0;
            keyboard.stop_remote();
            keyboard = null;
            release();
            closed(accepted);
        }
    }
}
