using Gtk;
using Singularity.Widgets;
using Singularity.Tablet;

namespace Singularity.SidebarPages {

    public class TabletPage : SettingsPage {
        private SettingsView view;
        private GLib.Settings settings;
        private TabletManager manager;
        private StatusPage empty;
        private PreferencesGroup device_group;
        private PreferencesGroup screen_group;
        private PreferencesGroup buttons_group;
        private Gee.ArrayList<Widget> device_rows = new Gee.ArrayList<Widget>();
        private SelectionRow screen_row;
        private Gee.ArrayList<string> screen_names = new Gee.ArrayList<string>();
        private ActionRow area_row;
        private ActionRow pressure_row;
        private ActionRow pen_buttons_row;
        private ActionRow pad_buttons_row;
        private bool syncing = false;

        public TabletPage(SettingsView view) {
            base(_("Graphics Tablet"));
            this.view = view;
            settings = new GLib.Settings("dev.sinty.desktop");
            manager = TabletManager.get_default();
            back_clicked.connect(() => view.go_home());

            empty = new StatusPage();
            empty.icon_name = "input-tablet";
            empty.title = _("No Tablet Connected");
            empty.description = _("Connect a graphics tablet to map it to a screen and choose what its pen and buttons do.");
            add_widget(empty);

            device_group = new PreferencesGroup(_("Device"));
            add_group(device_group);

            screen_group = new PreferencesGroup(_("Screen"));
            screen_row = new SelectionRow(_("Map to Screen"), {});
            screen_row.selected.connect(on_screen_selected);
            screen_group.add_row(screen_row);
            var aspect_row = new SwitchRow(_("Keep Aspect Ratio"),
                _("Use only the part of the tablet that has the shape of the screen"),
                settings.get_boolean("tablet-keep-aspect"));
            settings.bind("tablet-keep-aspect", aspect_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            screen_group.add_row(aspect_row);
            var left_row = new SwitchRow(_("Left-Handed"),
                _("Turn the tablet around so that its buttons are on the right"),
                settings.get_boolean("tablet-left-handed"));
            settings.bind("tablet-left-handed", left_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            screen_group.add_row(left_row);
            area_row = make_nav_row(_("Active Area"), "", "view-fullscreen-symbolic",
                () => view.open_subpage(new TabletAreaPage(view), "tablet-area"));
            screen_group.add_row(area_row);
            var mouse_row = new SwitchRow(_("Mouse Mode"),
                _("Move the pointer from where it is, like a mouse, instead of to the point under the pen"),
                settings.get_boolean("tablet-mouse-mode"));
            settings.bind("tablet-mouse-mode", mouse_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            screen_group.add_row(mouse_row);
            add_group(screen_group);

            buttons_group = new PreferencesGroup(_("Pen and Buttons"));
            pressure_row = make_nav_row(_("Pressure"), "", "singularity-markup-pen-symbolic",
                () => view.open_subpage(new TabletPressurePage(view), "tablet-pressure"));
            buttons_group.add_row(pressure_row);
            pen_buttons_row = make_nav_row(_("Pen Buttons"), _("Clicks for the buttons on the side of the pen"),
                "input-mouse-symbolic", () => view.open_subpage(new TabletPenButtonsPage(view), "tablet-pen-buttons"));
            buttons_group.add_row(pen_buttons_row);
            pad_buttons_row = make_nav_row(_("Tablet Buttons"), "", "input-keyboard-symbolic",
                () => view.open_subpage(new TabletPadButtonsPage(view), "tablet-pad-buttons"));
            buttons_group.add_row(pad_buttons_row);
            add_group(buttons_group);

            manager.changed.connect(refresh);
            settings.changed.connect((key) => {
                if (key.has_prefix("tablet-")) refresh_summaries();
            });
            DisplayManager.get_default().monitors_changed.connect(refresh_screens);
            refresh();
        }

        private delegate void NavAction();

        private ActionRow make_nav_row(string title, string subtitle, string icon_name, owned NavAction action) {
            var row = new ActionRow(title, subtitle, icon_name);
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.add_css_class("dim-label");
            row.add_suffix(chevron);
            row.activatable = true;
            row.activated.connect(() => action());
            return row;
        }

        private void refresh() {
            bool connected = manager.connected;
            empty.visible = !connected;
            device_group.visible = connected;
            screen_group.visible = connected;
            buttons_group.visible = connected;
            foreach (var row in device_rows) device_group.remove_row(row);
            device_rows.clear();
            foreach (var dev in manager.state.devices) {
                var row = new ActionRow(dev.name != "" ? dev.name : _("Graphics Tablet"), describe(dev), "input-tablet-symbolic");
                device_group.add_row(row);
                device_rows.add(row);
            }
            device_group.description = manager.state.devices.size > 1
                ? _("These settings apply to every connected tablet.") : "";
            refresh_screens();
            refresh_summaries();
        }

        private string describe(DeviceInfo dev) {
            string size = dev.width_mm > 0 && dev.height_mm > 0
                ? _("%.0f by %.0f mm").printf(dev.width_mm, dev.height_mm) : _("Size unknown");
            if (dev.pad_buttons <= 0) return size;
            return ngettext("%s, %d button", "%s, %d buttons", dev.pad_buttons).printf(size, dev.pad_buttons);
        }

        private void refresh_screens() {
            syncing = true;
            screen_names.clear();
            string[] labels = { _("All Screens") };
            screen_names.add("");
            string current = settings.get_string("tablet-output");
            string current_label = labels[0];
            foreach (var m in DisplayManager.get_default().get_monitors()) {
                if (!m.enabled) continue;
                string label = m.description != null && m.description != "" ? m.description : m.name;
                labels += label;
                screen_names.add(m.name);
                if (m.name == current) current_label = label;
            }
            screen_row.set_items(labels);
            screen_row.current_value = current_label;
            syncing = false;
        }

        private void on_screen_selected(string label) {
            if (syncing) return;
            string[] labels = { _("All Screens") };
            foreach (var m in DisplayManager.get_default().get_monitors()) {
                if (!m.enabled) continue;
                labels += m.description != null && m.description != "" ? m.description : m.name;
            }
            for (int i = 0; i < labels.length && i < screen_names.size; i++) {
                if (labels[i] == label) {
                    settings.set_string("tablet-output", screen_names[i]);
                    return;
                }
            }
        }

        private void refresh_summaries() {
            var area = manager.active_area();
            area_row.subtitle = area == null
                ? _("Whole tablet")
                : _("%.0f by %.0f mm").printf(area.width, area.height);
            pressure_row.subtitle = TabletPressurePage.preset_label(PressureCurve.preset_index(manager.curve()));
            int pads = int.min(manager.state.pad_buttons, Rc.PAD_BUTTONS.length);
            pad_buttons_row.visible = pads > 0;
            pad_buttons_row.subtitle = ngettext("What the %d button on the tablet does",
                "What the %d buttons on the tablet do", pads).printf(pads);
        }
    }

    public class TabletAreaPage : SettingsPage {
        private GLib.Settings settings;
        private TabletManager manager;
        private TabletAreaPreview preview;
        private SpinRow left_row;
        private SpinRow top_row;
        private SpinRow width_row;
        private SpinRow height_row;
        private bool syncing = false;

        public TabletAreaPage(SettingsView view) {
            base(_("Active Area"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("tablet"));
            settings = new GLib.Settings("dev.sinty.desktop");
            manager = TabletManager.get_default();
            var dev = manager.state.primary;
            double tw = dev != null ? dev.width_mm : 0;
            double th = dev != null ? dev.height_mm : 0;

            var preview_group = new PreferencesGroup(_("Preview"),
                _("The highlighted part of the tablet covers the screen."));
            var preview_row = new PreferencesRow();
            preview_row.activatable = false;
            preview = new TabletAreaPreview();
            preview_row.set_child(preview);
            preview_group.add_row(preview_row);
            add_group(preview_group);

            var area_group = new PreferencesGroup(_("Area"),
                _("Measured in millimetres from the top left corner, with the tablet held normally."));
            var custom_row = new SwitchRow(_("Use Part of the Tablet"),
                _("Draw with less arm movement on a large tablet"),
                settings.get_boolean("tablet-area-custom"));
            settings.bind("tablet-area-custom", custom_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            area_group.add_row(custom_row);
            left_row = new SpinRow(_("Left"), null, 0, double.max(tw, 1), 1, 0);
            top_row = new SpinRow(_("Top"), null, 0, double.max(th, 1), 1, 0);
            width_row = new SpinRow(_("Width"), null, 1, double.max(tw, 1), 1, double.max(tw, 1));
            height_row = new SpinRow(_("Height"), null, 1, double.max(th, 1), 1, double.max(th, 1));
            foreach (var row in new SpinRow[] { left_row, top_row, width_row, height_row }) {
                row.spin_btn.value_changed.connect(store_area);
                area_group.add_row(row);
            }
            add_group(area_group);

            settings.changed.connect((key) => {
                if (key.has_prefix("tablet-")) sync();
            });
            manager.changed.connect(sync);
            sync();
        }

        private void sync() {
            var dev = manager.state.primary;
            double tw = dev != null ? dev.width_mm : 0;
            double th = dev != null ? dev.height_mm : 0;
            bool custom = settings.get_boolean("tablet-area-custom");
            double x, y, w, h;
            settings.get("tablet-area", "(dddd)", out x, out y, out w, out h);
            var shown = Geometry.clamp(Area(x, y, w, h), tw, th);
            if (shown.is_empty()) shown = Area(0, 0, tw, th);
            syncing = true;
            left_row.spin_btn.set_value(shown.x);
            top_row.spin_btn.set_value(shown.y);
            width_row.spin_btn.set_value(shown.width);
            height_row.spin_btn.set_value(shown.height);
            syncing = false;
            foreach (var row in new SpinRow[] { left_row, top_row, width_row, height_row }) row.sensitive = custom;
            double sw, sh;
            manager.screen_size(out sw, out sh);
            var active = Geometry.active_area(tw, th, custom, shown, settings.get_boolean("tablet-keep-aspect"),
                sw, sh);
            preview.set_areas(tw, th, active);
        }

        private void store_area() {
            if (syncing) return;
            settings.set("tablet-area", "(dddd)", left_row.spin_btn.get_value(), top_row.spin_btn.get_value(),
                width_row.spin_btn.get_value(), height_row.spin_btn.get_value());
        }
    }

    public class TabletAreaPreview : DrawingArea {
        private double tablet_width = 0;
        private double tablet_height = 0;
        private Area active = Area(0, 0, 0, 0);

        public TabletAreaPreview() {
            content_height = 150;
            hexpand = true;
            margin_top = 12;
            margin_bottom = 12;
            margin_start = 12;
            margin_end = 12;
            set_draw_func(draw);
        }

        public void set_areas(double width, double height, Area area) {
            tablet_width = width;
            tablet_height = height;
            active = area;
            queue_draw();
        }

        private void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w, h) / 2);
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            if (tablet_width <= 0 || tablet_height <= 0) return;
            var color = get_color();
            double scale = double.min((width - 2) / tablet_width, (height - 2) / tablet_height);
            double w = tablet_width * scale;
            double h = tablet_height * scale;
            double ox = (width - w) / 2;
            double oy = (height - h) / 2;
            rounded(cr, ox, oy, w, h, 8);
            cr.set_source_rgba(color.red, color.green, color.blue, 0.08);
            cr.fill_preserve();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.35);
            cr.set_line_width(1.5);
            cr.stroke();
            if (active.is_empty()) return;
            rounded(cr, ox + active.x * scale + 3, oy + active.y * scale + 3,
                active.width * scale - 6, active.height * scale - 6, 5);
            cr.set_source_rgba(color.red, color.green, color.blue, 0.22);
            cr.fill_preserve();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.8);
            cr.set_line_width(2);
            cr.stroke();
        }
    }

