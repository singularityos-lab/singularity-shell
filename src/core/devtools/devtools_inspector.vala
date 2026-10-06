using Gtk;

namespace Singularity {

    public class DevtoolsInspector : Object {

        public static void build_settings (Box dest, string schema_id, string[] prefixes) {
            var src = GLib.SettingsSchemaSource.get_default ();
            if (src == null) { add_note (dest, "no schema source"); return; }
            var schema = src.lookup (schema_id, true);
            if (schema == null) { add_note (dest, "schema %s not found".printf (schema_id)); return; }

            var settings = new GLib.Settings (schema_id);
            string[] keys = schema.list_keys ();
            GLib.qsort_with_data<string> (keys, sizeof (string), (a, b) => GLib.strcmp (a, b));

            int shown = 0;
            foreach (string key in keys) {
                if (!matches_prefix (key, prefixes)) continue;
                var skey = schema.get_key (key);
                string t = skey.get_value_type ().dup_string ();
                if (t.has_prefix ("a")) continue;

                Widget? control = null;
                if (t == "b") {
                    control = bool_control (settings, key);
                } else if (t == "i") {
                    control = int_control (settings, skey, key);
                } else if (t == "d") {
                    control = double_control (settings, skey, key);
                } else if (t == "s") {
                    string[]? choices = string_choices (key);
                    control = (choices != null)
                        ? enum_control (settings, key, choices)
                        : string_control (settings, key);
                }
                if (control == null) continue;

                dest.append (make_row (key, control));
                shown++;
            }
            if (shown == 0) add_note (dest, "no tunable keys");
        }

        public static void build_widget_tree (Box dest, Gtk.Application app) {
            var roots = new GLib.GenericArray<Widget> ();
            foreach (var win in app.get_windows ()) {
                if (win.get_type ().name ().has_prefix ("SingularityDevtools")) continue;
                if (win.get_type ().name () == "SingularityDebugHudWindow") continue;
                collect_singularity (win, roots);
            }
            if (roots.length == 0) { add_note (dest, "no Singularity widgets mapped"); return; }

            for (int i = 0; i < roots.length; i++) {
                var w = roots.get (i);
                var exp = new Expander (type_label (w));
                exp.add_css_class ("devtools-tree-root");
                var holder = new Box (Orientation.VERTICAL, 2);
                holder.margin_start = 10;
                holder.append (outline_row (w, 0, true));
                build_subtree (holder, w, 1);
                exp.set_child (holder);
                dest.append (exp);
            }
        }

        private static void build_subtree (Box dest, Widget parent, int depth) {
            Widget? child = parent.get_first_child ();
            while (child != null) {
                bool nested = child.get_type ().name ().has_prefix ("Singularity");
                dest.append (outline_row (child, depth, nested));
                if (!nested) build_subtree (dest, child, depth + 1);
                child = child.get_next_sibling ();
            }
        }

        private static Widget outline_row (Widget target, int depth, bool accent) {
            var row = new Box (Orientation.HORIZONTAL, 6);
            row.margin_start = depth * 12;

            var chk = new CheckButton ();
            chk.add_css_class ("devtools-outline-check");
            chk.active = target.has_css_class ("devtools-outline");
            chk.toggled.connect (() => {
                if (chk.active) target.add_css_class ("devtools-outline");
                else target.remove_css_class ("devtools-outline");
            });
            row.append (chk);

            var lbl = new Label (type_label (target));
            lbl.add_css_class ("devtools-tree-node");
            if (accent) lbl.add_css_class ("devtools-tree-sing");
            lbl.halign = Align.START;
            lbl.xalign = 0;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.hexpand = true;
            row.append (lbl);
            return row;
        }

        private static void collect_singularity (Widget root, GLib.GenericArray<Widget> outv) {
            if (root.get_type ().name ().has_prefix ("Singularity"))
                outv.add (root);
            Widget? child = root.get_first_child ();
            while (child != null) {
                if (!child.get_type ().name ().has_prefix ("Singularity"))
                    collect_singularity (child, outv);
                else
                    outv.add (child);
                child = child.get_next_sibling ();
            }
        }

        private static string type_label (Widget w) {
            string name = w.get_type ().name ();
            string classes = string.joinv (".", w.get_css_classes ());
            if (classes.length > 0) return "%s .%s".printf (name, classes);
            return name;
        }

        private static Widget make_row (string key, Widget control) {
            var row = new Box (Orientation.HORIZONTAL, 8);
            row.add_css_class ("devtools-row");
            var lbl = new Label (key);
            lbl.add_css_class ("devtools-row-key");
            lbl.halign = Align.START;
            lbl.xalign = 0;
            lbl.hexpand = true;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            row.append (lbl);
            control.halign = Align.END;
            row.append (control);
            return row;
        }

