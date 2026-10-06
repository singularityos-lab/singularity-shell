using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DevDBusPage : SettingsPage {
        private SettingsView view;
        private BusType bus_type = BusType.SESSION;
        private PreferencesGroup names_group;
        private Gee.ArrayList<ActionRow> rows = new Gee.ArrayList<ActionRow> ();
        private Singularity.Widgets.SearchEntry search;
        private Switch unique_switch;

        public DevDBusPage (SettingsView view, BusType bus = BusType.SESSION) {
            base (_("D-Bus Inspector"));
            this.view = view;
            bus_type = bus;
            back_btn.visible = true;
            back_clicked.connect (() => view.navigate_to ("developer"));

            var bus_switch = new SegmentedControl ();
            bus_switch.add_option ("session", _("Session Bus"));
            bus_switch.add_option ("system", _("System Bus"));
            bus_switch.set_active (bus == BusType.SYSTEM ? "system" : "session");
            bus_switch.halign = Align.CENTER;
            bus_switch.margin_top = 4;
            bus_switch.margin_bottom = 8;
            bus_switch.selected.connect ((n) => {
                bus_type = n == "system" ? BusType.SYSTEM : BusType.SESSION;
                load.begin ();
            });
            add_widget (bus_switch);

            search = new Singularity.Widgets.SearchEntry ();
            search.placeholder_text = _("Filter names...");
            search.margin_bottom = 8;
            search.search_changed.connect (apply_filter);
            add_widget (search);

            var options = new PreferencesGroup ();
            var unique_row = new ActionRow (_("Show Unique Names"), _("Connections such as :1.42 that have no well-known name"));
            unique_switch = new Switch ();
            unique_switch.valign = Align.CENTER;
            unique_switch.notify["active"].connect (apply_filter);
            unique_row.add_suffix (unique_switch);
            options.add_row (unique_row);
            add_group (options);

            names_group = new PreferencesGroup (_("Names"));
            add_group (names_group);
            load.begin ();
        }

        private async void load () {
            foreach (var r in rows) names_group.remove_row (r);
            rows.clear ();
            try {
                var conn = yield Bus.get (bus_type);
                var reply = yield conn.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListNames", null, new VariantType ("(as)"), DBusCallFlags.NONE, -1);
                var activatable_reply = yield conn.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, new VariantType ("(as)"), DBusCallFlags.NONE, -1);
                var running = new Gee.HashSet<string> ();
                foreach (string n in reply.get_child_value (0).get_strv ()) running.add (n);
                var all = new Gee.TreeSet<string> ();
                all.add_all (running);
                foreach (string n in activatable_reply.get_child_value (0).get_strv ()) all.add (n);
                foreach (string name in all) {
                    bool active = running.contains (name);
                    var row = new ActionRow (name, active ? null : _("Not running, started on demand"));
                    row.set_data<bool> ("unique", name.has_prefix (":"));
                    var go = new Button.from_icon_name ("go-next-symbolic");
                    go.add_css_class ("flat");
                    go.valign = Align.CENTER;
                    string captured = name;
                    go.clicked.connect (() => open_name (captured));
                    row.add_suffix (go);
                    row.activated.connect (() => open_name (captured));
                    names_group.add_row (row);
                    rows.add (row);
                }
                names_group.description = ngettext ("%d name", "%d names", all.size).printf (all.size);
                apply_filter ();
            } catch (Error e) {
                names_group.description = e.message;
            }
        }

        private void apply_filter () {
            string q = search.text.strip ().down ();
            foreach (var r in rows) {
                bool unique = r.get_data<bool> ("unique");
                r.visible = (!unique || unique_switch.active) && (q == "" || r.title.down ().contains (q));
            }
        }

        private void open_name (string name) {
            view.open_subpage (new DevDBusNamePage (view, bus_type, name), "dev-dbus-name");
        }
    }

    public class DevDBusNamePage : SettingsPage {
        private const int MAX_OBJECTS = 300;
        private SettingsView view;
        private DBusConnection? conn;
        private BusType bus_type;
        private string name;
        private int visited;

        public DevDBusNamePage (SettingsView view, BusType bus_type, string name) {
            base (name);
            this.view = view;
            this.bus_type = bus_type;
            this.name = name;
            back_btn.visible = true;
            back_clicked.connect (() => view.open_subpage (new DevDBusPage (view, bus_type), "dev-dbus"));
            load.begin ();
        }

        private async void load () {
            var owner_group = new PreferencesGroup (_("Owner"));
            add_group (owner_group);
            try {
                conn = yield Bus.get (bus_type);
                var owner = yield conn.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "GetNameOwner", new Variant ("(s)", name), new VariantType ("(s)"), DBusCallFlags.NONE, -1);
                string unique = owner.get_child_value (0).get_string ();
                owner_group.add_row (new ActionRow (_("Unique Name"), unique));
                try {
                    var pid_reply = yield conn.call ("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        "GetConnectionUnixProcessID", new Variant ("(s)", name), new VariantType ("(u)"), DBusCallFlags.NONE, -1);
                    uint pid = pid_reply.get_child_value (0).get_uint32 ();
                    string cmdline = "";
                    try {
                        uint8[] raw;
                        FileUtils.get_data ("/proc/%u/cmdline".printf (pid), out raw);
                        for (int i = 0; i < raw.length; i++) if (raw[i] == 0) raw[i] = ' ';
                        raw += 0;
                        cmdline = ((string) raw).strip ();
                    } catch (Error e) {
                    }
                    owner_group.add_row (new ActionRow (_("Process"), "%u  %s".printf (pid, cmdline)));
                } catch (Error e) {
                }
            } catch (Error e) {
                owner_group.add_row (new ActionRow (_("Not Running"), e.message));
                if (conn == null) return;
            }
            visited = 0;
            yield walk ("/");
            if (visited == 0) {
                var none = new PreferencesGroup (_("Objects"));
                none.description = _("This service exports no introspectable objects.");
                add_group (none);
            }
        }

        private async void walk (string path) {
            if (visited >= MAX_OBJECTS) return;
            string xml;
            try {
                var reply = yield conn.call (name, path, "org.freedesktop.DBus.Introspectable", "Introspect",
                    null, new VariantType ("(s)"), DBusCallFlags.NONE, 5000);
                xml = reply.get_child_value (0).get_string ();
            } catch (Error e) {
                return;
            }
            DBusNodeInfo node;
            try {
                node = new DBusNodeInfo.for_xml (xml);
            } catch (Error e) {
                return;
            }
            var interesting = new Gee.ArrayList<DBusInterfaceInfo> ();
            foreach (var iface in node.interfaces) {
                if (iface.name.has_prefix ("org.freedesktop.DBus.")) continue;
                interesting.add (iface);
            }
            if (interesting.size > 0) {
                visited++;
                var group = new PreferencesGroup (path);
                foreach (var iface in interesting) group.add_row (interface_row (path, iface));
                add_group (group);
            }
            foreach (var child in node.nodes) {
                string child_path = path == "/" ? "/" + child.path : path + "/" + child.path;
                yield walk (child_path);
            }
        }

        private static string args_signature (DBusArgInfo[]? args) {
            if (args == null) return "";
            string[] parts = {};
            foreach (var a in args) parts += "%s %s".printf (a.signature, a.name ?? "");
            return string.joinv (", ", parts);
        }

        private Widget interface_row (string path, DBusInterfaceInfo iface) {
            int count = (iface.methods != null ? iface.methods.length : 0)
                + (iface.properties != null ? iface.properties.length : 0)
                + (iface.signals != null ? iface.signals.length : 0);
            var exp = new ExpanderRow (iface.name, ngettext ("%d member", "%d members", count).printf (count));
            if (iface.properties != null && iface.properties.length > 0) {
                var props = new Gee.HashMap<string, ActionRow> ();
                foreach (var p in iface.properties) {
                    string access = (p.flags & DBusPropertyInfoFlags.WRITABLE) != 0 ? _("read and write") : _("read only");
                    var row = new ActionRow (p.name, "%s, %s".printf (p.signature, access));
                    var value = new Label ("");
                    value.add_css_class ("dim-label");
                    value.ellipsize = Pango.EllipsizeMode.END;
                    value.max_width_chars = 28;
                    value.selectable = true;
                    row.add_suffix (value);
                    row.set_data<Label> ("value", value);
                    props[p.name] = row;
                    exp.add_row (row);
                }
                fetch_properties.begin (path, iface.name, props);
            }
            if (iface.methods != null) {
                foreach (var m in iface.methods) {
                    string sig = "(%s) %s (%s)".printf (args_signature (m.in_args), _("returns"), args_signature (m.out_args));
                    var row = new ActionRow (m.name + "()", sig);
                    var call = new Button.with_label (_("Call"));
                    call.add_css_class ("pill");
                    call.valign = Align.CENTER;
                    DBusMethodInfo method = m;
                    string iface_name = iface.name;
                    row.add_suffix (call);
                    exp.add_row (row);
                    var panel = call_panel (path, iface_name, method);
                    exp.add_row (panel);
                    call.clicked.connect (() => panel.reveal_child = !panel.reveal_child);
                }
            }
            if (iface.signals != null) {
                foreach (var s in iface.signals) {
                    exp.add_row (new ActionRow (s.name, _("signal (%s)").printf (args_signature (s.args))));
                }
            }
            return exp;
        }

        private async void fetch_properties (string path, string iface, Gee.HashMap<string, ActionRow> rows) {
            try {
                var reply = yield conn.call (name, path, "org.freedesktop.DBus.Properties", "GetAll",
                    new Variant ("(s)", iface), new VariantType ("(a{sv})"), DBusCallFlags.NONE, 5000);
                var dict = reply.get_child_value (0);
                var iter = dict.iterator ();
                string key;
                Variant val;
                while (iter.next ("{sv}", out key, out val)) {
                    if (!rows.has_key (key)) continue;
                    var label = rows[key].get_data<Label> ("value");
                    string text = val.print (false);
                    label.label = text;
                    label.tooltip_text = text;
                }
            } catch (Error e) {
            }
        }

        private Revealer call_panel (string path, string iface, DBusMethodInfo method) {
            string in_sig = "";
            if (method.in_args != null) foreach (var a in method.in_args) in_sig += a.signature;
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_start = 16;
            box.margin_end = 16;
            box.margin_top = 4;
            box.margin_bottom = 12;
            var hint = new Label (in_sig == "" ? _("This method takes no arguments.") : _("Arguments as a GVariant tuple of type (%s), for example (\"text\", 42).").printf (in_sig));
            hint.wrap = true;
            hint.xalign = 0;
            hint.add_css_class ("dim-label");
            box.append (hint);
            var line = new Box (Orientation.HORIZONTAL, 8);
            var entry = new Entry ();
            entry.hexpand = true;
            entry.visible = in_sig != "";
            line.append (entry);
            var run = new Button.with_label (_("Run"));
            run.add_css_class ("pill");
            run.add_css_class ("suggested-action");
            run.halign = in_sig == "" ? Align.START : Align.FILL;
            line.append (run);
            box.append (line);
            var result = new Label ("");
            result.wrap = true;
            result.wrap_mode = Pango.WrapMode.WORD_CHAR;
            result.selectable = true;
            result.xalign = 0;
            result.add_css_class ("monospace");
            result.visible = false;
            box.append (result);
            var revealer = new Revealer ();
            revealer.child = box;
            revealer.reveal_child = false;
            revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            run.clicked.connect (() => {
                Variant? args = null;
                try {
                    if (in_sig != "") args = Variant.parse (new VariantType ("(" + in_sig + ")"), entry.text);
                } catch (Error e) {
                    show_result (result, _("The arguments are not valid: %s").printf (e.message));
                    return;
                }
                run.sensitive = false;
                conn.call.begin (name, path, iface, method.name, args, null, DBusCallFlags.NONE, 15000, null, (o, res) => {
                    run.sensitive = true;
                    try {
                        show_result (result, conn.call.end (res).print (true));
                    } catch (Error e) {
                        show_result (result, e.message);
                    }
                });
            });
            entry.activate.connect (() => run.clicked ());
            revealer.notify["child-revealed"].connect (() => {
                if (!revealer.child_revealed) return;
                Graphene.Rect bounds;
                if (revealer.compute_bounds (content_box, out bounds)) {
                    scroller.vadjustment.clamp_page (bounds.origin.y, bounds.origin.y + bounds.size.height);
                }
                if (entry.visible) entry.grab_focus ();
            });
            return revealer;
        }

        private static void show_result (Label result, string text) {
            result.label = text;
            result.visible = true;
        }
    }
}
