using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class SettingsSubpages : Object {
        private unowned SettingsView view;
        private unowned SettingsPage parent;
        private string parent_name;

        public SettingsSubpages(SettingsView view, SettingsPage parent, string parent_name) {
            this.view = view;
            this.parent = parent;
            this.parent_name = parent_name;
        }

        public SettingsPage create(string title) {
            var page = new SettingsPage(title);
            page.back_btn.visible = true;
            page.back_clicked.connect(() => view.navigate_to(parent_name));
            return page;
        }

        public ActionRow link(string title, string subtitle, string icon_name, SettingsPage page, string page_name) {
            var row = new ActionRow(title, subtitle, icon_name != "" ? icon_name : null);
            row.activatable = true;
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.add_css_class("dim-label");
            chevron.valign = Align.CENTER;
            row.add_suffix(chevron);
            row.activated.connect(() => view.open_subpage(page, page_name));
            index(page, page_name);
            return row;
        }

        public void index(SettingsPage page, string page_name) {
            foreach (var group_widget in page.get_groups()) {
                var group = group_widget as PreferencesGroup;
                if (group == null) continue;
                foreach (var row_widget in group.get_rows()) {
                    var row = row_widget as ActionRow;
                    if (row == null) {
                        string? custom_title = row_widget.get_data<string>("settings-title");
                        if (custom_title != null) search_target(custom_title, "", page, page_name, row_widget);
                        continue;
                    }
                    if (row.title == "") continue;
                    Widget target = row;
                    parent.add_search_action(row.title, row.subtitle, () => open(page, page_name, target));
                }
            }
        }

        public void search_target(string title, string subtitle, SettingsPage page, string page_name, Widget target) {
            parent.add_search_action(title, subtitle, () => open(page, page_name, target));
        }

        private void open(SettingsPage page, string page_name, Widget target) {
            view.open_subpage(page, page_name);
            Timeout.add(250, () => {
                if (!target.get_mapped()) return Source.REMOVE;
                Graphene.Point point;
                if (target.compute_point(page.content_box, Graphene.Point() { x = 0, y = 0 }, out point)) {
                    var adjustment = page.scroller.vadjustment;
                    adjustment.value = double.min(double.max(point.y - 24, adjustment.lower),
                        adjustment.upper - adjustment.page_size);
                }
                target.add_css_class("settings-highlight");
                Timeout.add(1600, () => {
                    target.remove_css_class("settings-highlight");
                    return Source.REMOVE;
                });
                return Source.REMOVE;
            });
        }
    }
}
