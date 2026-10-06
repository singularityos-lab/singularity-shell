using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class CustomShortcutPage : SettingsPage {
        private SettingsView view;
        private ShortcutManager manager;
        private string? keybinding_id;
        private string accelerator = "";
        private EntryRow name_row;
        private SelectionRow kind_row;
        private EntryRow command_row;
        private PreferencesGroup target_group;
        private SelectionRow? app_row = null;
        private SelectionRow? action_row = null;
        private string app_id = "";
        private string action_id = "";
        private Button save_btn;

        public CustomShortcutPage(SettingsView view, ShortcutManager manager, CustomKeybinding? existing) {
            base(existing != null ? _("Edit Shortcut") : _("New Shortcut"));
            this.view = view;
            this.manager = manager;
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("keyboard"));

            keybinding_id = existing != null ? existing.id : null;
            if (existing != null) {
                accelerator = existing.accelerator;
                app_id = existing.app_id;
                action_id = existing.action;
            }

            var general = new PreferencesGroup(_("Shortcut"));
            name_row = new EntryRow(_("Name"));
            name_row.text = existing != null ? existing.name : "";
            name_row.entry_changed.connect(update_save_sensitivity);
            general.add_row(name_row);

            var kinds = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            kinds.add(option("action", _("App Action"), _("An action from an app, such as Translate Clipboard")));
            kinds.add(option("command", _("Command"), _("A command line")));
            bool is_command = existing != null && !existing.is_app_action;
            kind_row = new SelectionRow.with_options(_("Runs"), kinds, is_command ? "command" : "action");
            kind_row.selected.connect(() => update_kind());
            general.add_row(kind_row);
            add_group(general);

            target_group = new PreferencesGroup(_("Target"));
            command_row = new EntryRow(_("Command"));
            command_row.text = existing != null ? existing.command : "";
            command_row.entry_changed.connect(update_save_sensitivity);
            target_group.add_row(command_row);
            build_app_row();
            add_group(target_group);

            save_btn = new Button.with_label(_("Save"));
            save_btn.add_css_class("suggested-action");
            save_btn.add_css_class("pill");
            save_btn.halign = Align.CENTER;
            save_btn.margin_top = 24;
            save_btn.clicked.connect(save);
            add_widget(save_btn);

            update_kind();
        }

        private static Singularity.Core.AppSettingOption option(string id, string label, string? subtitle = null) {
            var opt = new Singularity.Core.AppSettingOption();
            opt.id = id;
            opt.label = label;
            opt.subtitle = subtitle;
            return opt;
        }

        private bool is_command() {
            return kind_row.current_value == "command";
        }

        private void update_kind() {
            command_row.visible = is_command();
            if (app_row != null) app_row.visible = !is_command();
            if (action_row != null) action_row.visible = !is_command();
            update_save_sensitivity();
        }

        private void build_app_row() {
            var apps = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (var info in AppInfo.get_all()) {
                var dai = info as DesktopAppInfo;
                if (dai == null || !dai.should_show() || dai.list_actions().length == 0) continue;
                string id = dai.get_id();
                if (id.has_suffix(".desktop")) id = id.substring(0, id.length - 8);
                apps.add(option(id, dai.get_display_name()));
            }
            apps.sort((a, b) => a.label.collate(b.label));
            app_row = new SelectionRow.with_options(_("App"), apps, app_id);
            app_row.selected.connect((id) => {
                app_id = id;
                action_id = "";
                build_action_row();
                update_save_sensitivity();
            });
            target_group.add_row(app_row);
            build_action_row();
        }

        private void build_action_row() {
            if (action_row != null) target_group.remove_row(action_row);
            var actions = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            var dai = app_id != "" ? new DesktopAppInfo(app_id + ".desktop") : null;
            if (dai != null) {
                foreach (string action in dai.list_actions())
                    actions.add(option(action, dai.get_action_name(action)));
            }
            action_row = new SelectionRow.with_options(_("Action"), actions, action_id);
            action_row.selected.connect((id) => {
                action_id = id;
                update_save_sensitivity();
            });
            action_row.visible = !is_command();
            target_group.add_row(action_row);
        }

        private void update_save_sensitivity() {
            bool named = name_row.text.strip() != "";
            bool target = is_command() ? command_row.text.strip() != "" : (app_id != "" && action_id != "");
            save_btn.sensitive = named && target;
        }

        private void save() {
            if (is_command()) {
                manager.set_custom_keybinding(keybinding_id, name_row.text.strip(), accelerator,
                    command_row.text.strip(), "", "");
            } else {
                manager.set_custom_keybinding(keybinding_id, name_row.text.strip(), accelerator,
                    "", app_id, action_id);
            }
            view.navigate_to("keyboard");
        }
    }
}
