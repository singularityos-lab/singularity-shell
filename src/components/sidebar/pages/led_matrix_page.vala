using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class LedMatrixPage : SettingsPage {
        private const string STUDIO_ID = "dev.sinty.ledstudio";

        private LedMatrixService service;
        private GLib.Settings settings;
        private LedMatrixView preview;
        private PreferencesGroup scene_group;
        private PreferencesGroup custom_group;
        private ActionRow device_row;
        private ulong frame_handler = 0;
        private ulong scenes_handler = 0;
        private ulong available_handler = 0;

        public LedMatrixPage(SettingsView view) {
            base(_("LED Matrix"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("displays"));
            service = LedMatrixService.get_default();
            settings = new GLib.Settings("dev.sinty.desktop");

            preview = new LedMatrixView();
            preview.set_size(service.width, service.height);
            preview.height_request = 150;
            preview.margin_bottom = 6;
            var preview_group = new PreferencesGroup();
            preview_group.add_row(preview);
            add_group(preview_group);

            var matrix_group = new PreferencesGroup(_("Matrix"));
            var enabled = new SwitchRow(_("Show Content"),
                _("When off, the matrix stays dark"), settings.get_boolean("led-matrix-enabled"));
            settings.bind("led-matrix-enabled", enabled.switch_btn, "active", SettingsBindFlags.DEFAULT);
            matrix_group.add_row(enabled);
            var brightness_row = new ActionRow(_("Brightness"), _("The brightest level the matrix may use"));
            brightness_row.activatable = false;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 7, 1);
            scale.width_request = 170;
            scale.draw_value = false;
            scale.set_value(settings.get_int("led-matrix-brightness"));
            scale.value_changed.connect(() => settings.set_int("led-matrix-brightness", (int) scale.get_value()));
            brightness_row.add_suffix(scale);
            settings.bind("led-matrix-enabled", brightness_row, "sensitive", SettingsBindFlags.GET);
            matrix_group.add_row(brightness_row);
            device_row = new ActionRow(_("Device"), "");
            device_row.activatable = false;
            matrix_group.add_row(device_row);
            add_group(matrix_group);

            scene_group = new PreferencesGroup(_("Scene"), _("What the matrix shows"));
            settings.bind("led-matrix-enabled", scene_group, "sensitive", SettingsBindFlags.GET);
            add_group(scene_group);

            custom_group = new PreferencesGroup(_("Your Scenes"),
                _("Scenes made in LED Studio or imported from a file"));
            settings.bind("led-matrix-enabled", custom_group, "sensitive", SettingsBindFlags.GET);
            add_group(custom_group);

            settings.changed.connect(on_setting);
            map.connect(() => {
                frame_handler = service.frame_rendered.connect((px) => preview.set_pixels(px));
                scenes_handler = service.scenes_changed.connect(rebuild);
                available_handler = service.notify["available"].connect(update_device);
                rebuild();
                update_device();
                service.refresh();
            });
            unmap.connect(() => {
                service.disconnect(frame_handler);
                service.disconnect(scenes_handler);
                service.disconnect(available_handler);
            });
        }

        private void on_setting(string key) {
            if (key == "led-matrix-scene") rebuild();
        }

        private void update_device() {
            preview.set_size(service.width, service.height);
            if (service.available) {
                device_row.subtitle = _("%d × %d, firmware %u").printf(service.width, service.height, service.firmware);
            } else {
                device_row.subtitle = _("The matrix is not answering yet");
            }
        }

        private ActionRow scene_row(string id) {
            var row = new ActionRow(service.scene_title(id), null);
            if (settings.get_string("led-matrix-scene") == id) {
                var check = new Image.from_icon_name("object-select-symbolic");
                check.valign = Align.CENTER;
                check.tooltip_text = _("Showing");
                row.add_suffix(check);
            } else {
                row.activatable = true;
                row.activated.connect(() => settings.set_string("led-matrix-scene", id));
            }
            return row;
        }

        private void rebuild() {
            scene_group.clear();
            foreach (var id in LedScene.builtin_ids()) scene_group.add_row(scene_row(id));

            custom_group.clear();
            foreach (var id in service.custom_ids()) {
                var row = scene_row(id);
                var remove = new Button.from_icon_name("user-trash-symbolic");
                remove.add_css_class("flat");
                remove.add_css_class("destructive-action");
                remove.valign = Align.CENTER;
                remove.tooltip_text = _("Remove Scene");
                remove.clicked.connect(() => row.confirmation_requested(_("Remove"), _("Cancel"),
                    ConfirmationSuggestedAction.CANCEL));
                row.confirmed.connect(() => service.remove_scene(id));
                row.add_suffix(remove);
                custom_group.add_row(row);
            }
            var import_row = new ActionRow(_("Import Scene"), _("A scene file saved from LED Studio"), "document-open-symbolic");
            import_row.activatable = true;
            import_row.activated.connect(() => on_import(import_row));
            custom_group.add_row(import_row);

            var studio = new DesktopAppInfo(STUDIO_ID + ".desktop");
            if (studio != null) {
                var open_row = new ActionRow(_("Open LED Studio"), _("Draw, animate and test scenes live"), "dev.sinty.ledstudio");
                open_row.activatable = true;
                open_row.add_suffix(NotificationSettingsPage.chevron());
                open_row.activated.connect(() => {
                    try {
                        studio.launch(null, null);
                    } catch (Error e) {
                        warning("LED Studio: %s", e.message);
                    }
                });
                custom_group.add_row(open_row);
            }
        }

        private void on_import(ActionRow row) {
            var dialog = new Gtk.FileDialog();
            dialog.title = _("Import Scene");
            var filter = new Gtk.FileFilter();
            filter.name = _("LED Scenes");
            filter.add_pattern("*.json");
            var filters = new GLib.ListStore(typeof(Gtk.FileFilter));
            filters.append(filter);
            dialog.filters = filters;
            dialog.default_filter = filter;
            SidebarWait.choose_file.begin(this, dialog, null, (obj, result) => {
                try {
                    var file = SidebarWait.choose_file.end(result);
                    if (file.get_path() == null) return;
                    string id = service.import_scene(file.get_path());
                    settings.set_string("led-matrix-scene", id);
                } catch (Error e) {
                    if (e is IOError.CANCELLED || e is Gtk.DialogError) return;
                    row.subtitle = e.message;
                }
            });
        }
    }
}
