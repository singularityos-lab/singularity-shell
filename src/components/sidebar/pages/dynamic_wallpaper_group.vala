using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class DynamicWallpaperGroup : PreferencesGroup {
        private GLib.Settings settings;
        private DesktopPage page;
        private ActionRow status_row;
        private EntryRow location_row;
        private ActionRow import_row;
        private bool importing = false;

        public DynamicWallpaperGroup(DesktopPage page) {
            Object();
            title = _("Dynamic Wallpaper");
            description = _("Wallpapers that follow the time of day or the light and dark appearance.");
            this.page = page;
            settings = new GLib.Settings("dev.sinty.desktop");
            var controller = DynamicWallpaperController.get_default();

            status_row = new ActionRow("", null, "preferences-desktop-wallpaper-symbolic");
            add_row(status_row);

            location_row = new EntryRow(_("Location"), "find-location-symbolic");
            location_row.text = settings.get_string(DynamicWallpaperController.COORDINATES_KEY);
            location_row.entry_activated.connect(() => save_location());
            location_row.entry_changed.connect(() => {
                string text = location_row.text.strip();
                double lat = 0, lon = 0;
                if (text == "" || DynamicWallpaperController.parse_coordinates(text, out lat, out lon))
                    location_row.remove_css_class("error");
                else
                    location_row.add_css_class("error");
            });
            add_row(location_row);

            import_row = new ActionRow(_("Import Dynamic Wallpaper"), import_hint(), "document-open-symbolic");
            import_row.activated.connect(() => choose_file());
            add_row(import_row);

            controller.state_changed.connect(() => update());
            settings.changed[DynamicWallpaperController.PICTURE_KEY].connect(() => update());
            Singularity.Style.ThemeMode.get_default().changed.connect(() => update());
            update();
        }

        private string import_hint() {
            if (DynamicWallpaperImporter.heic_supported())
                return _("HEIC from macOS, a time-based XML slideshow or a Singularity manifest");
            return _("A time-based XML slideshow or a Singularity manifest. HEIC needs a decoder that is not installed.");
        }

        private void save_location() {
            string text = location_row.text.strip();
            double lat = 0, lon = 0;
            if (text != "" && !DynamicWallpaperController.parse_coordinates(text, out lat, out lon)) return;
            settings.set_string(DynamicWallpaperController.COORDINATES_KEY, text);
            update();
        }

        private string location_text(DynamicWallpaperController controller) {
            switch (controller.location_source) {
                case "manual": return _("Sun position for the coordinates below");
                case "timezone": return _("Sun position for your time zone");
                default: return _("Sun position for an approximate location");
            }
        }

        private void update() {
            var controller = DynamicWallpaperController.get_default();
            var wp = controller.wallpaper;
            status_row.visible = wp != null;
            location_row.visible = wp != null && wp.kind == DynamicWallpaperKind.SOLAR;
            if (wp == null) return;
            status_row.title = wp.display_name();
            string kind;
            switch (wp.kind) {
                case DynamicWallpaperKind.SOLAR:
                    controller.current_state();
                    kind = location_text(controller);
                    break;
                case DynamicWallpaperKind.APPEARANCE:
                    kind = Singularity.Style.ThemeMode.get_default().shell_dark()
                        ? _("Follows the appearance, dark now") : _("Follows the appearance, light now");
                    break;
                case DynamicWallpaperKind.CYCLE:
                    kind = _("Timed slideshow");
                    break;
                default:
                    kind = _("Changes at set times of day");
                    break;
            }
            status_row.subtitle = kind;
            location_row.subtitle = _("Latitude and longitude, for example 45.46, 9.19. Leave empty to use the time zone.");
        }

        private void choose_file() {
            if (importing) return;
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Import Dynamic Wallpaper");
            var filter = new Gtk.FileFilter();
            filter.name = _("Dynamic Wallpapers");
            filter.add_suffix("json");
            filter.add_suffix("xml");
            if (DynamicWallpaperImporter.heic_supported()) {
                filter.add_suffix("heic");
                filter.add_suffix("heif");
            }
            var filters = new GLib.ListStore(typeof(Gtk.FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.default_filter = filter;
            SidebarWait.choose_file.begin(this, dialog, null, (obj, result) => {
                try {
                    var file = SidebarWait.choose_file.end(result);
                    string? path = file.get_path();
                    if (path != null) import_path(path);
                } catch (Error e) {
                }
            });
        }

        public void import_path(string path) {
            importing = true;
            import_row.subtitle = _("Importing…");
            import_row.remove_css_class("error");
            new Thread<void>("dynamic-wallpaper-import", () => {
                string manifest = "";
                string failure = "";
                try {
                    manifest = DynamicWallpaperImporter.import_file(path);
                } catch (Error e) {
                    failure = e.message;
                }
                Idle.add(() => {
                    importing = false;
                    if (failure != "") {
                        import_row.subtitle = _("Could not import: %s").printf(failure);
                        import_row.add_css_class("error");
                        return Source.REMOVE;
                    }
                    import_row.subtitle = import_hint();
                    page.show_collection("dynamic-imports");
                    settings.set_string(DynamicWallpaperController.PICTURE_KEY, File.new_for_path(manifest).get_uri());
                    return Source.REMOVE;
                });
            });
        }
    }
}
