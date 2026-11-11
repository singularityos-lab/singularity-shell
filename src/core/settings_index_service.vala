using Gtk;

namespace Singularity.Shell {

    [DBus (name = "dev.sinty.Shell.SettingsIndex")]
    public class SettingsIndexService : Object {
        private unowned SingularityApp app;

        [DBus (visible = false)]
        public SettingsIndexService(SingularityApp app) {
            this.app = app;
        }

        public async string entries() throws Error {
            yield app.warm_settings_index();
            var b = new Json.Builder();
            b.begin_array();
            foreach (var e in app.settings_entries()) {
                b.begin_object();
                b.set_member_name("page");
                b.add_string_value(e.page_name ?? "");
                b.set_member_name("page_title");
                b.add_string_value(e.page_title ?? "");
                b.set_member_name("title");
                b.add_string_value(e.title ?? "");
                b.set_member_name("subtitle");
                b.add_string_value(e.subtitle ?? "");
                b.set_member_name("group");
                b.add_string_value(e.group ?? "");
                b.set_member_name("kind");
                b.add_string_value(e.kind.to_string().replace("SINGULARITY_SETTINGS_ENTRY_KIND_", "").down());
                var sw = e.toggle();
                b.set_member_name("state");
                b.add_string_value(sw == null ? "" : (sw.active ? "on" : "off"));
                b.end_object();
            }
            b.end_array();
            var g = new Json.Generator();
            g.root = b.get_root();
            return g.to_data(null);
        }

        public async string set_switch(string page, string title, bool on) throws Error {
            yield app.warm_settings_index();
            foreach (var e in app.settings_entries()) {
                if (e.page_name != page || e.title != title) continue;
                var sw = e.toggle();
                if (sw == null) throw new IOError.NOT_SUPPORTED("this row is not a switch; open it with its page instead");
                if (!sw.sensitive) throw new IOError.PERMISSION_DENIED("this switch cannot be changed right now");
                bool was = sw.active;
                sw.active = on;
                return "{\"was\":%s,\"now\":%s}".printf(was ? "true" : "false", sw.active ? "true" : "false");
            }
            throw new IOError.NOT_FOUND("no row with that title on that page");
        }

        private Singularity.SettingsEntry? find_entry(string page, string title) {
            foreach (var e in app.settings_entries()) {
                if (e.page_name == page && e.title == title) return e;
            }
            return null;
        }

        private static bool secret(string title, Widget ctl) {
            if (ctl is PasswordEntry) return true;
            var en = ctl as Entry;
            if (en != null && !en.visibility) return true;
            string t = title.down();
            foreach (unowned string word in new string[] { "password", "passphrase", "passcode", "secret", "token", "private key" }) {
                if (t.contains(word)) return true;
            }
            foreach (unowned string w in t.split_set(" -_/()")) {
                if (w == "pin") return true;
            }
            return false;
        }

        private static Widget? find_control(Widget root) {
            if (root is Singularity.Widgets.SelectionRow) return root;
            if (root is Switch || root is SpinButton || root is Scale || root is Singularity.Widgets.ChoiceButton
                || root is DropDown || root is PasswordEntry || root is Entry) return root;
            for (Widget? c = root.get_first_child(); c != null; c = c.get_next_sibling()) {
                var hit = find_control(c);
                if (hit != null) return hit;
            }
            return null;
        }

        private static string item_label(Object? item, Gtk.Expression? expr) {
            if (item == null) return "";
            var so = item as StringObject;
            if (so != null) return so.string;
            if (expr != null) {
                var v = Value(typeof(string));
                if (expr.evaluate(item, ref v)) return v.get_string() ?? "";
            }
            foreach (unowned string name in new string[] { "label", "title", "name", "display-name", "string" }) {
                var spec = item.get_class().find_property(name);
                if (spec == null || spec.value_type != typeof(string)) continue;
                var v = Value(typeof(string));
                item.get_property(name, ref v);
                if (v.get_string() != null && v.get_string() != "") return v.get_string();
            }
            return "";
        }

        private static string[] model_labels(ListModel? model, Gtk.Expression? expr) {
            string[] out_labels = {};
            if (model == null) return out_labels;
            for (uint i = 0; i < model.get_n_items() && i < 200; i++) out_labels += item_label(model.get_item(i), expr);
            return out_labels;
        }

