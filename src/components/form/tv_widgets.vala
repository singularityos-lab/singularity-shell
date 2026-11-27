using Gtk;
using GtkLayerShell;

namespace Singularity {

    internal class TvWidgetCard : Box {
        public string instance_id { get; construct; }
        public string provider_id { get; construct; }

        private Overlay _frame;
        private Widget _skeleton;
        private bool _built = false;
        private WidgetSize _size;
        private Variant? _config;

        public TvWidgetCard(AppSystem.OverviewWidgetInstance inst, WidgetSize size) {
            Object(instance_id: inst.instance_id, provider_id: inst.provider_id, orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("tv-widget");
            focusable = true;
            overflow = Overflow.HIDDEN;
            hexpand = false;
            vexpand = false;
            halign = Align.START;
            valign = Align.START;
            _size = size;
            set_size_request(TvWidgetRow.span(size.w), TvWidgetRow.span(size.h));
            if (inst.config_json != "") {
                try {
                    _config = Variant.parse(null, inst.config_json);
                } catch (Error e) {
                    _config = null;
                }
            }
            _skeleton = new Box(Orientation.VERTICAL, 0);
            _skeleton.add_css_class("overview-widget-loading");
            _frame = new Overlay();
            _frame.child = _skeleton;
            _frame.can_focus = false;
            _frame.hexpand = true;
            _frame.vexpand = true;
            append(_frame);
            update_property(Gtk.AccessibleProperty.LABEL, label_for(provider_id), -1);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                switch (keyval) {
                    case Gdk.Key.Return:
                    case Gdk.Key.KP_Enter:
                    case Gdk.Key.space:
                    case Gdk.Key.ISO_Enter:
                        open_app();
                        return true;
                    default:
                        return false;
                }
            });
            add_controller(keys);
        }

        public void build() {
            if (_built) return;
            _built = true;
            var provider = OverviewWidgetRegistry.get_default().find(provider_id);
            if (provider == null) return;
            var content = provider.create_instance(instance_id, _size, _config);
            if (content == null) return;
            content.hexpand = true;
            content.vexpand = true;
            _frame.add_overlay(content);
            if (get_mapped()) Singularity.Motion.crossfade(_skeleton, content);
            else _skeleton.visible = false;
        }

        private void open_app() {
            var provider = OverviewWidgetRegistry.get_default().find(provider_id);
            if (provider == null) return;
            string id = provider.provider_id;
            var info = new GLib.DesktopAppInfo(id.has_suffix(".desktop") ? id : id + ".desktop");
            if (info != null) AppSystem.launch_app(info);
        }

