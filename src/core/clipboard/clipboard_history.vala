using GLib;

namespace Singularity {

    public class ClipboardHistory : Object {
        public const string SCHEMA = "dev.sinty.desktop.clipboard";
        private static ClipboardHistory? _instance = null;

        public ClipboardModel model { get; private set; default = new ClipboardModel(); }
        public GLib.Settings? settings { get; private set; default = null; }
        public bool watching { get; private set; default = false; }
        public uint skipped_sensitive { get; private set; default = 0; }

        private string _dir;
        private uint _save_id = 0;
        private ulong _gdk_handler = 0;

        public static ClipboardHistory get_default() {
            if (_instance == null) _instance = new ClipboardHistory();
            return _instance;
        }

        private ClipboardHistory() {
            _dir = Path.build_filename(Environment.get_user_data_dir(), "singularity", "clipboard");
            var source = SettingsSchemaSource.get_default();
            if (source != null && source.lookup(SCHEMA, true) != null) {
                settings = new GLib.Settings(SCHEMA);
                model.limit = int.max(5, settings.get_int("history-limit"));
                settings.changed["history-limit"].connect(() => model.limit = int.max(5, settings.get_int("history-limit")));
                settings.changed["history-enabled"].connect(() => {
                    if (!enabled) model.clear();
                });
            }
            retire_legacy_plugin(source);
            load_pinned();
            model.changed.connect(schedule_save);
        }

        public bool enabled {
            get { return settings == null || settings.get_boolean("history-enabled"); }
        }

        public bool paste_on_select {
            get { return settings == null || settings.get_boolean("paste-on-select"); }
        }

        public void start() {
            if (watching) return;
            watching = clipboard_watch_start(on_selection);
            if (!watching) {
                var display = Gdk.Display.get_default();
                if (display == null) return;
                var clipboard = display.get_clipboard();
                _gdk_handler = clipboard.changed.connect(() => read_gdk(clipboard));
            }
        }

        public signal void text_copied(string text);

        private void on_selection(string mime, Bytes? data, bool sensitive) {
            if (sensitive) {
                skipped_sensitive++;
                debug("clipboard: skipped an item marked as secret");
                return;
            }
            if (data != null && ClipboardModel.is_text_mime(mime)) {
                var sb = new StringBuilder.sized(data.get_size() + 1);
                sb.append_len((string) data.get_data(), (ssize_t) data.get_size());
                if (sb.str.validate() && sb.str.strip() != "") text_copied(sb.str);
            }
            if (!enabled || data == null) return;
            model.add(mime, data, get_real_time());
        }

        private void read_gdk(Gdk.Clipboard clipboard) {
            var formats = clipboard.get_formats();
            if (formats == null || formats.contain_mime_type("x-kde-passwordManagerHint")) {
                skipped_sensitive++;
                return;
            }
            if (formats.contain_gtype(typeof(Gdk.Texture))) {
                clipboard.read_texture_async.begin(null, (obj, res) => {
                    try {
                        var tex = clipboard.read_texture_async.end(res);
                        if (tex != null && enabled) model.add("image/png", tex.save_to_png_bytes(), get_real_time());
                    } catch (Error e) {
                    }
                });
                return;
            }
            clipboard.read_text_async.begin(null, (obj, res) => {
                try {
                    string? text = clipboard.read_text_async.end(res);
                    if (text != null && text.strip() != "") text_copied(text);
                    if (text != null && text != "" && enabled) model.add("text/plain;charset=utf-8", new Bytes(text.data), get_real_time());
                } catch (Error e) {
                }
            });
        }

        public bool copy(ClipboardEntry entry) {
            if (watching && clipboard_set(entry.mime, entry.data)) return true;
            var display = Gdk.Display.get_default();
            if (display == null) return false;
            if (entry.is_image) {
                try {
                    var tex = Gdk.Texture.from_bytes(entry.data);
                    display.get_clipboard().set_texture(tex);
                } catch (Error e) {
                    return false;
                }
            } else {
                display.get_clipboard().set_text(entry.text);
            }
            return true;
        }

        public void paste_into_focused() {
            clipboard_send_paste();
        }

        private void retire_legacy_plugin(SettingsSchemaSource? source) {
            if (source == null || source.lookup("dev.sinty.desktop", true) == null) return;
            if (!ClipboardPluginMigration.needed(_dir)) return;
            if (ClipboardPluginMigration.run(new GLib.Settings("dev.sinty.desktop"), settings, _dir))
                message("clipboard: retired the Clipboard History plugin in favour of the built-in history");
        }

        private void load_pinned() {
            string json;
            try {
                if (FileUtils.get_contents(Path.build_filename(_dir, "pinned.json"), out json)) {
                    model.load_pinned(json, _dir);
                }
            } catch (FileError e) {
            }
        }

        private void schedule_save() {
            if (_save_id != 0) return;
            _save_id = Timeout.add(500, () => {
                _save_id = 0;
                DirUtils.create_with_parents(_dir, 0700);
                try {
                    FileUtils.set_contents_full(Path.build_filename(_dir, "pinned.json"), model.pinned_to_json(_dir), -1,
                        FileSetContentsFlags.CONSISTENT, 0600);
                } catch (FileError e) {
                    warning("clipboard: could not save pinned items: %s", e.message);
                }
                prune_images();
                return Source.REMOVE;
            });
        }

        private void prune_images() {
            var keep = new Gee.HashSet<string>();
            foreach (var e in model.entries) {
                if (e.pinned && e.is_image) keep.add(e.digest + ".img");
            }
            try {
                var d = Dir.open(_dir);
                string? n;
                while ((n = d.read_name()) != null) {
                    if (n.has_suffix(".img") && !keep.contains(n)) FileUtils.remove(Path.build_filename(_dir, n));
                }
            } catch (FileError e) {
            }
        }
    }

    public class CursorPositionRequest : Object {
        private static CursorPositionRequest? _instance = null;
        private bool _pending = false;

        public signal void received(int x, int y);

        public static CursorPositionRequest get_default() {
            if (_instance == null) _instance = new CursorPositionRequest();
            return _instance;
        }

        public bool request() {
            if (_pending) return true;
            _pending = wayland_request_cursor_position();
            if (_pending) {
                Timeout.add(500, () => {
                    _pending = false;
                    return Source.REMOVE;
                });
            }
            return _pending;
        }

        public bool deliver(int x, int y) {
            if (!_pending) return false;
            _pending = false;
            received(x, y);
            return true;
        }
    }
}
