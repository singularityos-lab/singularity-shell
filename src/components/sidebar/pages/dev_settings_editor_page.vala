using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DevSettingsEditorPage : SettingsPage {
        private SettingsView view;
        private PreferencesGroup group;
        private Gee.ArrayList<ActionRow> rows = new Gee.ArrayList<ActionRow> ();
        private StatusPage empty;

        public DevSettingsEditorPage (SettingsView view) {
            base (_("Settings Editor"));
            this.view = view;
            back_btn.visible = true;
            back_clicked.connect (() => view.navigate_to ("developer"));

            var search = new Singularity.Widgets.SearchEntry ();
            search.placeholder_text = _("Search schemas and keys...");
            search.margin_bottom = 8;
            add_widget (search);

            group = new PreferencesGroup (_("Schemas"));
            group.description = _("Every setting installed on this system, grouped by schema.");
            add_group (group);
            empty = new StatusPage ();
            empty.icon_name = "system-search";
            empty.title = _("No Schemas Found");
            empty.description = _("No schema or key matches the search.");
            var clear = new Button.with_label (_("Clear Search"));
            clear.halign = Align.CENTER;
            clear.add_css_class ("pill");
            clear.add_css_class ("suggested-action");
            clear.clicked.connect (() => search.text = "");
            empty.child = clear;
            empty.visible = false;
            add_widget (empty);

            var source = SettingsSchemaSource.get_default ();
            string[] non_relocatable, relocatable;
            source.list_schemas (true, out non_relocatable, out relocatable);
            var ids = new Gee.ArrayList<string> ();
            foreach (string id in non_relocatable) ids.add (id);
            ids.sort ((a, b) => strcmp (a, b));
            foreach (string id in ids) {
                var schema = source.lookup (id, true);
                if (schema == null) continue;
                string[] keys = schema.list_keys ();
                var row = new ActionRow (id, ngettext ("%d key", "%d keys", keys.length).printf (keys.length));
                row.set_data<string> ("haystack", (id + " " + string.joinv (" ", keys)).down ());
                var go = new Button.from_icon_name ("go-next-symbolic");
                go.add_css_class ("flat");
                go.valign = Align.CENTER;
                string captured = id;
                go.clicked.connect (() => open_schema (captured));
                row.add_suffix (go);
                row.activated.connect (() => open_schema (captured));
                group.add_row (row);
                rows.add (row);
            }
            search.search_changed.connect (() => {
                string q = search.text.strip ().down ();
                int shown = 0;
                foreach (var r in rows) {
                    bool match = q == "" || r.get_data<string> ("haystack").contains (q);
                    r.visible = match;
                    if (match) shown++;
                }
                empty.visible = shown == 0;
                group.visible = shown > 0;
            });
        }

        private void open_schema (string id) {
            view.open_subpage (new DevSchemaPage (view, id), "dev-schema");
        }
    }

    public class DevSchemaPage : SettingsPage {
        private GLib.Settings settings;
        private SettingsSchema schema;
        private Gee.HashMap<string, Widget> editors = new Gee.HashMap<string, Widget> ();
        private Gee.HashMap<string, Button> resets = new Gee.HashMap<string, Button> ();
        private bool syncing;

        public DevSchemaPage (SettingsView view, string id) {
            base (id);
            back_btn.visible = true;
            back_clicked.connect (() => view.open_subpage (new DevSettingsEditorPage (view), "dev-settings-editor"));
            schema = SettingsSchemaSource.get_default ().lookup (id, true);
            settings = new GLib.Settings (id);

            var group = new PreferencesGroup (_("Keys"));
            group.description = schema.get_path () != null ? schema.get_path () : "";
            add_group (group);
            string[] keys = schema.list_keys ();
            var sorted = new Gee.ArrayList<string> ();
            foreach (string k in keys) sorted.add (k);
            sorted.sort ((a, b) => strcmp (a, b));
            foreach (string key in sorted) group.add_row (build_row (key));

            settings.changed.connect ((key) => sync (key));
        }

        private Widget build_row (string key) {
            var info = schema.get_key (key);
            string summary = info.get_summary () ?? "";
            string type = info.get_value_type ().dup_string ();
            var row = new ActionRow (key, summary != "" ? summary : type);
            string description = info.get_description () ?? "";
            row.tooltip_text = "%s\n%s: %s%s".printf (type, _("Default"), info.get_default_value ().print (false),
                description != "" ? "\n\n" + description : "");

            Widget editor = make_editor (key, info, type);
            editor.valign = Align.CENTER;
            row.add_suffix (editor);
            editors[key] = editor;

            var reset = new Button.from_icon_name ("edit-undo-symbolic");
            reset.add_css_class ("flat");
            reset.valign = Align.CENTER;
            reset.tooltip_text = _("Reset to Default");
            reset.clicked.connect (() => settings.reset (key));
            row.add_suffix (reset);
            resets[key] = reset;
            sync (key);
            return row;
        }

        private Widget make_editor (string key, SettingsSchemaKey info, string type) {
            var range = info.get_range ();
            string range_type;
            Variant range_value;
            range.get ("(sv)", out range_type, out range_value);
            if (type == "b") {
                var sw = new Switch ();
                sw.notify["active"].connect (() => {
                    if (!syncing) settings.set_boolean (key, sw.active);
                });
                return sw;
            }
            if (range_type == "enum" || (type == "s" && range_type == "enum")) {
                var choices = new StringList (null);
                var iter = range_value.iterator ();
                Variant? v;
                while ((v = iter.next_value ()) != null) choices.append (v.get_string ());
                var dd = new DropDown (choices, null);
                dd.notify["selected"].connect (() => {
                    if (syncing) return;
                    var item = dd.selected_item as StringObject;
                    if (item != null) settings.set_value (key, new Variant.string (item.string));
                });
                return dd;
            }
            if (type == "i" || type == "u" || type == "x" || type == "t" || type == "d" || type == "q" || type == "n" || type == "y") {
                double lo = -1e9, hi = 1e9;
                if (range_type == "range") {
                    lo = number_of (range_value.get_child_value (0));
                    hi = number_of (range_value.get_child_value (1));
                } else if (type == "u" || type == "t" || type == "q" || type == "y") {
                    lo = 0;
                }
                var spin = new SpinButton.with_range (lo, hi, type == "d" ? 0.1 : 1);
                spin.digits = type == "d" ? 2 : 0;
                spin.value_changed.connect (() => {
                    if (syncing) return;
                    settings.set_value (key, number_variant (type, spin.value));
                });
                return spin;
            }
            var entry = new Entry ();
            entry.width_chars = 22;
            entry.hexpand = false;
            entry.activate.connect (() => {
                try {
                    Variant v;
                    if (type == "s") v = new Variant.string (entry.text);
                    else v = Variant.parse (new VariantType (type), entry.text);
                    if (!settings.set_value (key, v)) throw new IOError.INVALID_ARGUMENT (_("Value out of range"));
                    entry.remove_css_class ("error");
                } catch (Error e) {
                    entry.add_css_class ("error");
                    entry.tooltip_text = e.message;
                }
            });
            return entry;
        }

        private static double number_of (Variant v) {
            switch (v.get_type_string ()) {
                case "i": return v.get_int32 ();
                case "u": return v.get_uint32 ();
                case "x": return v.get_int64 ();
                case "t": return v.get_uint64 ();
                case "d": return v.get_double ();
                case "n": return v.get_int16 ();
                case "q": return v.get_uint16 ();
                case "y": return v.get_byte ();
                default: return 0;
            }
        }

        private static Variant number_variant (string type, double value) {
            switch (type) {
                case "i": return new Variant.int32 ((int32) value);
                case "u": return new Variant.uint32 ((uint32) value);
                case "x": return new Variant.int64 ((int64) value);
                case "t": return new Variant.uint64 ((uint64) value);
                case "n": return new Variant.int16 ((int16) value);
                case "q": return new Variant.uint16 ((uint16) value);
                case "y": return new Variant.byte ((uint8) value);
                default: return new Variant.double (value);
            }
        }

        private void sync (string key) {
            if (!editors.has_key (key)) return;
            syncing = true;
            var value = settings.get_value (key);
            var editor = editors[key];
            if (editor is Switch) {
                ((Switch) editor).active = value.get_boolean ();
            } else if (editor is DropDown) {
                var dd = (DropDown) editor;
                var model = (StringList) dd.model;
                string current = value.is_of_type (VariantType.STRING) ? value.get_string () : value.print (false);
                for (uint i = 0; i < model.get_n_items (); i++) {
                    if (model.get_string (i) == current) dd.selected = i;
                }
            } else if (editor is SpinButton) {
                ((SpinButton) editor).value = number_of (value);
            } else if (editor is Entry) {
                ((Entry) editor).text = value.is_of_type (VariantType.STRING) ? value.get_string () : value.print (false);
            }
            resets[key].sensitive = settings.get_user_value (key) != null;
            syncing = false;
        }
    }
}