    public class TabletPressurePage : SettingsPage {
        private GLib.Settings settings;
        private TabletCurvePreview preview;
        private Scale feel;
        private bool syncing = false;

        public static string preset_label(int index) {
            switch (index) {
                case 0: return _("Softest");
                case 1: return _("Soft");
                case 2: return _("Normal");
                case 3: return _("Firm");
                case 4: return _("Firmest");
            }
            return _("Custom");
        }

        public TabletPressurePage(SettingsView view) {
            base(_("Pressure"));
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("tablet"));
            settings = new GLib.Settings("dev.sinty.desktop");

            var feel_group = new PreferencesGroup(_("Feel"),
                _("A soft pen reaches full pressure with a light touch, a firm pen needs you to press harder."));
            var preview_row = new PreferencesRow();
            preview_row.activatable = false;
            preview = new TabletCurvePreview();
            preview_row.set_child(preview);
            feel_group.add_row(preview_row);

            var feel_row = new PreferencesRow();
            feel_row.activatable = false;
            var box = new Box(Orientation.VERTICAL, 4);
            box.margin_top = 8;
            box.margin_bottom = 8;
            box.margin_start = 12;
            box.margin_end = 12;
            feel = new Scale.with_range(Orientation.HORIZONTAL, 0, PressureCurve.PRESET_COUNT - 1, 1);
            feel.draw_value = false;
            feel.round_digits = 0;
            feel.hexpand = true;
            for (int i = 0; i < PressureCurve.PRESET_COUNT; i++) feel.add_mark(i, PositionType.BOTTOM, null);
            feel.value_changed.connect(() => {
                if (syncing) return;
                int index = (int) Math.round(feel.get_value());
                double[] c = PressureCurve.preset(index);
                settings.set("tablet-pressure-curve", "(dddd)", c[0], c[1], c[2], c[3]);
            });
            box.append(feel);
            var ends = new Box(Orientation.HORIZONTAL, 0);
            var soft = new Label(_("Soft"));
            soft.add_css_class("dim-label");
            soft.add_css_class("caption");
            soft.hexpand = true;
            soft.halign = Align.START;
            var firm = new Label(_("Firm"));
            firm.add_css_class("dim-label");
            firm.add_css_class("caption");
            firm.halign = Align.END;
            ends.append(soft);
            ends.append(firm);
            box.append(ends);
            feel_row.set_child(box);
            feel_group.add_row(feel_row);
            add_group(feel_group);