        private static string label_for(string provider_id) {
            var provider = OverviewWidgetRegistry.get_default().find(provider_id);
            return provider != null ? provider.display_name : provider_id;
        }
    }

    internal class TvWidgetRow : Box {
        public const int UNIT = 150;
        public const int GAP = 24;
        private const int MAX_W = 4;
        private const int MAX_H = 2;

        private Box _cards;
        private ScrolledWindow _scroll;
        private FlowBox _edit_row;
        private GLib.Settings _settings;
        private ulong _sig_settings = 0;
        private ulong _sig_registry = 0;
        private uint _build_source = 0;
        private GLib.Queue<TvWidgetCard> _pending = new GLib.Queue<TvWidgetCard>();

        public signal void edit();
        public signal bool leave_up();

        public static int span(int units) {
            return UNIT * units + GAP * (units - 1);
        }

        public TvWidgetRow(int gutter) {
            Object(orientation: Orientation.HORIZONTAL, spacing: GAP);
            add_css_class("tv-widget-row");
            _cards = new Box(Orientation.HORIZONTAL, GAP);
            _cards.valign = Align.START;
            _edit_row = TvHome.new_row();
            _edit_row.valign = Align.START;
            _edit_row.min_children_per_line = 1;
            _edit_row.max_children_per_line = 1;
            var tile = TvHome.tile(new ThemedIcon("list-add-symbolic"), "list-add-symbolic", _("Edit Widgets"), true);
            _edit_row.append(tile);
            _edit_row.child_activated.connect(() => edit());
            _edit_row.keynav_failed.connect((direction) => direction == DirectionType.RIGHT);

            var strip = new Box(Orientation.HORIZONTAL, GAP);
            strip.margin_start = gutter;
            strip.margin_end = gutter;
            strip.append(_cards);
            strip.append(_edit_row);
            _scroll = new ScrolledWindow();
            _scroll.hscrollbar_policy = PolicyType.EXTERNAL;
            _scroll.vscrollbar_policy = PolicyType.NEVER;
            _scroll.propagate_natural_height = true;
            _scroll.hexpand = true;
            _scroll.child = strip;
            append(_scroll);

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval == Gdk.Key.Up) return leave_up();
                if (keyval == Gdk.Key.Down) return true;
                return false;
            });
            add_controller(keys);


            _settings = new GLib.Settings("dev.sinty.desktop");
            _sig_settings = _settings.changed["overview-widgets"].connect(() => fill());
            var registry = OverviewWidgetRegistry.get_default();
            registry.load_manifests();
            _sig_registry = registry.changed.connect(() => fill());
            map.connect(() => schedule_builds());
            fill();
        }

        public bool focus_nearest(Widget origin) {
            var root = get_root() as Widget;
            if (root == null) return focus_first();
            Graphene.Rect from;
            if (!origin.compute_bounds(root, out from)) return focus_first();
            float x = from.get_x() + from.get_width() / 2;
            Widget? best = null;
            float best_distance = float.MAX;
            Widget[] candidates = {};
            for (var c = _cards.get_first_child(); c != null; c = c.get_next_sibling()) candidates += c;
            var tile = _edit_row.get_child_at_index(0);
            if (tile != null) candidates += tile;
            foreach (var c in candidates) {
                Graphene.Rect b;
                if (!c.compute_bounds(root, out b)) continue;
                float d = Math.fabsf(b.get_x() + b.get_width() / 2 - x);
                if (d < best_distance) {
                    best_distance = d;
                    best = c;
                }
            }
            return best != null ? best.grab_focus() : focus_first();
        }

        public bool focus_first() {
            var first = _cards.get_first_child();
            if (first != null) return first.grab_focus();
            var tile = _edit_row.get_child_at_index(0);
            return tile != null && tile.grab_focus();
        }

        public static WidgetSize fit(OverviewWidgetProvider provider, int w, int h) {
            if (w >= 1 && h >= 1 && w <= MAX_W && h <= MAX_H) {
                foreach (var s in provider.supported_sizes) {
                    if (s.w == w && s.h == h) return s;
                }
            }
            WidgetSize best = WidgetSize(0, 0);
            foreach (var s in provider.supported_sizes) {
                if (s.w > MAX_W || s.h > MAX_H) continue;
                int area = s.w * s.h;
                int best_area = best.w * best.h;
                if (area > best_area || (area == best_area && s.h > best.h)) best = s;
            }
            if (best.w == 0) {
                foreach (var s in provider.supported_sizes) {
                    if (best.w == 0 || s.w * s.h < best.w * best.h) best = s;
                }
            }
            if (best.w == 0) best = WidgetSize(2, 2);
            return WidgetSize(int.min(best.w, MAX_W), int.min(best.h, MAX_H));
        }

        private void fill() {
            _pending.clear();
            Widget? w;
            while ((w = _cards.get_first_child()) != null) _cards.remove(w);
            var registry = OverviewWidgetRegistry.get_default();
            foreach (var inst in AppSystem.get_default().get_overview_widgets()) {
                var provider = registry.find(inst.provider_id);
                if (provider == null) continue;
                var card = new TvWidgetCard(inst, fit(provider, inst.w, inst.h));
                _cards.append(card);
                _pending.push_tail(card);
            }
            schedule_builds();
        }

        private void schedule_builds() {
            if (_build_source != 0 || _pending.is_empty() || !get_mapped()) return;
            _build_source = Idle.add(() => {
                var card = _pending.pop_head();
                if (card != null && card.get_parent() == _cards) card.build();
                if (!_pending.is_empty() && get_mapped()) return Source.CONTINUE;
                _build_source = 0;
                return Source.REMOVE;
            }, Priority.DEFAULT_IDLE);
        }

        public override void dispose() {
            if (_build_source != 0) {
                Source.remove(_build_source);
                _build_source = 0;
            }
            if (_sig_settings != 0) {
                _settings.disconnect(_sig_settings);
                _sig_settings = 0;
            }
            if (_sig_registry != 0) {
                OverviewWidgetRegistry.get_default().disconnect(_sig_registry);
                _sig_registry = 0;
            }
            base.dispose();
        }
    }

    public class TvWidgetPicker : Gtk.Window {
        private const int HEAD_ICON = 88;
        private const string ACTION = "tv-widget";

        private FlowBox _grid;
        private Singularity.Animation.MotionBin _stage;
        private bool _closing = false;
        private GLib.Settings _settings;
        private ulong _sig_settings = 0;

        public signal void dismissed();

        public TvWidgetPicker(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            init_for_window(this);
            set_monitor(this, monitor);
            set_namespace(this, "singularity-tv-widgets");
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            foreach (var edge in new GtkLayerShell.Edge[] { Edge.TOP, Edge.BOTTOM, Edge.LEFT, Edge.RIGHT }) set_anchor(this, edge, true);
            set_exclusive_zone(this, -1);
            set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("tv-settings");

            var page = new Box(Orientation.VERTICAL, 0);
            page.add_css_class("tv-home-page");
            var head = new Box(Orientation.HORIZONTAL, 24);
            head.add_css_class("tv-home-head");
            var icon = new Image.from_icon_name("dev.sinty.widgets");
            icon.pixel_size = HEAD_ICON;
            var title = new Label(_("Widgets"));
            title.add_css_class("tv-home-title");
            title.xalign = 0;
            title.valign = Align.CENTER;
            head.append(icon);
            head.append(title);
            page.append(head);

            _grid = TvHome.new_row();
            _grid.valign = Align.START;
            _grid.child_activated.connect((child) => toggle(child));
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = _grid;
            page.append(scroll);

            _stage = new Singularity.Animation.MotionBin(page);
            set_child(_stage);

            var keys = new EventControllerKey();
            keys.propagation_phase = PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape && keyval != Gdk.Key.BackSpace) return false;
                dismiss();
                return true;
            });
            ((Widget) this).add_controller(keys);

            _settings = new GLib.Settings("dev.sinty.desktop");
            _sig_settings = _settings.changed["overview-widgets"].connect(() => mark());
            fill();
        }

        public override void dispose() {
            if (_sig_settings != 0) {
                _settings.disconnect(_sig_settings);
                _sig_settings = 0;
            }
            base.dispose();
        }

        private void fill() {
            Widget? w;
            while ((w = _grid.get_first_child()) != null) _grid.remove(w);
            var providers = OverviewWidgetRegistry.get_default().list();
            var sorted = new GLib.List<OverviewWidgetProvider>();
            foreach (var p in providers) sorted.append(p);
            sorted.sort((a, b) => a.display_name.collate(b.display_name));
            foreach (var p in sorted) {
                var child = TvHome.tile(new ThemedIcon(p.icon_name), p.icon_name, p.display_name);
                child.set_data<string>(ACTION, p.id);
                _grid.append(child);
            }
            mark();
        }

        private string? instance_of(string provider_id) {
            foreach (var inst in AppSystem.get_default().get_overview_widgets()) {
                if (inst.provider_id == provider_id) return inst.instance_id;
            }
            return null;
        }

        private void mark() {
            for (var c = _grid.get_first_child(); c != null; c = c.get_next_sibling()) {
                var id = c.get_data<string>(ACTION);
                if (id == null) continue;
                bool added = instance_of(id) != null;
                TvHome.set_tile_checked((FlowBoxChild) c, added);
                var provider = OverviewWidgetRegistry.get_default().find(id);
                string name = provider != null ? provider.display_name : id;
                c.update_property(Gtk.AccessibleProperty.LABEL, added ? _("%s, on the home screen").printf(name) : name, -1);
            }
        }

        private void toggle(FlowBoxChild child) {
            var id = child.get_data<string>(ACTION);
            if (id == null) return;
            var apps = AppSystem.get_default();
            var existing = instance_of(id);
            if (existing != null) {
                apps.remove_overview_widget(existing);
                return;
            }
            var provider = OverviewWidgetRegistry.get_default().find(id);
            if (provider == null) return;
            var size = TvWidgetRow.fit(provider, 0, 0);
            apps.add_overview_widget(id, size.w, size.h);
        }

        public void open() {
            _closing = false;
            present();
            var first = _grid.get_child_at_index(0);
            if (first != null) first.grab_focus();
            if (Singularity.Motion.reduced()) return;
            _stage.opacity = 0.0;
            _stage.scale = 1.04;
            Singularity.Motion.tween(_stage, "opacity", 1.0, Singularity.Motion.Duration.MEDIUM, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.spring_to(_stage, "scale", 1.0, Singularity.Motion.Spring.GENTLE);
        }

        public void dismiss() {
            if (_closing) return;
            _closing = true;
            var fade = Singularity.Motion.tween(_stage, "opacity", 0.0,
                Singularity.Motion.Duration.SMALL.exit_ms(), Singularity.Motion.Curve.EXIT);
            fade.done.connect(() => {
                close_layer_window(this);
                dismissed();
            });
        }
    }
}
