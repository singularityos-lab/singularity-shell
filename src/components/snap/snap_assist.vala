using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class SnapAssist : Gtk.Window {
        private const int ZONE_INSET = 8;
        private const int THUMB_W = 220;
        private const int THUMB_H = 138;

        public signal void window_chosen(void* handle, SnapZone zone);

        private Fixed stage;
        private SnapRect _area;
        private Gdk.Rectangle _monitor_geometry;
        private SnapZone[] _zones = {};
        private int _zone_index = 0;
        private Gee.ArrayList<AppSystem.Window> _candidates = new Gee.ArrayList<AppSystem.Window>();
        private Widget[] _zone_widgets = {};
        private Widget[] _cards = {};
        private bool _closing = false;

        public bool is_open { get { return visible && !_closing; } }

        public SnapAssist(Gtk.Application app) {
            Object(application: app);
            init_for_window(this);
            set_namespace(this, "singularity-snap-assist");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("snap-assist-window");

            stage = new Fixed();
            stage.hexpand = true;
            stage.vexpand = true;
            set_child(stage);

            var click = new GestureClick();
            click.released.connect((n, x, y) => {
                var picked = stage.pick(x, y, PickFlags.DEFAULT);
                if (picked == null || picked == stage) dismiss();
            });
            stage.add_controller(click);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Escape) {
                    dismiss();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget) this).add_controller(keys);
        }

        public bool open(Gdk.Monitor? monitor, SnapRect area, SnapZone[] zones, void* snapped) {
            _closing = false;
            _area = area;
            _zones = zones;
            _zone_index = 0;
            _candidates.clear();
            foreach (var win in AppSystem.get_default().get_active_workspace_windows()) {
                if (win.handle == snapped || win.is_fullscreen) continue;
                _candidates.add(win);
            }
            if (_zones.length == 0 || _candidates.size == 0) return false;
            _monitor_geometry = { area.x, area.y, area.width, area.height };
            if (monitor != null) {
                _monitor_geometry = monitor.geometry;
                set_monitor(this, monitor);
            }
            present();
            build_zones();
            return true;
        }

        private SnapRect local_rect(SnapZone zone) {
            var r = zone.rect_in(_area);
            return SnapRect(r.x - _monitor_geometry.x + ZONE_INSET, r.y - _monitor_geometry.y + ZONE_INSET,
                r.width - ZONE_INSET * 2, r.height - ZONE_INSET * 2);
        }

        private void clear_zones() {
            foreach (var w in _zone_widgets) stage.remove(w);
            _zone_widgets = {};
        }

        private void build_zones() {
            clear_zones();
            _cards = {};
            for (int i = _zone_index; i < _zones.length; i++) {
                var rect = local_rect(_zones[i]);
                var zone_box = new Box(Orientation.VERTICAL, 12);
                zone_box.add_css_class("snap-assist-zone");
                zone_box.set_size_request(int.max(rect.width, 40), int.max(rect.height, 40));
                if (i == _zone_index) {
                    zone_box.add_css_class("active");
                    zone_box.append(build_cards(rect));
                }
                var bin = new Singularity.Animation.MotionBin(zone_box);
                stage.put(bin, rect.x, rect.y);
                _zone_widgets += bin;
                Singularity.Motion.reveal(zone_box, Singularity.Motion.Preset.FADE);
            }
            if (_cards.length > 0) {
                Singularity.Motion.cascade(_cards, Singularity.Motion.Preset.SCALE_FADE);
            }
        }

        private Widget build_cards(SnapRect rect) {
            var flow = new FlowBox();
            flow.add_css_class("snap-assist-grid");
            flow.selection_mode = SelectionMode.NONE;
            flow.activate_on_single_click = true;
            flow.homogeneous = true;
            flow.column_spacing = 12;
            flow.row_spacing = 12;
            flow.valign = Align.CENTER;
            flow.halign = Align.CENTER;
            uint columns = uint.max(1, (uint) ((rect.width - 40) / (THUMB_W + 32)));
            columns = uint.min(columns, (uint) _candidates.size);
            flow.min_children_per_line = columns;
            flow.max_children_per_line = columns;
            foreach (var win in _candidates) {
                var card = build_card(win);
                var bin = new Singularity.Animation.MotionBin(card);
                var child = new FlowBoxChild();
                child.halign = Align.CENTER;
                child.set_child(bin);
                child.set_data<AppSystem.Window>("snap-window", win);
                flow.append(child);
                _cards += card;
            }
            flow.child_activated.connect((child) => {
                var win = child.get_data<AppSystem.Window>("snap-window");
                if (win != null) choose(win);
            });
            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroller.vexpand = true;
            scroller.set_child(flow);
            return scroller;
        }

        private Widget build_card(AppSystem.Window win) {
            var card = new Box(Orientation.VERTICAL, 8);
            card.add_css_class("snap-assist-card");
            card.width_request = THUMB_W;
            card.halign = Align.CENTER;

            var header = new Box(Orientation.HORIZONTAL, 8);
            var icon = new Image();
            icon.pixel_size = 24;
            if (win.gicon != null) icon.gicon = win.gicon;
            else icon.icon_name = win.icon_name;
            header.append(icon);
            var title = new Label(win.title);
            title.ellipsize = Pango.EllipsizeMode.END;
            title.hexpand = true;
            title.halign = Align.START;
            title.add_css_class("snap-assist-card-title");
            header.append(title);
            card.append(header);

            var frame = new Box(Orientation.VERTICAL, 0);
            frame.add_css_class("snap-assist-thumb");
            frame.set_size_request(THUMB_W, THUMB_H);
            frame.hexpand = false;
            frame.vexpand = false;
            frame.overflow = Overflow.HIDDEN;
            var picture = new Picture();
            picture.content_fit = ContentFit.CONTAIN;
            picture.can_shrink = true;
            picture.hexpand = true;
            picture.vexpand = true;
            var placeholder = new Image();
            placeholder.pixel_size = 64;
            if (win.gicon != null) placeholder.gicon = win.gicon;
            else placeholder.icon_name = win.icon_name;
            placeholder.vexpand = true;
            frame.append(placeholder);
            PreviewCache.get_default().request(win.handle, THUMB_W, THUMB_H, (texture) => {
                if (texture == null || _closing) return;
                picture.paintable = texture;
                frame.remove(placeholder);
                frame.append(picture);
            });
            card.append(frame);
            return card;
        }

        private void choose(AppSystem.Window win) {
            if (_zone_index >= _zones.length) return;
            var zone = _zones[_zone_index];
            window_chosen(win.handle, zone);
            _candidates.remove(win);
            _zone_index++;
            if (_zone_index >= _zones.length || _candidates.size == 0) {
                dismiss();
                return;
            }
            build_zones();
        }

        public void dismiss() {
            if (!visible || _closing) return;
            _closing = true;
            if (_zone_widgets.length == 0) {
                finish_dismiss();
                return;
            }
            Singularity.Animation.AnimationGroup? last = null;
            foreach (var w in _zone_widgets) {
                last = Singularity.Motion.conceal(w, Singularity.Motion.Preset.FADE);
            }
            last.done.connect(finish_dismiss);
        }

        private void finish_dismiss() {
            if (!_closing) return;
            _closing = false;
            clear_zones();
            close_layer_window(this);
        }
    }
}