            var try_group = new PreferencesGroup(_("Try It"), _("Draw here with the pen to feel the pressure."));
            var try_row = new PreferencesRow();
            try_row.activatable = false;
            var pad = new TabletTryArea();
            try_row.set_child(pad);
            try_group.add_row(try_row);
            var clear = new Button.with_label(_("Clear"));
            clear.add_css_class("flat");
            clear.valign = Align.CENTER;
            clear.clicked.connect(() => pad.clear());
            try_group.add_header_suffix(clear);
            add_group(try_group);

            settings.changed["tablet-pressure-curve"].connect(sync);
            sync();
        }

        private void sync() {
            double a, b, c, d;
            settings.get("tablet-pressure-curve", "(dddd)", out a, out b, out c, out d);
            double[] curve = { a, b, c, d };
            preview.set_curve(curve);
            int index = PressureCurve.preset_index(curve);
            syncing = true;
            feel.set_value(index >= 0 ? index : PressureCurve.LINEAR);
            syncing = false;
        }
    }

    public class TabletCurvePreview : DrawingArea {
        private double[] curve = { 0.0, 0.0, 1.0, 1.0 };

        public TabletCurvePreview() {
            content_height = 140;
            hexpand = true;
            margin_top = 12;
            margin_bottom = 8;
            margin_start = 12;
            margin_end = 12;
            set_draw_func(draw);
            update_property(Gtk.AccessibleProperty.LABEL, _("Pressure curve"), -1);
        }

        public void set_curve(double[] c) {
            curve = c;
            queue_draw();
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            var color = get_color();
            double size = double.min(width, height) - 2;
            double ox = (width - size) / 2;
            double oy = (height - size) / 2;
            cr.set_line_width(1);
            cr.set_source_rgba(color.red, color.green, color.blue, 0.12);
            for (int i = 0; i <= 4; i++) {
                double p = Math.floor(i * size / 4.0) + 0.5;
                cr.move_to(ox + p, oy);
                cr.line_to(ox + p, oy + size);
                cr.move_to(ox, oy + p);
                cr.line_to(ox + size, oy + p);
            }
            cr.stroke();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.3);
            cr.set_dash({ 4, 4 }, 0);
            cr.move_to(ox, oy + size);
            cr.line_to(ox + size, oy);
            cr.stroke();
            cr.set_dash(null, 0);
            cr.set_source_rgba(color.red, color.green, color.blue, 0.9);
            cr.set_line_width(2.5);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            for (int i = 0; i <= 64; i++) {
                double p = i / 64.0;
                double v = PressureCurve.apply(curve, p);
                double x = ox + p * size;
                double y = oy + size - v * size;
                if (i == 0) cr.move_to(x, y);
                else cr.line_to(x, y);
            }
            cr.stroke();
        }
    }

    public class TabletTryArea : DrawingArea {
        private struct Dot {
            public double x;
            public double y;
            public double pressure;
            public bool start;
        }

        private Gee.ArrayList<Dot?> dots = new Gee.ArrayList<Dot?>();

        public TabletTryArea() {
            content_height = 140;
            hexpand = true;
            margin_top = 8;
            margin_bottom = 8;
            margin_start = 8;
            margin_end = 8;
            set_draw_func(draw);
            var stylus = new GestureStylus();
            stylus.down.connect((x, y) => add_dot(stylus, x, y, true));
            stylus.motion.connect((x, y) => add_dot(stylus, x, y, false));
            add_controller(stylus);
        }

        private void add_dot(GestureStylus stylus, double x, double y, bool start) {
            double pressure;
            if (!stylus.get_axis(Gdk.AxisUse.PRESSURE, out pressure)) pressure = 0.5;
            if (!start && stylus.get_device_tool() == null) return;
            dots.add(Dot() { x = x, y = y, pressure = pressure, start = start });
            queue_draw();
        }

        public void clear() {
            dots.clear();
            queue_draw();
        }

        private void draw(DrawingArea area, Cairo.Context cr, int width, int height) {
            var color = get_color();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.05);
            cr.rectangle(0, 0, width, height);
            cr.fill();
            cr.set_source_rgba(color.red, color.green, color.blue, 0.9);
            cr.set_line_cap(Cairo.LineCap.ROUND);
            for (int i = 1; i < dots.size; i++) {
                if (dots[i].start) continue;
                cr.set_line_width(1 + dots[i].pressure * 10);
                cr.move_to(dots[i - 1].x, dots[i - 1].y);
                cr.line_to(dots[i].x, dots[i].y);
                cr.stroke();
            }
        }
    }

    private class TabletChoice {
        public string value;
        public string label;

        public TabletChoice(string value, string label) {
            this.value = value;
            this.label = label;
        }
    }

    private abstract class TabletButtonsPage : SettingsPage {
        protected GLib.Settings settings;
        private string key;

        protected TabletButtonsPage(SettingsView view, string title, string key) {
            base(title);
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("tablet"));
            settings = new GLib.Settings("dev.sinty.desktop");
            this.key = key;
        }

        protected SelectionRow button_row(string title, string button, string fallback, Gee.ArrayList<TabletChoice> choices) {
            string[] labels = {};
            foreach (var c in choices) labels += c.label;
            var map = TabletManager.read_map(settings, key);
            string current = map.contains(button) ? map[button] : fallback;
            string current_label = labels[0];
            foreach (var c in choices) {
                if (c.value == current) current_label = c.label;
            }
            var row = new SelectionRow(title, labels, current_label);
            row.selected.connect((label) => {
                foreach (var c in choices) {
                    if (c.label == label) TabletManager.write_map(settings, key, button, c.value);
                }
            });
            return row;
        }
    }

    private class TabletPenButtonsPage : TabletButtonsPage {
        public TabletPenButtonsPage(SettingsView view) {
            base(view, _("Pen Buttons"), "tablet-stylus-buttons");
            var choices = new Gee.ArrayList<TabletChoice>();
            choices.add(new TabletChoice("right", _("Right Click")));
            choices.add(new TabletChoice("middle", _("Middle Click")));
            choices.add(new TabletChoice("back", _("Back")));
            choices.add(new TabletChoice("none", _("Nothing")));
            var group = new PreferencesGroup(_("Pen"), _("The lower button is the one closer to the tip."));
            group.add_row(button_row(_("Lower Button"), "Stylus", "right", choices));
            group.add_row(button_row(_("Upper Button"), "Stylus2", "middle", choices));
            if (TabletManager.get_default().state.has_button("Stylus3"))
                group.add_row(button_row(_("Third Button"), "Stylus3", "back", choices));
            add_group(group);
        }
    }

    private class TabletPadButtonsPage : TabletButtonsPage {
        public TabletPadButtonsPage(SettingsView view) {
            base(view, _("Tablet Buttons"), "tablet-pad-buttons");
            var choices = new Gee.ArrayList<TabletChoice>();
            choices.add(new TabletChoice("default", _("Send to the App")));
            choices.add(new TabletChoice("key:ctrl+z", _("Undo")));
            choices.add(new TabletChoice("key:ctrl+shift+z", _("Redo")));
            choices.add(new TabletChoice("key:ctrl+c", _("Copy")));
            choices.add(new TabletChoice("key:ctrl+v", _("Paste")));
            choices.add(new TabletChoice("key:ctrl+s", _("Save")));
            choices.add(new TabletChoice("key:ctrl+plus", _("Zoom In")));
            choices.add(new TabletChoice("key:ctrl+minus", _("Zoom Out")));
            choices.add(new TabletChoice("right", _("Right Click")));
            choices.add(new TabletChoice("middle", _("Middle Click")));
            choices.add(new TabletChoice("back", _("Back")));
            choices.add(new TabletChoice("forward", _("Forward")));
            choices.add(new TabletChoice("action:toggle_workspace_overview", _("Workspaces")));
            choices.add(new TabletChoice("action:toggle_launcher", _("App Launcher")));
            choices.add(new TabletChoice("action:toggle_desktop_reveal", _("Show Desktop")));
            choices.add(new TabletChoice("action:screenshot_tool", _("Screenshot")));
            choices.add(new TabletChoice("action:toggle_screen_keyboard", _("Screen Keyboard")));
            choices.add(new TabletChoice("none", _("Nothing")));
            var group = new PreferencesGroup(_("Tablet"),
                _("Send to the App lets drawing apps decide. The other choices work the same in every app."));
            int count = int.min(TabletManager.get_default().state.pad_buttons, Rc.PAD_BUTTONS.length);
            for (int i = 0; i < count; i++)
                group.add_row(button_row(_("Button %d").printf(i + 1), Rc.PAD_BUTTONS[i], "default", choices));
            add_group(group);
        }
    }
}
