using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class SpokenVoicePage : SettingsPage {
        private const string BUS_NAME = "dev.sinty.Speech1";
        private const string OBJECT_PATH = "/dev/sinty/Speech1";
        private const string INTERFACE = "dev.sinty.Speech1";

        private DBusProxy? proxy = null;
        private bool syncing = false;
        private uint write_id = 0;

        private PreferencesGroup voice_group;
        private PreferencesGroup speech_group;
        private PreferencesGroup natural_group;
        private StatusPage missing;
        private SelectionRow voice_row;
        private Scale rate_scale;
        private Scale pitch_scale;
        private Scale volume_scale;
        private Widget[] natural_rows = {};
        private HashTable<string, Label> progress_labels = new HashTable<string, Label>(str_hash, str_equal);
        private HashTable<string, Button> install_buttons = new HashTable<string, Button>(str_hash, str_equal);
        private Gee.ArrayList<Singularity.Core.AppSettingOption> voice_options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();

        public signal void summary_changed(string summary);

        public SpokenVoicePage(SettingsView view) {
            base(_("Spoken Voice"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("accessibility"));

            missing = new StatusPage();
            missing.icon_name = "audio-speakers-symbolic";
            missing.title = _("Speech Not Available");
            missing.description = _("The speech service of the system is not running, so text cannot be read aloud.");
            missing.compact = true;
            missing.visible = false;
            add_widget(missing);

            voice_group = new PreferencesGroup(_("Reading Aloud"));
            voice_group.description = _("The voice apps use to read text aloud. Automatic picks a voice for the language of the system.");
            voice_row = new SelectionRow.with_options(_("Voice"), new Gee.ArrayList<Singularity.Core.AppSettingOption>(), "");
            voice_row.selected.connect((id) => {
                if (syncing) return;
                set_property_value("Voice", new Variant.string(id));
            });
            voice_group.add_row(voice_row);
            var try_row = new ActionRow(_("Try the Voice"), _("Hear a short sentence"));
            try_row.activatable = false;
            var try_btn = new Button.with_label(_("Play"));
            try_btn.valign = Align.CENTER;
            try_btn.clicked.connect(() => call.begin("Preview", new Variant("(s)", voice_row.current_value)));
            try_row.add_suffix(try_btn);
            voice_group.add_row(try_row);
            add_group(voice_group);

            speech_group = new PreferencesGroup(_("Speech"));
            rate_scale = slider(speech_group, _("Speed"), _("How fast the voice speaks"), 0.5, 2.5, 0.05, "%.2f×");
            pitch_scale = slider(speech_group, _("Pitch"), _("How high the voice sounds"), 0.5, 2, 0.05, "%.2f×");
            volume_scale = slider(speech_group, _("Volume"), _("How loud the voice is, next to the other sounds"), 0, 1.5, 0.05, "%.0f%%", 100);
            add_group(speech_group);

            natural_group = new PreferencesGroup(_("Natural Voices"));
            natural_group.description = _("Voices that sound like a person. Each one is a download of tens of megabytes, checked before it is installed, and then works without a connection.");
            natural_group.visible = false;
            add_group(natural_group);

            map.connect(() => refresh.begin());
            connect_proxy.begin();
        }

        private Scale slider(PreferencesGroup group, string title, string subtitle, double min, double max, double step, string format, double factor = 1) {
            var row = new ActionRow(title, subtitle);
            row.activatable = false;
            var scale = new Scale.with_range(Orientation.HORIZONTAL, min, max, step);
            scale.width_request = 160;
            scale.draw_value = true;
            scale.value_pos = PositionType.RIGHT;
            scale.set_format_value_func((s, value) => format.printf(value * factor));
            scale.value_changed.connect(schedule_write);
            row.add_suffix(scale);
            group.add_row(row);
            return scale;
        }

        private async void connect_proxy() {
            try {
                proxy = yield new DBusProxy.for_bus(BusType.SESSION, DBusProxyFlags.NONE,
                    null, BUS_NAME, OBJECT_PATH, INTERFACE, null);
                proxy.g_properties_changed.connect(() => sync_values());
                proxy.g_signal.connect(on_signal);
            } catch (Error e) {
                proxy = null;
            }
            yield refresh();
        }

        private async Variant? call(string method, Variant? args) {
            if (proxy == null) return null;
            try {
                return yield proxy.call(method, args, DBusCallFlags.NONE, -1, null);
            } catch (Error e) {
                debug("SpokenVoicePage: %s: %s", method, e.message);
                return null;
            }
        }

        private void set_property_value(string name, Variant value) {
            if (proxy == null) return;
            proxy.call.begin("org.freedesktop.DBus.Properties.Set",
                new Variant("(ssv)", INTERFACE, name, value), DBusCallFlags.NONE, -1, null, (o, r) => {
                    try {
                        proxy.call.end(r);
                    } catch (Error e) {
                        debug("SpokenVoicePage: %s: %s", name, e.message);
                    }
                });
            proxy.set_cached_property(name, value);
            update_summary();
        }

        private void schedule_write() {
            if (syncing) return;
            if (write_id != 0) Source.remove(write_id);
            write_id = Timeout.add(250, () => {
                write_id = 0;
                set_property_value("Rate", new Variant.double(Math.round(rate_scale.get_value() * 100) / 100.0));
                set_property_value("Pitch", new Variant.double(Math.round(pitch_scale.get_value() * 100) / 100.0));
                set_property_value("Volume", new Variant.double(Math.round(volume_scale.get_value() * 100) / 100.0));
                return Source.REMOVE;
            });
        }

        private double cached_double(string name, double fallback) {
            var v = proxy != null ? proxy.get_cached_property(name) : null;
            return v != null && v.is_of_type(VariantType.DOUBLE) ? v.get_double() : fallback;
        }

        private string cached_string(string name) {
            var v = proxy != null ? proxy.get_cached_property(name) : null;
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        private bool cached_bool(string name) {
            var v = proxy != null ? proxy.get_cached_property(name) : null;
            return v != null && v.is_of_type(VariantType.BOOLEAN) && v.get_boolean();
        }

        private void sync_values() {
            if (write_id != 0) return;
            syncing = true;
            rate_scale.set_value(cached_double("Rate", 1));
            pitch_scale.set_value(cached_double("Pitch", 1));
            volume_scale.set_value(cached_double("Volume", 1));
            voice_row.current_value = cached_string("Voice");
            syncing = false;
            update_summary();
        }

        private static Singularity.Core.AppSettingOption option(string id, string label, string subtitle) {
            var opt = new Singularity.Core.AppSettingOption();
            opt.id = id;
            opt.label = label;
            opt.subtitle = subtitle;
            return opt;
        }

        private static string system_language() {
            string lang = Environment.get_variable("LANG") ?? "";
            int cut = lang.index_of_char('.');
            if (cut >= 0) lang = lang.substring(0, cut);
            return lang.replace("_", "-").down();
        }

        private static bool same_language(string a, string b) {
            return a.down().split("-")[0] == b.split("-")[0];
        }

        private async void refresh() {
            var reply = yield call("ListVoices", null);
            bool available = reply != null;
            missing.visible = !available;
            voice_group.visible = available;
            speech_group.visible = available;
            if (!available) {
                natural_group.visible = false;
                return;
            }
            string lang = system_language();
            var natural = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            var local = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            var others = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            var list = reply.get_child_value(0);
            for (size_t i = 0; i < list.n_children(); i++) {
                var row = list.get_child_value(i);
                if (row.n_children() < 4) continue;
                string id = row.get_child_value(0).get_string();
                string name = row.get_child_value(1).get_string();
                string language = row.get_child_value(2).get_string();
                string engine = row.get_child_value(3).get_string();
                string label = engine == "piper" ? capitalize(name) : name;
                string detail = engine == "piper" ? _("Natural voice, %s").printf(language) : language;
                var opt = option(id, label, detail);
                if (engine == "piper" && same_language(language, lang)) natural.add(opt);
                else if (same_language(language, lang)) local.add(opt);
                else others.add(opt);
            }
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            options.add(option("", _("Automatic"), _("A voice for the language of the system")));
            options.add_all(natural);
            options.add_all(local);
            options.add_all(others);
            voice_options = options;
            syncing = true;
            voice_row.set_options(options);
            syncing = false;
            sync_values();
            yield refresh_natural();
        }

        private static string capitalize(string s) {
            if (s == "") return s;
            return s.substring(0, 1).up() + s.substring(1);
        }

        private static string quality_label(string quality) {
            switch (quality) {
            case "x_low": return _("very compact");
            case "low": return _("compact");
            case "medium": return _("good quality");
            case "high": return _("best quality");
            }
            return quality;
        }

        private async void refresh_natural() {
            double scrolled = scroller.vadjustment.value;
            yield fill_natural();
            Idle.add(() => {
                scroller.vadjustment.value = scrolled;
                return Source.REMOVE;
            });
        }

        private async void fill_natural() {
            foreach (var w in natural_rows) natural_group.remove_row(w);
            natural_rows = {};
            progress_labels.remove_all();
            install_buttons.remove_all();
            if (!cached_bool("NeuralVoices")) {
                natural_group.visible = false;
                return;
            }
            natural_group.visible = true;
            var reply = yield call("AvailableVoices", new Variant("(s)", ""));
            if (reply == null) {
                var row = new ActionRow(_("The list of voices cannot be downloaded right now"), _("Check the connection and open this page again."));
                row.activatable = false;
                natural_group.add_row(row);
                natural_rows += row;
                return;
            }
            var list = reply.get_child_value(0);
            if (list.n_children() == 0) {
                var row = new ActionRow(_("No natural voice speaks the language of the system yet"), null);
                row.activatable = false;
                natural_group.add_row(row);
                natural_rows += row;
            }
            for (size_t i = 0; i < list.n_children(); i++) {
                string key, name, language, quality;
                int64 size;
                bool installed;
                list.get_child_value(i).get("(ssssxb)", out key, out name, out language, out quality, out size, out installed);
                var row = new ActionRow(capitalize(name), "%s, %s, %s".printf(language, quality_label(quality), format_size((uint64) size)));
                row.activatable = false;
                var progress = new Label("");
                progress.add_css_class("dim-label");
                progress.visible = false;
                progress.valign = Align.CENTER;
                row.add_suffix(progress);
                progress_labels.set(key, progress);
                var btn = new Button.with_label(installed ? _("Remove") : _("Download"));
                btn.valign = Align.CENTER;
                if (installed) btn.add_css_class("destructive-action");
                string voice_key = key;
                btn.clicked.connect(() => {
                    if (installed) {
                        call.begin("RemoveVoice", new Variant("(s)", voice_key), (o, r) => {
                            call.end(r);
                            refresh.begin();
                        });
                    } else {
                        btn.sensitive = false;
                        progress.label = _("Starting");
                        progress.visible = true;
                        call.begin("InstallVoice", new Variant("(s)", voice_key));
                    }
                });
                install_buttons.set(key, btn);
                row.add_suffix(btn);
                natural_group.add_row(row);
                natural_rows += row;
            }
        }

        private void on_signal(string? sender, string name, Variant args) {
            if (name == "VoiceProgress") {
                string key;
                int64 done, total;
                args.get("(sxx)", out key, out done, out total);
                var label = progress_labels.get(key);
                if (label != null && total > 0) {
                    label.label = "%d%%".printf((int) (done * 100 / total));
                    label.visible = true;
                }
            } else if (name == "VoiceInstalled") {
                string key, error;
                bool ok;
                args.get("(sbs)", out key, out ok, out error);
                if (ok) {
                    set_property_value("Voice", new Variant.string("piper:" + key));
                    refresh.begin();
                } else {
                    var label = progress_labels.get(key);
                    if (label != null) {
                        label.label = _("Download failed");
                        label.tooltip_text = error;
                        label.visible = true;
                    }
                    var btn = install_buttons.get(key);
                    if (btn != null) btn.sensitive = true;
                }
            }
        }

        private void update_summary() {
            string id = cached_string("Voice");
            string label = _("Automatic");
            if (id != "") {
                foreach (var opt in voice_options) {
                    if (opt.id == id) label = opt.label;
                }
            }
            summary_changed(label);
        }
    }
}
