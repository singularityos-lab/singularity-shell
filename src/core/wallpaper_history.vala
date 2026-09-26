using GLib;
using Gee;

namespace Singularity {

    public class WallpaperHistory : Object {
        public const int MAX_ENTRIES = 200;
        private const string BACK_KEY = "wallpaper-history-back";
        private const string FORWARD_KEY = "wallpaper-history-forward";
        private const string CURRENT_KEY = "wallpaper-history-current";

        private GLib.Settings settings;
        private ArrayList<string> back = new ArrayList<string>();
        private ArrayList<string> forward = new ArrayList<string>();
        private int max_entries;
        public string? current_path { get; private set; default = null; }
        public int size { get { return back.size + forward.size + (current_path != null ? 1 : 0); } }

        public WallpaperHistory(GLib.Settings? settings = null, int max_entries = MAX_ENTRIES) {
            this.settings = settings ?? new GLib.Settings("dev.sinty.desktop");
            this.max_entries = int.max(1, max_entries);
            load();
        }

        private bool has_key(string key) {
            SettingsSchema? schema = settings.settings_schema;
            return schema != null && schema.has_key(key);
        }

        private void load_stack(ArrayList<string> destination, string key) {
            if (!has_key(key)) return;
            foreach (string path in settings.get_strv(key)) {
                if (path != "") destination.add(path);
            }
        }

        private void load() {
            load_stack(back, BACK_KEY);
            load_stack(forward, FORWARD_KEY);
            if (has_key(CURRENT_KEY)) {
                string saved = settings.get_string(CURRENT_KEY);
                if (saved != "") current_path = saved;
            }
            trim_to_limit();
        }

        private string[] stack_to_array(ArrayList<string> stack) {
            string[] result = {};
            foreach (string path in stack) result += path;
            return result;
        }

        private void save() {
            settings.delay();
            if (has_key(BACK_KEY)) settings.set_strv(BACK_KEY, stack_to_array(back));
            if (has_key(FORWARD_KEY)) settings.set_strv(FORWARD_KEY, stack_to_array(forward));
            if (has_key(CURRENT_KEY)) settings.set_string(CURRENT_KEY, current_path ?? "");
            settings.apply();
        }

        private void trim_to_limit() {
            while (size > max_entries) {
                if (back.size > 0) back.remove_at(0);
                else if (forward.size > 0) forward.remove_at(0);
                else break;
            }
        }

        public void record(string path) {
            if (path == "" || path == current_path) return;
            if (current_path != null) back.add(current_path);
            current_path = path;
            forward.clear();
            trim_to_limit();
            save();
        }

        public bool can_go_back() {
            return current_path != null && back.size > 0;
        }

        public bool can_go_forward() {
            return current_path != null && forward.size > 0;
        }

        public string? go_back() {
            if (!can_go_back()) return null;
            forward.add(current_path);
            current_path = back.remove_at(back.size - 1);
            save();
            return current_path;
        }

        public string? go_forward() {
            if (!can_go_forward()) return null;
            back.add(current_path);
            current_path = forward.remove_at(forward.size - 1);
            save();
            return current_path;
        }
    }
}
