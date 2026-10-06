using GLib;
using Dbusmenu;

namespace Singularity {

    public class DBusMenuAdapter : MenuModel {
        private Dbusmenu.Client client;
        private Dbusmenu.Menuitem? item;
        private unowned List<Dbusmenu.Menuitem> children;
        private bool is_root;

        public DBusMenuAdapter(Dbusmenu.Client client, Dbusmenu.Menuitem? item, bool is_root = false) {
            this.client = client;
            this.item = item;
            this.is_root = is_root;

            if (item != null) {
                update_children();
                item.child_added.connect(on_child_added);
                item.child_moved.connect(on_child_moved);
                item.child_removed.connect(on_child_removed);
                item.property_changed.connect(on_property_changed);
                // Apps such as Firefox populate a submenu's children lazily, only
                // after they receive an aboutToShow. This adapter only ever wraps
                // a submenu (the root wraps the menubar), so always request it;
                // without it the submenu stays empty and clicking File/Edit/View
                // does nothing (#82, #112).
                if (!is_root) {
                    item.send_about_to_show(null, null);
                }
            }

            if (is_root) {
                 client.layout_updated.connect(on_layout_updated);
            }
        }

        // A menu item is a submenu when it advertises child-display "submenu",
        // or already carries children. The property holds even before the app
        // has sent the children, so it is the reliable discriminator.
        private static bool is_submenu(Dbusmenu.Menuitem mi) {
            string disp = mi.property_get(Dbusmenu.MENUITEM_PROP_CHILD_DISPLAY);
            if (disp == Dbusmenu.MENUITEM_CHILD_DISPLAY_SUBMENU) return true;
            unowned List<Dbusmenu.Menuitem> ch = mi.get_children();
            return ch != null && ch.length() > 0;
        }

        private void update_children() {
            if (item != null) {
                children = item.get_children();
            } else {
                children = null;
            }
        }

        private void on_child_added(Dbusmenu.Menuitem item, GLib.Object child, uint position) {
            update_children();
            items_changed((int)position, 0, 1);
        }

        private void on_child_removed(Dbusmenu.Menuitem item, GLib.Object child) {
            int old_n = get_n_items() + 1;
            update_children();
            items_changed(0, old_n, get_n_items());
        }

        private void on_child_moved(Dbusmenu.Menuitem item, GLib.Object child, uint newpos, uint oldpos) {
            update_children();
            items_changed(0, get_n_items(), get_n_items());
        }

        private void on_property_changed(string prop, Variant val) {
            // A visible/label/enabled property changed on one of our children -
            // signal a full refresh so menu consumers re-read all item attributes.
            items_changed(0, get_n_items(), get_n_items());
        }

        private void on_layout_updated(Dbusmenu.Client client) {
            if (item == null) {
                item = client.get_root();
                if (item != null) {
                    item.child_added.connect(on_child_added);
                    item.child_moved.connect(on_child_moved);
                    item.child_removed.connect(on_child_removed);
                    item.property_changed.connect(on_property_changed);
                }
            }
            update_children();
            items_changed(0, get_n_items(), get_n_items());
        }

        public static string? shortcut_to_accel(Variant? shortcut) {
            if (shortcut == null || !shortcut.is_of_type(new VariantType("aas")) || shortcut.n_children() == 0) return null;
            var first = shortcut.get_child_value(0);
            var accel = new StringBuilder();
            string key = "";
            for (size_t i = 0; i < first.n_children(); i++) {
                string part = first.get_child_value(i).get_string();
                switch (part) {
                    case "Control": accel.append("<Control>"); break;
                    case "Alt": accel.append("<Alt>"); break;
                    case "Shift": accel.append("<Shift>"); break;
                    case "Super": accel.append("<Super>"); break;
                    default: key = part; break;
                }
            }
            if (key == "") return null;
            accel.append(key);
            return accel.str;
        }

        public override int get_n_items() {
            return (int) (children != null ? children.length() : 0);
        }

        public override Variant? get_item_attribute_value(int item_index, string attribute, VariantType? expected_type) {
             if (children == null || item_index < 0 || item_index >= children.length()) return null;
             var child = children.nth_data(item_index);

             if (attribute == "label") {
                 string val = child.property_get(Dbusmenu.MENUITEM_PROP_LABEL);
                 return new Variant.string(val ?? "");
             }
             // Submenu parents (File, Edit, ...) must expose only the submenu
             // link, never an action: a GMenu item carrying both confuses GTK
             // into activating the parent instead of opening the submenu (#82).
             if (attribute == "action") {
                 if (is_root || is_submenu(child)) return null;
                 return new Variant.string("dbusmenu.activate");
             }
             if (attribute == "target") {
                 if (is_root || is_submenu(child)) return null;
                 return new Variant.int32(child.get_id());
             }
             if (attribute == "enabled") {
                 bool enabled = child.property_get_bool(Dbusmenu.MENUITEM_PROP_ENABLED);
                 return new Variant.boolean(enabled);
             }
             if (attribute == "accel") {
                 if (is_root || is_submenu(child)) return null;
                 string? accel = shortcut_to_accel(child.property_get_variant("shortcut"));
                 return accel != null ? new Variant.string(accel) : null;
             }
             if (attribute == "visible") {
                 bool visible = child.property_get_bool(Dbusmenu.MENUITEM_PROP_VISIBLE);
                 return new Variant.boolean(visible);
             }
             return null;
        }

        public override MenuModel? get_item_link(int item_index, string link) {
             if (link != "submenu") return null;
             if (children == null || item_index < 0 || item_index >= children.length()) return null;

             var child = children.nth_data(item_index);
             // The root wraps the menubar, so every direct child is a menu (its
             // children load lazily, so neither the hint nor a child count is
             // reliable here). Below the root, fall back to the submenu hint.
             if (!is_root && !is_submenu(child)) return null;

             return new DBusMenuAdapter(client, child, false);
        }
    }
}
