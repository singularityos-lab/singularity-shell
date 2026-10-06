using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class SnapLayoutTile : Gtk.Widget {
        public SnapLayout layout { get; construct; }
        public int tile_width { get; construct; }
        public int tile_height { get; construct; }
        private Fixed fixed;
        private Box[] zone_boxes = {};
        private SnapZone? _hovered = null;

        public signal void zone_activated(SnapZone zone);
        public signal void zone_hovered(SnapZone? zone);

        public SnapLayoutTile(SnapLayout layout, int tile_width, int tile_height) {
            Object(layout: layout, tile_width: tile_width, tile_height: tile_height);
        }

        static construct {
            set_layout_manager_type(typeof(BinLayout));
            set_css_name("snap-layout");
        }

        construct {
            add_css_class("snap-layout-tile");
            tooltip_text = layout.name;
            set_size_request(tile_width, tile_height);
            fixed = new Fixed();
            fixed.set_parent(this);
            var cell = SnapRect(0, 0, tile_width, tile_height);
            foreach (var zone in layout.zones) {
                var rect = zone.rect_in(cell);
                var box = new Box(Orientation.VERTICAL, 0);
                box.add_css_class("snap-zone");
                box.set_size_request(int.max(rect.width - 4, 4), int.max(rect.height - 4, 4));
                fixed.put(box, rect.x + 2, rect.y + 2);
                zone_boxes += box;
            }

            var motion = new EventControllerMotion();
            motion.motion.connect((x, y) => set_hovered(zone_at((int) x, (int) y)));
            motion.leave.connect(() => set_hovered(null));
            add_controller(motion);

            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                var zone = zone_at((int) x, (int) y);
                if (zone != null) zone_activated(zone);
            });
            add_controller(click);
        }

        public override void dispose() {
            if (fixed != null) {
                fixed.unparent();
                fixed = null;
            }
            base.dispose();
        }

        public SnapZone? zone_at(int x, int y) {
            return SnapLayoutModel.zone_at(layout, SnapRect(0, 0, tile_width, tile_height), x, y);
        }

        public SnapZone? hovered {
            get { return _hovered; }
        }

        public void set_hovered(SnapZone? zone) {
            if (zone == _hovered || (zone != null && _hovered != null && zone.same_as(_hovered))) return;
            _hovered = zone;
            for (int i = 0; i < layout.zones.length; i++) {
                bool on = zone != null && layout.zones[i].same_as(zone);
                if (on) zone_boxes[i].add_css_class("hover");
                else zone_boxes[i].remove_css_class("hover");
            }
            zone_hovered(zone);
        }
    }

    public class SnapPicker : Gtk.Window {
        public const int SHADOW = 24;
        private const int TILE_BASE = 92;
        private const int GRACE_MS = 350;

        public signal void zone_chosen(SnapLayout layout, SnapZone zone);
        public signal void closed();

        private Singularity.Animation.MotionBin card_bin;
        private Box card;
        private Grid grid;
        private SnapLayoutTile[] tiles = {};
        private SnapRect _area;
        private SnapRect _surface;
        private Gdk.Monitor? _monitor = null;
        private uint _source = 0;
        private bool _pointer_inside = false;
        private bool _button_hovered = false;
        private uint _grace_id = 0;
        private bool _closing = false;
        private Cairo.RectangleInt _card_rect = Cairo.RectangleInt() { x = 0, y = 0, width = 0, height = 0 };

        public SnapRect area { get { return _area; } }
        public SnapRect surface { get { return _surface; } }
        public uint source { get { return _source; } }
        public bool is_open { get { return visible && !_closing; } }

        public SnapPicker(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-snap-picker");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("snap-picker-window");

            card = new Box(Orientation.VERTICAL, 8);
            card.add_css_class("snap-picker");
            var title = new Label(_("Snap Layouts"));
            title.add_css_class("snap-picker-title");
            title.halign = Align.START;
            card.append(title);
            grid = new Grid();
            grid.row_spacing = 10;
            grid.column_spacing = 10;
            card.append(grid);

            card_bin = new Singularity.Animation.MotionBin(card);
            set_child(card_bin);

            var motion = new EventControllerMotion();
            motion.enter.connect(() => {
                _pointer_inside = true;
                cancel_grace();
            });
            motion.leave.connect(() => {
                _pointer_inside = false;
                if (_source == 0) schedule_grace();
            });
            ((Gtk.Widget) this).add_controller(motion);
            map.connect_after(() => apply_input_region());
        }

        private void apply_input_region() {
            var surface = get_surface();
            if (surface == null || _card_rect.width < 1 || _card_rect.height < 1) return;
            var region = new Cairo.Region.rectangle(_card_rect);
            surface.set_input_region(region);
        }

        private static Gdk.Monitor? monitor_for(SnapRect area) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            int cx = area.x + area.width / 2;
            int cy = area.y + area.height / 2;
            Gdk.Monitor? first = null;
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = (Gdk.Monitor) monitors.get_item(i);
                if (first == null) first = monitor;
                var g = monitor.geometry;
                if (cx >= g.x && cx < g.x + g.width && cy >= g.y && cy < g.y + g.height) return monitor;
            }
            return first;
        }

        private void rebuild(uint source, Gdk.Rectangle output) {
            foreach (var tile in tiles) grid.remove(tile);
            tiles = {};
            var layouts = SnapLayoutModel.layouts_for(output.width, output.height);
            int tile_w = TILE_BASE;
            int tile_h = TILE_BASE;
            if (_area.width > 0 && _area.height > 0) {
                if (_area.width >= _area.height) {
                    tile_h = int.max(28, (int) Math.round((double) TILE_BASE * _area.height / _area.width));
                } else {
                    tile_h = TILE_BASE;
                    tile_w = int.max(40, (int) Math.round((double) TILE_BASE * _area.width / _area.height));
                }
            }
            int columns = source == 0 ? 3 : layouts.length;
            for (int i = 0; i < layouts.length; i++) {
                var tile = new SnapLayoutTile(layouts[i], tile_w, tile_h);
                var layout = layouts[i];
                tile.zone_activated.connect((zone) => zone_chosen(layout, zone));
                grid.attach(tile, i % columns, i / columns, 1, 1);
                tiles += tile;
            }
        }

        public void open(uint source, SnapRect anchor, SnapRect area) {
            cancel_grace();
            _closing = false;
            _source = source;
            _area = area;
            _button_hovered = source == 0;
            _pointer_inside = false;
            _monitor = monitor_for(area);
            Gdk.Rectangle mg = { area.x, area.y, area.width, area.height };
            if (_monitor != null) {
                mg = _monitor.geometry;
                set_monitor(this, _monitor);
            }
            rebuild(source, mg);
            int w, h, nat;
            card_bin.measure(Orientation.HORIZONTAL, -1, out w, out nat, null, null);
            w = int.max(w, nat);
            card_bin.measure(Orientation.VERTICAL, w, out h, out nat, null, null);
            h = int.max(h, nat);
            int card_w = w - SHADOW * 2;
            int card_h = h - SHADOW * 2;
            int x, y;
            if (source == 0) {
                x = anchor.x + anchor.width / 2 - card_w / 2;
                y = anchor.y + anchor.height + 6;
                if (y + card_h > area.y + area.height) y = anchor.y - card_h - 6;
            } else {
                x = area.x + (area.width - card_w) / 2;
                y = area.y + 10;
            }
            x = int.max(area.x + 8, int.min(x, area.x + area.width - card_w - 8));
            y = int.max(area.y + 4, y);
            _surface = SnapRect(x - SHADOW, y - SHADOW, w, h);
            _card_rect = Cairo.RectangleInt() { x = SHADOW, y = SHADOW, width = card_w, height = card_h };
            set_margin(this, GtkLayerShell.Edge.LEFT, _surface.x - mg.x);
            set_margin(this, GtkLayerShell.Edge.TOP, _surface.y - mg.y);
            card_bin.origin_x = 0.5;
            card_bin.origin_y = 0.0;
            present();
            apply_input_region();
            Singularity.Motion.reveal(card, Singularity.Motion.Preset.SCALE_FADE);
            if (source == 0) schedule_grace(1500);
        }

        public SnapZone? hover_layout_point(int x, int y, out SnapLayout? layout) {
            layout = null;
            SnapZone? found = null;
            foreach (var tile in tiles) {
                Graphene.Point origin;
                if (!tile.compute_point(this, Graphene.Point() { x = 0, y = 0 }, out origin)) {
                    tile.set_hovered(null);
                    continue;
                }
                int lx = x - _surface.x - (int) origin.x;
                int ly = y - _surface.y - (int) origin.y;
                var zone = tile.zone_at(lx, ly);
                tile.set_hovered(zone);
                if (zone != null && found == null) {
                    found = zone;
                    layout = tile.layout;
                }
            }
            return found;
        }

        public void button_left() {
            _button_hovered = false;
            if (_source == 0 && !_pointer_inside) schedule_grace();
        }

        private void schedule_grace(uint ms = GRACE_MS) {
            cancel_grace();
            _grace_id = Timeout.add(ms, () => {
                _grace_id = 0;
                if (!_pointer_inside && !_button_hovered) dismiss();
                return Source.REMOVE;
            });
        }

        private void cancel_grace() {
            if (_grace_id != 0) {
                Source.remove(_grace_id);
                _grace_id = 0;
            }
        }

        public void dismiss() {
            cancel_grace();
            if (!visible || _closing) return;
            _closing = true;
            foreach (var tile in tiles) tile.set_hovered(null);
            var anim = Singularity.Motion.conceal(card, Singularity.Motion.Preset.SCALE_FADE);
            anim.done.connect(() => {
                if (!_closing) return;
                _closing = false;
                close_layer_window(this);
                closed();
            });
        }
    }
}