        private static void collect_row_labels(Widget w, GenericArray<string> labels) {
            var row = w as ListBoxRow;
            if (row != null) {
                var l = first_label(row);
                if (l != null && l != "") labels.add(l);
                return;
            }
            for (Widget? c = w.get_first_child(); c != null; c = c.get_next_sibling()) collect_row_labels(c, labels);
        }

        private static string? first_label(Widget w) {
            var l = w as Label;
            if (l != null && l.label != "") return l.label;
            for (Widget? c = w.get_first_child(); c != null; c = c.get_next_sibling()) {
                var hit = first_label(c);
                if (hit != null) return hit;
            }
            return null;
        }

        private static string[] selection_labels(Singularity.Widgets.SelectionRow row) {
            var found = read_selection_labels(row);
            if (found.length > 0 || row.expanded) return found;
            row.expanded = true;
            found = read_selection_labels(row);
            row.expanded = false;
            return found;
        }

        private static string[] read_selection_labels(Singularity.Widgets.SelectionRow row) {
            var labels = new GenericArray<string>();
            for (Widget? c = row.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (c is ListBox || c.get_first_child() != null) collect_row_labels(c, labels);
            }
            string[] clean = {};
            foreach (var l in labels.data) if (l != row.title && !(l in clean)) clean += l;
            return clean;
        }

        private static void describe_control(Widget ctl, Json.Builder b) {
            b.set_member_name("control");
            if (ctl is Switch) {
                b.add_string_value("switch");
                b.set_member_name("value");
                b.add_boolean_value(((Switch) ctl).active);
            } else if (ctl is SpinButton) {
                var sp = (SpinButton) ctl;
                b.add_string_value("number");
                b.set_member_name("value");
                b.add_double_value(sp.value);
                b.set_member_name("min");
                b.add_double_value(sp.adjustment.lower);
                b.set_member_name("max");
                b.add_double_value(sp.adjustment.upper);
            } else if (ctl is Scale) {
                var sc = (Scale) ctl;
                b.add_string_value("slider");
                b.set_member_name("value");
                b.add_double_value(sc.adjustment.value);
                b.set_member_name("min");
                b.add_double_value(sc.adjustment.lower);
                b.set_member_name("max");
                b.add_double_value(sc.adjustment.upper);
            } else if (ctl is Singularity.Widgets.ChoiceButton || ctl is DropDown) {
                ListModel? model;
                Gtk.Expression? expr;
                uint sel;
                if (ctl is DropDown) {
                    var dd = (DropDown) ctl;
                    model = dd.model;
                    expr = dd.expression;
                    sel = dd.selected;
                } else {
                    var cb = (Singularity.Widgets.ChoiceButton) ctl;
                    model = cb.model;
                    expr = cb.expression;
                    sel = cb.selected;
                }
                var labels = model_labels(model, expr);
                b.add_string_value("choice");
                b.set_member_name("value");
                b.add_string_value(sel < labels.length ? labels[sel] : "");
                b.set_member_name("options");
                b.begin_array();
                foreach (var l in labels) b.add_string_value(l);
                b.end_array();
            } else if (ctl is Singularity.Widgets.SelectionRow) {
                var sr = (Singularity.Widgets.SelectionRow) ctl;
                b.add_string_value("choice");
                b.set_member_name("value");
                b.add_string_value(sr.current_value ?? "");
                b.set_member_name("options");
                b.begin_array();
                foreach (var l in selection_labels(sr)) b.add_string_value(l);
                b.end_array();
            } else {
                b.add_string_value("text");
                b.set_member_name("value");
                b.add_string_value(((Entry) ctl).text);
            }
        }

        public async string describe(string page, string title) throws Error {
            yield app.warm_settings_index();
            var e = find_entry(page, title);
            if (e == null) throw new IOError.NOT_FOUND("no row with that title on that page");
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("page");
            b.add_string_value(page);
            b.set_member_name("title");
            b.add_string_value(title);
            var ctl = e.widget != null ? find_control(e.widget) : null;
            if (ctl == null) {
                b.set_member_name("control");
                b.add_string_value(e.kind == Singularity.SettingsEntryKind.LAUNCH ? "page" : "none");
            } else {
                b.set_member_name("enabled");
                b.add_boolean_value(ctl.sensitive);
                if (secret(title, ctl)) {
                    b.set_member_name("control");
                    b.add_string_value("password");
                } else {
                    describe_control(ctl, b);
                }
            }
            b.end_object();
            var g = new Json.Generator();
            g.root = b.get_root();
            return g.to_data(null);
        }

