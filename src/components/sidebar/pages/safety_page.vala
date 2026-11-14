using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class SafetyPage : SettingsPage {
        private Json.Object config = new Json.Object();
        private bool loading = true;
        private uint pending = 0;
        private SwitchRow enabled;
        private SelectionRow severity;
        private SelectionRow magnitude;
        private EntryRow country;
        private EntryRow places;
        private EntryRow position;
        private ActionRow sources;
        private ActionRow numbers;
        private EntryRow contact_name;
        private EntryRow contact_number;
        private EntryRow medical_name;
        private EntryRow blood;
        private EntryRow allergies;
        private EntryRow conditions;
        private EntryRow medication;
        private SwitchRow on_lock;

        private static Gee.ArrayList<Singularity.Core.AppSettingOption> options(string[,] items) {
            var out = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < items.length[0]; i++) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = items[i, 0];
                o.label = items[i, 1];
                out.add(o);
            }
            return out;
        }

        public SafetyPage(SettingsView view) {
            base(_("Safety"));
            var client = AegisClient.get_default();

            if (!client.available) {
                var missing = new StatusPage();
                missing.icon_name = "aegis-security";
                missing.title = _("Sinty Aegis Is Not Running");
                missing.description = _("Public alerts and the emergency screen need the Sinty Aegis service.");
                add_widget(missing);
                return;
            }

            var alerts = new PreferencesGroup(_("Public Alerts"),
                _("Official warnings and earthquakes for the place this computer is in. A danger turns the top bar red and stays for five minutes. Everything else is a quiet line in the top bar."));
            enabled = new SwitchRow(_("Follow Public Alerts"), _("From the authorities of your country and two earthquake catalogues"));
            enabled.switch_btn.notify["active"].connect(() => changed());
            alerts.add_row(enabled);
            severity = new SelectionRow.with_options(_("Show Alerts From"), options({
                { "1", _("Minor") }, { "2", _("Moderate") }, { "3", _("Severe") }, { "4", _("Extreme") }
            }), "2");
            severity.selected.connect((id) => changed());
            alerts.add_row(severity);
            magnitude = new SelectionRow.with_options(_("Earthquakes From Magnitude"), options({
                { "3", "3.0" }, { "3.5", "3.5" }, { "4", "4.0" }, { "4.5", "4.5" }, { "5", "5.0" }
            }), "3.5");
            magnitude.subtitle = _("Only earthquakes that can be felt where you are");
            magnitude.selected.connect((id) => changed());
            alerts.add_row(magnitude);
            sources = new ActionRow(_("Sources"), _("Looking for the authorities of your country"), "network-server-symbolic");
            alerts.add_row(sources);
            add_group(alerts);

            var place = new PreferencesGroup(_("Your Place"),
                _("Leave these empty to use the country and city of your time zone."));
            country = new EntryRow(_("Country"));
            country.placeholder_text = _("Two letters, like it or us");
            country.entry_changed.connect(() => changed());
            place.add_row(country);
            places = new EntryRow(_("Regions"));
            places.placeholder_text = _("Names used by your authority, separated by commas");
            places.entry_changed.connect(() => changed());
            place.add_row(places);
            position = new EntryRow(_("Position"));
            position.placeholder_text = _("Latitude and longitude, like 41.90, 12.50");
            position.entry_changed.connect(() => changed());
            place.add_row(position);
            add_group(place);

            var emergency = new PreferencesGroup(_("Emergency Call"),
                _("Shown on the emergency screen, which you can open from any alert."));
            numbers = new ActionRow(_("Emergency Numbers Here"), "", "call-start-symbolic");
            emergency.add_row(numbers);
            contact_name = new EntryRow(_("Emergency Contact"));
            contact_name.entry_changed.connect(() => changed());
            emergency.add_row(contact_name);
            contact_number = new EntryRow(_("Contact Phone Number"));
            contact_number.entry_changed.connect(() => changed());
            emergency.add_row(contact_number);
            add_group(emergency);

            var medical = new PreferencesGroup(_("Medical Details"),
                _("What someone helping you should know. Kept on this computer only."));
            medical_name = new EntryRow(_("Name"));
            blood = new EntryRow(_("Blood Type"));
            allergies = new EntryRow(_("Allergies"));
            conditions = new EntryRow(_("Conditions"));
            medication = new EntryRow(_("Medication"));
            EntryRow[] rows = { medical_name, blood, allergies, conditions, medication };
            foreach (var r in rows) {
                r.entry_changed.connect(() => changed());
                medical.add_row(r);
            }
            on_lock = new SwitchRow(_("Show on the Emergency Screen"), _("Anyone can read these details from the emergency screen"));
            on_lock.switch_btn.notify["active"].connect(() => changed());
            medical.add_row(on_lock);
            add_group(medical);

            var test = new PreferencesGroup(_("Try It"));
            var loud = new ActionRow(_("Send a Test Danger"), _("The red top bar and the alert card, for five minutes"), "aegis-national-symbolic");
            loud.activatable = true;
            loud.activated.connect(() => client.test.begin("national"));
            test.add_row(loud);
            var quiet = new ActionRow(_("Send a Quiet Test"), _("Only a line in the top bar"), "aegis-storm-symbolic");
            quiet.activatable = true;
            quiet.activated.connect(() => client.test.begin("storm:notice"));
            test.add_row(quiet);
            add_group(test);

            load.begin();
        }

        private static string member(Json.Object o, string key) {
            return o.has_member(key) && !o.get_null_member(key) && o.get_member(key).get_value_type() == typeof(string) ? o.get_string_member(key) : "";
        }

        private async void load() {
            var client = AegisClient.get_default();
            try {
                var parser = new Json.Parser();
                parser.load_from_data(yield client.config());
                config = parser.get_root().dup_object();
            } catch (Error e) {
                config = new Json.Object();
            }
            enabled.active = !config.has_member("enabled") || config.get_boolean_member("enabled");
            if (config.has_member("min_severity")) severity.current_value = config.get_int_member("min_severity").to_string();
            if (config.has_member("min_magnitude")) magnitude.current_value = "%g".printf(config.get_double_member("min_magnitude"));
            country.text = member(config, "country");
            if (config.has_member("places") && !config.get_null_member("places")) {
                string[] names = {};
                foreach (var n in config.get_array_member("places").get_elements()) names += n.get_string();
                places.text = string.joinv(", ", names);
            }
            double lat = config.has_member("lat") ? config.get_double_member("lat") : 0;
            double lon = config.has_member("lon") ? config.get_double_member("lon") : 0;
            if (lat != 0 || lon != 0) position.text = "%.4f, %.4f".printf(lat, lon);
            if (config.has_member("contacts") && !config.get_null_member("contacts")) {
                var list = config.get_array_member("contacts");
                if (list.get_length() > 0) {
                    contact_name.text = member(list.get_object_element(0), "name");
                    contact_number.text = member(list.get_object_element(0), "number");
                }
            }
            if (config.has_member("medical")) {
                var m = config.get_object_member("medical");
                medical_name.text = member(m, "name");
                blood.text = member(m, "blood");
                allergies.text = member(m, "allergies");
                conditions.text = member(m, "conditions");
                medication.text = member(m, "medication");
                on_lock.active = m.has_member("on_lock") && m.get_boolean_member("on_lock");
            }
            loading = false;
            yield summary();
        }

        private async void summary() {
            var client = AegisClient.get_default();
            try {
                var parser = new Json.Parser();
                parser.load_from_data(yield client.sos());
                var o = parser.get_root().get_object();
                string[] list = {};
                foreach (var n in o.get_array_member("numbers").get_elements()) list += n.get_string();
                numbers.subtitle = "%s  ·  %s".printf(member(o, "country").up(), string.joinv(", ", list));
                string[] names = {};
                foreach (var n in o.get_array_member("sources").get_elements()) names += n.get_string();
                sources.subtitle = names.length > 0 ? string.joinv(", ", names) : _("No authority of this country publishes alerts online. Earthquakes still work.");
            } catch (Error e) {
                numbers.subtitle = "112";
            }
            string[] known = yield client.areas();
            if (known.length > 0) places.subtitle = _("Seen in the feeds: %s").printf(string.joinv(", ", known[0:int.min(known.length, 24)]));
        }

        private void changed() {
            if (loading) return;
            if (pending != 0) GLib.Source.remove(pending);
            pending = GLib.Timeout.add(700, () => {
                pending = 0;
                save.begin();
                return GLib.Source.REMOVE;
            });
        }

        private async void save() {
            config.set_boolean_member("enabled", enabled.active);
            config.set_int_member("min_severity", int.parse(severity.current_value));
            config.set_double_member("min_magnitude", double.parse(magnitude.current_value));
            config.set_string_member("country", country.text.strip().down());
            var list = new Json.Array();
            foreach (string p in places.text.split(",")) if (p.strip() != "") list.add_string_element(p.strip());
            config.set_array_member("places", list);
            string[] pos = position.text.split(",");
            config.set_double_member("lat", pos.length == 2 ? double.parse(pos[0].strip()) : 0);
            config.set_double_member("lon", pos.length == 2 ? double.parse(pos[1].strip()) : 0);
            var contacts = new Json.Array();
            if (contact_name.text.strip() != "" || contact_number.text.strip() != "") {
                var c = new Json.Object();
                c.set_string_member("name", contact_name.text.strip());
                c.set_string_member("number", contact_number.text.strip());
                contacts.add_object_element(c);
            }
            config.set_array_member("contacts", contacts);
            var m = new Json.Object();
            m.set_string_member("name", medical_name.text.strip());
            m.set_string_member("blood", blood.text.strip());
            m.set_string_member("allergies", allergies.text.strip());
            m.set_string_member("conditions", conditions.text.strip());
            m.set_string_member("medication", medication.text.strip());
            m.set_string_member("notes", config.has_member("medical") ? member(config.get_object_member("medical"), "notes") : "");
            m.set_boolean_member("on_lock", on_lock.active);
            config.set_object_member("medical", m);
            var node = new Json.Node(Json.NodeType.OBJECT);
            node.set_object(config);
            yield AegisClient.get_default().set_config(Json.to_string(node, false));
            yield summary();
        }
    }
}
