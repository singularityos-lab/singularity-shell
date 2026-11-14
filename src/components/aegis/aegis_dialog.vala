using Gtk;

namespace Singularity {

    public class AegisDialog : Singularity.Shell.ShellDialog {
        private static bool styled = false;
        private Stack stack;
        private Image icon;
        private Label headline;
        private Label meta;
        private Label description;
        private Label instruction;
        private Button dismiss;
        private Button weather;
        private Box sos_box;
        private string current = "";
        private uint tick = 0;

        public AegisDialog(Gtk.Application app) {
            Object(
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            ensure_style();
            add_css_class("aegis-dialog");

            stack = new Stack();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.vhomogeneous = false;
            stack.hhomogeneous = false;
            stack.interpolate_size = true;
            content_box.append(stack);

            var page = new Box(Orientation.VERTICAL, 12);
            page.halign = Align.CENTER;
            page.valign = Align.CENTER;
            page.add_css_class("power-card");
            page.margin_top = 28;
            page.margin_bottom = 28;
            page.margin_start = 40;
            page.margin_end = 40;

            icon = new Image();
            icon.pixel_size = 64;
            page.append(icon);
            headline = new Label("");
            headline.add_css_class("title-1");
            headline.wrap = true;
            headline.max_width_chars = 36;
            headline.justify = Justification.CENTER;
            page.append(headline);
            meta = new Label("");
            meta.add_css_class("dim-label");
            meta.wrap = true;
            meta.max_width_chars = 60;
            meta.justify = Justification.CENTER;
            page.append(meta);

            instruction = new Label("");
            instruction.wrap = true;
            instruction.max_width_chars = 60;
            instruction.justify = Justification.CENTER;
            instruction.halign = Align.FILL;
            instruction.add_css_class("aegis-instruction");
            page.append(instruction);

            description = new Label("");
            description.add_css_class("dim-label");
            description.add_css_class("body");
            description.wrap = true;
            description.wrap_mode = Pango.WrapMode.WORD_CHAR;
            description.max_width_chars = 64;
            description.justify = Justification.CENTER;
            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.max_content_height = 200;
            scroller.propagate_natural_height = true;
            scroller.propagate_natural_width = true;
            scroller.set_child(description);
            page.append(scroller);

            var row = new Box(Orientation.HORIZONTAL, 12);
            row.halign = Align.CENTER;
            row.margin_top = 6;
            var sos = new Button.with_label(_("Emergency Call"));
            sos.add_css_class("destructive-action");
            sos.add_css_class("pill");
            sos.clicked.connect(() => show_sos());
            row.append(sos);
            weather = new Button.with_label(_("Open Weather"));
            weather.add_css_class("pill");
            weather.clicked.connect(() => {
                var info = new DesktopAppInfo("dev.sinty.weather.desktop");
                if (info == null) return;
                try {
                    info.launch(null, null);
                    close_dialog();
                } catch (Error e) {
                }
            });
            row.append(weather);
            dismiss = new Button.with_label(_("Dismiss"));
            dismiss.add_css_class("pill");
            dismiss.clicked.connect(() => {
                AegisClient.get_default().dismiss.begin(current, (o, r) => {
                    if (AegisClient.get_default().dismiss.end(r)) close_dialog();
                });
            });
            row.append(dismiss);
            var keep = new Button.with_label(_("Continue Working"));
            keep.add_css_class("suggested-action");
            keep.add_css_class("pill");
            keep.clicked.connect(() => close_dialog());
            row.append(keep);
            page.append(row);
            stack.add_named(page, "alert");

            var sos_page = new Box(Orientation.VERTICAL, 14);
            sos_page.halign = Align.CENTER;
            sos_page.valign = Align.CENTER;
            sos_page.add_css_class("power-card");
            sos_page.margin_top = 28;
            sos_page.margin_bottom = 28;
            sos_page.margin_start = 40;
            sos_page.margin_end = 40;
            var sos_icon = new Image.from_icon_name("call-start-symbolic");
            sos_icon.pixel_size = 56;
            sos_page.append(sos_icon);
            var sos_title = new Label(_("Emergency Call"));
            sos_title.add_css_class("title-1");
            sos_page.append(sos_title);
            sos_box = new Box(Orientation.VERTICAL, 12);
            sos_page.append(sos_box);
            var back = new Button.with_label(_("Back"));
            back.add_css_class("pill");
            back.halign = Align.CENTER;
            back.width_request = 128;
            back.margin_top = 4;
            back.clicked.connect(() => {
                if (AegisClient.get_default().top != null) stack.visible_child_name = "alert";
                else close_dialog();
            });
            sos_page.append(back);
            stack.add_named(sos_page, "sos");

            AegisClient.get_default().changed.connect(() => {
                if (!visible) return;
                if (AegisClient.get_default().top == null && stack.visible_child_name == "alert") close_dialog();
                else fill();
            });
        }

        public void show_alert() {
            if (AegisClient.get_default().top == null) return;
            stack.visible_child_name = "alert";
            fill();
            open();
        }

        public void show_sos() {
            stack.visible_child_name = "sos";
            fill_sos.begin();
            open();
        }

        private void open() {
            if (tick == 0) tick = GLib.Timeout.add_seconds(1, () => { hold(); return GLib.Source.CONTINUE; });
            present();
        }

        public override void close_dialog() {
            if (tick != 0) {
                GLib.Source.remove(tick);
                tick = 0;
            }
            base.close_dialog();
        }

        private AegisAlert? shown() {
            foreach (var a in AegisClient.get_default().alerts) if (a.id == current) return a;
            return AegisClient.get_default().top;
        }

        private void hold() {
            var a = shown();
            if (a == null) return;
            int64 left = a.seconds_held();
            dismiss.sensitive = left == 0;
            dismiss.label = left == 0 ? _("Dismiss") : _("Dismiss in %d:%02d").printf((int) (left / 60), (int) (left % 60));
        }

        private void fill() {
            var a = AegisClient.get_default().top;
            if (a == null) return;
            current = a.id;
            var theme = IconTheme.get_for_display(get_display());
            string colour = "aegis-%s".printf(a.kind);
            icon.icon_name = theme.has_icon(colour) ? colour : "dialog-warning";
            headline.label = a.headline;
            var when = new DateTime.from_unix_local(a.sent > 0 ? a.sent : a.raised);
            string[] parts = {};
            if (a.test) parts += _("Test");
            if (a.area != "" && !a.test) parts += a.area;
            if (a.source != "") parts += a.source;
            parts += when.format("%H:%M");
            meta.label = string.joinv("  ·  ", parts);
            instruction.label = a.instruction;
            instruction.visible = a.instruction != "";
            description.label = a.description;
            weather.visible = a.kind in new string[] { "storm", "wind", "snow", "heat", "cold", "flood" } && new DesktopAppInfo("dev.sinty.weather.desktop") != null;
            if (a.danger) add_css_class("aegis-danger");
            else remove_css_class("aegis-danger");
            hold();
        }

        private static string member(Json.Object o, string key) {
            return o.has_member(key) && !o.get_null_member(key) ? o.get_string_member(key) : "";
        }

        private async void fill_sos() {
            Widget? c = sos_box.get_first_child();
            while (c != null) {
                var next = c.get_next_sibling();
                sos_box.remove(c);
                c = next;
            }
            Json.Object? o = null;
            try {
                var parser = new Json.Parser();
                parser.load_from_data(yield AegisClient.get_default().sos());
                o = parser.get_root().get_object();
            } catch (Error e) {
                o = null;
            }
            if (o == null || !o.has_member("numbers")) {
                var missing = new Label(_("Sinty Aegis is not running. In most countries 112 reaches the emergency services."));
                missing.justify = Justification.CENTER;
                missing.max_width_chars = 64;
                missing.wrap = true;
                sos_box.append(missing);
                return;
            }
            bool line = o.get_int_member("lines") > 0;
            var note = new Label(line
                ? _("Choose a number to call it from this computer.")
                : _("This computer has no phone line. Call one of these numbers from a phone."));
            note.justify = Justification.CENTER;
            note.max_width_chars = 72;
            note.wrap = true;
            note.add_css_class("dim-label");
            sos_box.append(note);
            var row = new Box(Orientation.HORIZONTAL, 12);
            row.halign = Align.CENTER;
            foreach (var n in o.get_array_member("numbers").get_elements()) {
                string number = n.get_string();
                if (line) {
                    var b = new Button.with_label(number);
                    b.add_css_class("aegis-number");
                    b.add_css_class("destructive-action");
                    b.clicked.connect(() => {
                        AegisClient.get_default().call.begin(number, (obj, res) => {
                            string? err = AegisClient.get_default().call.end(res);
                            note.label = err == null ? _("Calling %s").printf(number) : err;
                        });
                    });
                    row.append(b);
                } else {
                    var l = new Label(number);
                    l.add_css_class("aegis-number");
                    l.selectable = true;
                    row.append(l);
                }
            }
            sos_box.append(row);
            if (o.get_boolean_member("located")) {
                var where = new Label(_("Your position: %.4f, %.4f").printf(o.get_double_member("lat"), o.get_double_member("lon")));
                where.selectable = true;
                sos_box.append(where);
            }
            if (o.has_member("contacts") && !o.get_null_member("contacts")) {
                foreach (var n in o.get_array_member("contacts").get_elements()) {
                    var contact = n.get_object();
                    var l = new Label("%s  ·  %s".printf(member(contact, "name"), member(contact, "number")));
                    l.selectable = true;
                    sos_box.append(l);
                }
            }
            if (o.has_member("medical")) {
                var m = o.get_object_member("medical");
                string[] lines = {};
                string[,] fields = {
                    { "name", _("Name") }, { "blood", _("Blood Type") }, { "allergies", _("Allergies") },
                    { "conditions", _("Conditions") }, { "medication", _("Medication") }, { "notes", _("Notes") }
                };
                for (int i = 0; i < fields.length[0]; i++) {
                    string v = member(m, fields[i, 0]);
                    if (v != "") lines += "%s: %s".printf(fields[i, 1], v);
                }
                if (lines.length > 0) {
                    var card = new Label(string.joinv("\n", lines));
                    card.halign = Align.FILL;
                    card.justify = Justification.CENTER;
                    card.wrap = true;
                    card.selectable = true;
                    card.add_css_class("aegis-medical");
                    sos_box.append(card);
                }
            }
        }

        private static void ensure_style() {
            if (styled) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            styled = true;
            var provider = new Gtk.CssProvider();
            provider.load_from_data(CSS.data);
            StyleContext.add_provider_for_display(display, provider, STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
        }

        private const string CSS = """
            .aegis-instruction { font-weight: 700; padding: 10px 16px; border-radius: 14px; background-color: alpha(currentColor, 0.07); }
            .aegis-danger .aegis-instruction { background-color: alpha(#e01b24, 0.2); }
            .aegis-number { font-size: 30px; font-weight: 800; padding: 8px 22px; border-radius: 16px; }
            label.aegis-number { background-color: alpha(currentColor, 0.08); }
            .aegis-medical { padding: 10px 16px; border-radius: 14px; background-color: alpha(currentColor, 0.06); }
        """;
    }
}