        private static string quoted(string v) {
            var node = new Json.Node(Json.NodeType.VALUE);
            node.set_string(v);
            return Json.to_string(node, false);
        }

        public async string set_value(string page, string title, string value) throws Error {
            yield app.warm_settings_index();
            var e = find_entry(page, title);
            if (e == null) throw new IOError.NOT_FOUND("no row with that title on that page");
            var ctl = e.widget != null ? find_control(e.widget) : null;
            if (ctl == null) throw new IOError.NOT_SUPPORTED("this row has no control to set; open its page instead");
            if (!ctl.sensitive) throw new IOError.PERMISSION_DENIED("this control cannot be changed right now");
            if (secret(title, ctl)) throw new IOError.PERMISSION_DENIED("passwords are typed by the user, never by Sinty AI");
            if (ctl is Switch) {
                var sw = (Switch) ctl;
                bool was = sw.active;
                if (value != "true" && value != "false") throw new IOError.INVALID_ARGUMENT("a switch takes true or false");
                sw.active = value == "true";
                return "{\"was\":%s,\"now\":%s}".printf(was ? "true" : "false", sw.active ? "true" : "false");
            }
            if (ctl is SpinButton || ctl is Scale) {
                double d;
                if (!double.try_parse(value, out d)) throw new IOError.INVALID_ARGUMENT("this control takes a number");
                var adj = (ctl is SpinButton) ? ((SpinButton) ctl).adjustment : ((Scale) ctl).adjustment;
                if (d < adj.lower || d > adj.upper) throw new IOError.INVALID_ARGUMENT("the number is outside %g to %g".printf(adj.lower, adj.upper));
                double was = adj.value;
                if (ctl is SpinButton) ((SpinButton) ctl).value = d; else adj.value = d;
                return "{\"was\":%s,\"now\":%s}".printf(quoted("%g".printf(was)), quoted("%g".printf(adj.value)));
            }
            if (ctl is Singularity.Widgets.ChoiceButton || ctl is DropDown) {
                ListModel? model = (ctl is DropDown) ? ((DropDown) ctl).model : ((Singularity.Widgets.ChoiceButton) ctl).model;
                Gtk.Expression? expr = (ctl is DropDown) ? ((DropDown) ctl).expression : ((Singularity.Widgets.ChoiceButton) ctl).expression;
                var labels = model_labels(model, expr);
                uint cur = (ctl is DropDown) ? ((DropDown) ctl).selected : ((Singularity.Widgets.ChoiceButton) ctl).selected;
                for (uint i = 0; i < labels.length; i++) {
                    if (labels[i] != value) continue;
                    string was = cur < labels.length ? labels[cur] : "";
                    if (ctl is DropDown) ((DropDown) ctl).selected = i; else ((Singularity.Widgets.ChoiceButton) ctl).selected = i;
                    return "{\"was\":%s,\"now\":%s}".printf(quoted(was), quoted(value));
                }
                throw new IOError.INVALID_ARGUMENT("not one of the options: %s".printf(string.joinv(", ", labels)));
            }
            if (ctl is Singularity.Widgets.SelectionRow) {
                var sr = (Singularity.Widgets.SelectionRow) ctl;
                var labels = selection_labels(sr);
                for (int i = 0; i < labels.length; i++) {
                    if (labels[i] != value) continue;
                    string was = sr.current_value ?? "";
                    sr.selected_index = i;
                    sr.selected(sr.current_value);
                    return "{\"was\":%s,\"now\":%s}".printf(quoted(was), quoted(sr.current_value ?? value));
                }
                throw new IOError.INVALID_ARGUMENT("not one of the options: %s".printf(string.joinv(", ", labels)));
            }
            var en = (Entry) ctl;
            string was = en.text;
            en.text = value;
            en.activate();
            return "{\"was\":%s,\"now\":%s}".printf(quoted(was), quoted(en.text));
        }

        public void open(string page, string row) throws Error {
            if (page == "" || page.index_of_char('#') >= 0) throw new IOError.INVALID_ARGUMENT("bad page");
            string target = row == "" ? page : page + "#" + row;
            Idle.add(() => {
                app.open_settings_page(target);
                return false;
            });
        }
    }
}
