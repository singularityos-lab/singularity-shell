using Gtk;
using Peas;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PluginDetailsPage : SettingsPage {
        private SingularityApp app;
        private Peas.PluginInfo info;
        private PluginManager manager;

        public PluginDetailsPage(SingularityApp app, Peas.PluginInfo info) {
            base(info.get_name());
            this.app = app;
            this.info = info;
            this.manager = PluginManager.get_default();

            back_clicked.connect(() => app.open_settings_page("plugins"));

            build_info_section();
            build_settings_section();
        }

        private void build_info_section() {
            var group = new PreferencesGroup();
            var row = new PreferencesRow();
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 12;
            box.margin_end = 12;

            // Use generic plugin icon as plugins might not have icons
            // Or use "extension-symbolic" or similar
            var icon_name = "application-x-addon";
            var icon = new Image.from_icon_name(icon_name);
            icon.pixel_size = 64;
            box.append(icon);

            var vbox = new Box(Orientation.VERTICAL, 4);
            vbox.valign = Align.CENTER;

            var name_lbl = new Label(info.get_name());
            name_lbl.add_css_class("title");
            name_lbl.halign = Align.START;
            name_lbl.ellipsize = Pango.EllipsizeMode.END;
            name_lbl.max_width_chars = 30;
            vbox.append(name_lbl);

            var version = info.get_version();
            var authors = info.get_authors();
            var author = (authors != null && authors.length > 0) ? authors[0] : null;
            var subtitle_text = "Version %s".printf(version ?? "Unknown");
            if (author != null) subtitle_text += " • %s".printf(author);

            var subtitle = new Label(subtitle_text);
            subtitle.add_css_class("subtitle");
            subtitle.halign = Align.START;
            vbox.append(subtitle);

            var desc_text = info.get_description();
            if (desc_text != null) {
                var desc = new Label(desc_text);
                desc.wrap = true;
                desc.xalign = 0f;
                desc.margin_top = 8;
                vbox.append(desc);
            }

            box.append(vbox);
            row.set_child(box);
            group.add_row(row);
            add_group(group);
        }

        private void build_settings_section() {
            if (!manager.is_plugin_enabled(info.get_module_name())) {
                 var group = new PreferencesGroup(_("Status"));
                 var row = new ActionRow(_("Plugin is disabled"));
                 var btn = new Button.with_label(_("Enable"));
                 btn.valign = Align.CENTER;
                 btn.clicked.connect(() => {
                     manager.set_plugin_enabled(info.get_module_name(), true);
                     app.open_settings_page("plugins");
                 });
                 row.add_suffix(btn);
                 group.add_row(row);
                 add_group(group);
                 return;
            }

            // Add Disable button
            var group_status = new PreferencesGroup(_("Status"));
            var row_status = new ActionRow(_("Plugin is enabled"));
            var btn_disable = new Button.with_label(_("Disable"));
            btn_disable.valign = Align.CENTER;
            btn_disable.add_css_class("destructive-action");
            btn_disable.clicked.connect(() => {
                 manager.set_plugin_enabled(info.get_module_name(), false);
                 app.open_settings_page("plugins");
            });
            row_status.add_suffix(btn_disable);
            group_status.add_row(row_status);
            add_group(group_status);

            var widget = manager.get_plugin_settings_widget(info.get_module_name());
            if (widget != null) {
                var group = new PreferencesGroup(_("Settings"));
                var row = new PreferencesRow();
                // We need to wrap the widget nicely if it's not a row itself
                // Usually plugins might return a Box.
                // Let's just add it as a child of the row.
                // Or if it's a box of simple controls, we might want to let it fill the row.

                // Add some margin
                widget.margin_start = 12;
                widget.margin_end = 12;
                widget.margin_top = 12;
                widget.margin_bottom = 12;

                row.set_child(widget);
                group.add_row(row);
                add_group(group);
            } else {
                var group = new PreferencesGroup(_("Settings"));
                var row = new ActionRow(_("No settings available"));
                group.add_row(row);
                add_group(group);
            }
        }
    }
}
