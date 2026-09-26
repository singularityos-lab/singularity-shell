using GLib;
using Gee;

namespace Singularity {

    public class WallpaperFavorites : Object {
        private const string FAVORITES_KEY = "wallpaper-favorites";
        private GLib.Settings settings;
        private ArrayList<string> favorites = new ArrayList<string>();

        public signal void favorites_changed();

        public WallpaperFavorites(GLib.Settings? settings = null) {
            this.settings = settings ?? new GLib.Settings("dev.sinty.desktop");
            SettingsSchema? schema = this.settings.settings_schema;
            if (schema == null || !schema.has_key(FAVORITES_KEY)) return;
            foreach (string path in this.settings.get_strv(FAVORITES_KEY)) {
                if (path != "" && !favorites.contains(path)) favorites.add(path);
            }
        }

        private void save() {
            SettingsSchema? schema = settings.settings_schema;
            if (schema == null || !schema.has_key(FAVORITES_KEY)) return;
            settings.set_strv(FAVORITES_KEY, list_favorites());
        }

        public bool is_favorite(string path) {
            return path != "" && favorites.contains(path);
        }

        public void toggle_favorite(string path) {
            if (path == "") return;
            if (!favorites.remove(path)) favorites.add(path);
            save();
            favorites_changed();
        }

        public string[] list_favorites() {
            string[] result = {};
            foreach (string path in favorites) result += path;
            return result;
        }
    }
}
