using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class StoragePage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup drives_group;
        private const int LOW_PERCENT = 20;

        private ActionRow space_row;
        private Image space_warning;
        private ulong health_id;
        private VolumeMonitor monitor;

        public StoragePage(SettingsView view) {
            base(_("Storage"));
            this.view = view;
            var computer = new PreferencesGroup();
            space_row = new ActionRow(_("This Computer"), "", "drive-harddisk-symbolic");
            space_warning = new Image.from_icon_name("dialog-warning-symbolic");
            space_warning.valign = Align.CENTER;
            space_warning.add_css_class("warning");
            space_warning.visible = false;
            space_row.add_suffix(space_warning);
            computer.add_row(space_row);
            add_group(computer);
            drives_group = new PreferencesGroup(_("USB Drives"),
                _("Sinty OS keeps an eye on the USB drives you use and warns you when one starts to wear out."));
            add_group(drives_group);
            update_space();
            health_id = DriveHealthMonitor.get_default().changed.connect(() => refresh.begin());
            monitor = VolumeMonitor.get();
            monitor.mount_added.connect(() => refresh.begin());
            monitor.mount_removed.connect(() => refresh.begin());
            destroy.connect(() => DriveHealthMonitor.get_default().disconnect(health_id));
            refresh.begin();
        }

        public static void open(SettingsView view) {
            var page = new StoragePage(view);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.go_home());
            view.open_subpage(page, "storage");
        }

        private void update_space() {
            try {
                var info = File.new_for_path(Environment.get_home_dir())
                    .query_filesystem_info("filesystem::size,filesystem::free");
                uint64 size = info.get_attribute_uint64("filesystem::size");
                uint64 free = info.get_attribute_uint64("filesystem::free");
                string text = _("%s free of %s").printf(format_size(free), format_size(size));
                space_warning.visible = size > 0 && free * 100 < size * LOW_PERCENT;
                if (space_warning.visible)
                    text = _("%s. Less than %d%% is free: the disk slows down and updates may not fit. Remove files you no longer need.")
                        .printf(text, LOW_PERCENT);
                space_row.subtitle = text;
            } catch (Error e) {
                space_row.subtitle = "";
                space_warning.visible = false;
            }
        }

        private static async bool monitored() {
            try {
                var bus = yield Bus.get(BusType.SYSTEM);
                var reply = yield bus.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant("(s)", DriveHealth.BUS_NAME), new VariantType("(b)"),
                    DBusCallFlags.NONE, 2000);
                return reply.get_child_value(0).get_boolean();
            } catch (Error e) {
                return false;
            }
        }

        private async void refresh() {
            drives_group.visible = yield monitored();
            if (!drives_group.visible) return;
            var list = yield DriveHealth.all();
            drives_group.clear();
            if (list.size == 0) {
                var empty = new ActionRow(_("No USB drives yet"), _("Drives you connect appear here with their condition."),
                    "drive-removable-media-symbolic");
                drives_group.add_row(empty);
                return;
            }
            list.sort((a, b) => {
                if (a.device != "" && b.device == "") return -1;
                if (a.device == "" && b.device != "") return 1;
                return a.last_seen > b.last_seen ? -1 : (a.last_seen < b.last_seen ? 1 : 0);
            });
            foreach (var h in list) drives_group.add_row(drive_row(h));
        }

        private ActionRow drive_row(DriveHealth h) {
            string name = h.name != "" ? h.name : _("USB Drive");
            string where = h.device != "" ? _("Connected") : _("Last used %s").printf(when(h.last_seen));
            var row = new ActionRow("%s, %s".printf(name, format_size(h.size)), "%s. %s".printf(h.summary(), where));
            var image = new Image.from_icon_name("drive-removable-media");
            image.pixel_size = 32;
            row.add_prefix(image);
            if (h.troubled) {
                var mark = new Image.from_icon_name(h.icon_name());
                mark.valign = Align.CENTER;
                mark.add_css_class(h.condition == DriveCondition.FAILING ? "error" : "warning");
                row.add_suffix(mark);
            }
            row.activatable = true;
            row.add_suffix(new Image.from_icon_name("go-next-symbolic"));
            row.activated.connect(() => {
                var page = new StorageDrivePage(h);
                page.back_btn.visible = true;
                page.back_clicked.connect(() => StoragePage.open(view));
                view.open_subpage(page, "storage-drive");
            });
            return row;
        }

        internal static string when(int64 time) {
            if (time <= 0) return _("never");
            var d = new DateTime.from_unix_local(time);
            return d != null ? d.format(_("%-d %B %Y")) : "";
        }
    }

    public class StorageDrivePage : SettingsPage {
        private DriveHealth health;

        public StorageDrivePage(DriveHealth health) {
            base(health.name != "" ? health.name : _("USB Drive"));
            this.health = health;

            var state = new PreferencesGroup();
            var state_row = new ActionRow(health.summary(), health.reasons.length > 0 ? health.explain() : null);
            var image = new Image.from_icon_name(health.icon_name());
            image.valign = Align.CENTER;
            if (health.condition == DriveCondition.FAILING) image.add_css_class("error");
            else if (health.condition == DriveCondition.WORN) image.add_css_class("warning");
            state_row.add_prefix(image);
            state.add_row(state_row);
            add_group(state);

            var facts = new PreferencesGroup(_("Details"));
            facts.add_row(fact(_("Capacity"), format_size(health.size)));
            if (health.real_size > 0) facts.add_row(fact(_("Real Capacity"), _("About %s").printf(format_size(health.real_size))));
            if (health.serial != "") facts.add_row(fact(_("Serial Number"), health.serial));
            facts.add_row(fact(_("Last Used"), health.device != "" ? _("Connected now") : StoragePage.when(health.last_seen)));
            add_group(facts);

            var mount = DriveHealthAlerts.mount_for(health.device);
            if (mount != null) {
                var actions = new PreferencesGroup();
                var row = new ActionRow(_("Files on This Drive"), _("Copy them to this computer before the drive gets worse."));
                var copy = row_button(_("Copy Files…"), health.troubled);
                copy.clicked.connect(() => {
                    try {
                        AppInfo.launch_default_for_uri(mount.get_root().get_uri(), null);
                    } catch (Error e) {
                        warning("open drive: %s", e.message);
                    }
                });
                row.add_suffix(copy);
                if (mount.can_eject()) {
                    var eject = row_button(_("Eject"), false);
                    eject.clicked.connect(() => mount.eject_with_operation.begin(MountUnmountFlags.NONE, null, null));
                    row.add_suffix(eject);
                }
                actions.add_row(row);
                add_group(actions);
            }
        }

        private ActionRow fact(string title, string value) {
            var row = new ActionRow(title, null);
            var label = new Label(value);
            label.add_css_class("dim-label");
            label.selectable = true;
            label.valign = Align.CENTER;
            row.add_suffix(label);
            return row;
        }
    }
}