        private static void add_note (Box dest, string text) {
            var lbl = new Label (text);
            lbl.add_css_class ("devtools-note");
            lbl.halign = Align.START;
            dest.append (lbl);
        }

        private static Widget bool_control (GLib.Settings settings, string key) {
            var sw = new Switch ();
            sw.valign = Align.CENTER;
            settings.bind (key, sw, "active", SettingsBindFlags.DEFAULT);
            return sw;
        }

        private static Widget int_control (GLib.Settings settings, GLib.SettingsSchemaKey skey, string key) {
            double lo = 0, hi = 200;
            range_bounds (skey, ref lo, ref hi);
            var scale = new Scale.with_range (Orientation.HORIZONTAL, lo, hi, 1);
            scale.width_request = 160;
            scale.draw_value = true;
            scale.value_pos = PositionType.LEFT;
            scale.digits = 0;
            scale.set_value (settings.get_int (key));
            scale.value_changed.connect (() => {
                int v = (int) scale.get_value ();
                if (v != settings.get_int (key)) settings.set_int (key, v);
            });
            settings.changed[key].connect (() => {
                if ((int) scale.get_value () != settings.get_int (key))
                    scale.set_value (settings.get_int (key));
            });
            return scale;
        }

        private static Widget double_control (GLib.Settings settings, GLib.SettingsSchemaKey skey, string key) {
            double lo = 0, hi = 1;
            range_bounds (skey, ref lo, ref hi);
            var scale = new Scale.with_range (Orientation.HORIZONTAL, lo, hi, (hi - lo) / 100.0);
            scale.width_request = 160;
            scale.draw_value = true;
            scale.value_pos = PositionType.LEFT;
            scale.digits = 2;
            scale.set_value (settings.get_double (key));
            scale.value_changed.connect (() => {
                double v = scale.get_value ();
                if (v != settings.get_double (key)) settings.set_double (key, v);
            });
            settings.changed[key].connect (() => {
                if (scale.get_value () != settings.get_double (key))
                    scale.set_value (settings.get_double (key));
            });
            return scale;
        }

        private static Widget string_control (GLib.Settings settings, string key) {
            var entry = new Entry ();
            entry.width_request = 160;
            entry.text = settings.get_string (key);
            entry.activate.connect (() => settings.set_string (key, entry.text));
            settings.changed[key].connect (() => {
                if (entry.text != settings.get_string (key)) entry.text = settings.get_string (key);
            });
            return entry;
        }

        private static Widget enum_control (GLib.Settings settings, string key, owned string[] choices) {
            var model = new StringList (choices);
            var dd = new DropDown (model, null);
            string cur = settings.get_string (key);
            for (uint i = 0; i < choices.length; i++)
                if (choices[i] == cur) { dd.selected = i; break; }
            dd.notify["selected"].connect (() => {
                if (dd.selected < choices.length) {
                    string v = choices[dd.selected];
                    if (v != settings.get_string (key)) settings.set_string (key, v);
                }
            });
            settings.changed[key].connect (() => {
                string v = settings.get_string (key);
                for (uint i = 0; i < choices.length; i++)
                    if (choices[i] == v && dd.selected != i) { dd.selected = i; break; }
            });
            return dd;
        }

        private static void range_bounds (GLib.SettingsSchemaKey skey, ref double lo, ref double hi) {
            var range = skey.get_range ();
            if (range == null) return;
            string rtype;
            Variant rval;
            range.get ("(sv)", out rtype, out rval);
            if (rtype == "range") {
                Variant vlo, vhi;
                rval.get ("(**)", out vlo, out vhi);
                lo = variant_to_double (vlo);
                hi = variant_to_double (vhi);
            }
        }

        private static double variant_to_double (Variant v) {
            string t = v.get_type_string ();
            if (t == "i") return (double) v.get_int32 ();
            if (t == "u") return (double) v.get_uint32 ();
            if (t == "x") return (double) v.get_int64 ();
            if (t == "d") return v.get_double ();
            if (t == "n") return (double) v.get_int16 ();
            if (t == "q") return (double) v.get_uint16 ();
            if (t == "y") return (double) v.get_byte ();
            return 0;
        }

        private static bool matches_prefix (string key, string[] prefixes) {
            if (prefixes.length == 0) return true;
            foreach (string p in prefixes)
                if (key.has_prefix (p)) return true;
            return false;
        }

        private static string[]? string_choices (string key) {
            switch (key) {
                case "dock-position":        return { "bottom", "left", "right" };
                case "dock-visibility-mode": return { "always", "overview-only" };
                case "dock-style":           return { "floating", "panel" };
                case "dock-alignment":       return { "start", "center", "end" };
                default:                     return null;
            }
        }
    }
}
