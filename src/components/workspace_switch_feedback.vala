using Gtk;
using GtkLayerShell;
using Gee;

namespace Singularity {

    private class WorkspaceMarkers : Gtk.Widget {
        private const int ACTIVE_WIDTH = 26;
        private const int INACTIVE_WIDTH = 10;
        private const int HEIGHT = 10;
        private const int GAP = 6;
        private const double ACTIVE_OPACITY = 1.0;
        private const double INACTIVE_OPACITY = 0.22;
        private double[] levels = {};

        public int count {
            get { return levels.length; }
        }

        construct {
            add_css_class("workspace-switch-markers");
        }

        public void set_count(int value) {
            levels = new double[value];
            queue_resize();
        }

        public double get_level(int index) {
            return index >= 0 && index < levels.length ? levels[index] : 0.0;
        }

        public void set_level(int index, double value) {
            if (index < 0 || index >= levels.length || levels[index] == value) return;
            levels[index] = value;
            queue_draw();
        }

        private int content_width() {
            if (levels.length == 0) return 0;
            return levels.length * INACTIVE_WIDTH + (ACTIVE_WIDTH - INACTIVE_WIDTH)
                + (levels.length - 1) * GAP;
        }

        public override Gtk.SizeRequestMode get_request_mode() {
            return Gtk.SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Gtk.Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum = natural = orientation == Gtk.Orientation.HORIZONTAL ? content_width() : HEIGHT;
            minimum_baseline = natural_baseline = -1;
        }

        public override void snapshot(Gtk.Snapshot snapshot) {
            var color = get_color();
            float x = (float) ((get_width() - content_width()) / 2.0);
            float y = (float) ((get_height() - HEIGHT) / 2.0);
            foreach (double level in levels) {
                float width = (float) (INACTIVE_WIDTH + (ACTIVE_WIDTH - INACTIVE_WIDTH) * level);
                var rect = Graphene.Rect().init(x, y, width, HEIGHT);
                var rounded = Gsk.RoundedRect().init_from_rect(rect, HEIGHT / 2.0f);
                var fill = color;
                fill.alpha = (float) (color.alpha * (INACTIVE_OPACITY
                    + (ACTIVE_OPACITY - INACTIVE_OPACITY) * level));
                snapshot.push_rounded_clip(rounded);
                snapshot.append_color(fill, rect);
                snapshot.pop();
                x += width + GAP;
            }
        }
    }

    public class WorkspaceSwitchFeedback : Gtk.Window {
        private const double OPEN_SCALE = 0.82;
        private const double CLOSE_SCALE = 0.9;
        private const int SHADOW_SPACE = 40;
        private Box card;
        private Singularity.Animation.MotionBin card_motion;
        private bool closing = false;
        private WorkspaceMarkers markers;
        private AppSystem app_system;
        private int active_index = -1;
        private int from_index = -1;
        private int target_index = -1;
        private bool gesture_active = false;
        private uint hide_timeout_id = 0;
        private ulong workspaces_changed_id = 0;
        private Gdk.Monitor monitor;
        private Singularity.Animation.TimedAnimation? animation;

        public WorkspaceSwitchFeedback(Gtk.Application app, Gdk.Monitor monitor) {
            Object(application: app);
            app_system = AppSystem.get_default();
            this.monitor = monitor;

            GtkLayerShell.init_for_window(this);
            GtkLayerShell.set_namespace(this, "singularity-workspace-switch");
            GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_exclusive_zone(this, -1);
            GtkLayerShell.set_keyboard_mode(this,
                GtkLayerShell.KeyboardMode.NONE);
            GtkLayerShell.set_monitor(this, monitor);

            add_css_class("singularity");
            add_css_class("workspace-switch-feedback-window");

            card = new Box(Orientation.HORIZONTAL, 0);
            card.add_css_class("workspace-switch-feedback");
            markers = new WorkspaceMarkers();
            markers.halign = Align.CENTER;
            markers.valign = Align.CENTER;
            card.append(markers);
            card_motion = new Singularity.Animation.MotionBin(card);
            card_motion.margin_top = SHADOW_SPACE;
            card_motion.margin_bottom = SHADOW_SPACE;
            card_motion.margin_start = SHADOW_SPACE;
            card_motion.margin_end = SHADOW_SPACE;
            set_child(card_motion);

            map.connect(() => {
                var surface = get_surface();
                if (surface != null)
                    surface.set_input_region(new Cairo.Region());
            });

            sync_workspace_state(false);
            workspaces_changed_id = app_system.workspaces_changed.connect(() => {
                sync_workspace_state(true);
            });
        }

        public void handle_gesture(uint32 phase, uint32 direction,
                                   double dx, bool cancelled,
                                   bool committed) {
            if (direction != 1 && direction != 2) return;
            if (phase == 0) {
                begin_gesture(direction);
            } else if (phase == 1 && gesture_active) {
                double width = workspace_span_width();
                double progress = width > 0
                    ? double.min(1.0, Math.fabs(dx) / width) : 0;
                set_progress(progress);
            } else if (phase == 2 && gesture_active) {
                finish_gesture(cancelled ? false : committed);
            }
        }

        private void begin_gesture(uint32 direction) {
            if (app_system.workspaces_per_monitor()
                    && app_system.get_active_monitor() != monitor) return;
            sync_workspace_state(false);
            if (markers.count < 2 || active_index < 0) return;
            cancel_hide();
            animation?.reset();
            from_index = active_index;
            target_index = direction == 1
                ? (active_index + 1) % markers.count
                : (active_index - 1 + markers.count) % markers.count;
            gesture_active = true;
            set_progress(0);
            show_feedback();
        }

        private void finish_gesture(bool committed) {
            double start = transition_progress();
            double target = committed ? 1.0 : 0.0;
            var settle = new Singularity.Animation.TimedAnimation.with_curve(
                markers, start, target, Singularity.Motion.Duration.MEDIUM.exit_ms(),
                Singularity.Motion.Curve.STANDARD);
            animation = settle;
            settle.tick.connect(() => set_progress(settle.value));
            settle.done.connect(() => {
                set_progress(target);
                if (committed) active_index = target_index;
                gesture_active = false;
                animation = null;
                schedule_hide();
            });
            settle.play();
        }

        private void sync_workspace_state(bool animate_change) {
            int count = 0;
            int next_active = -1;
            foreach (var workspace in app_system.get_workspaces_for_monitor(monitor)) {
                if (workspace.active) next_active = count;
                count++;
            }
            if (count != markers.count) rebuild_markers(count);
            if (next_active < 0) return;
            if (active_index < 0 || !animate_change || gesture_active) {
                active_index = next_active;
                if (!gesture_active) set_resting_state();
                return;
            }
            if (next_active == active_index) return;
            animate_workspace_change(active_index, next_active);
            active_index = next_active;
        }

        private void rebuild_markers(int count) {
            markers.set_count(count);
            if (active_index >= count) active_index = -1;
            set_resting_state();
        }

        private void animate_workspace_change(int from, int target) {
            cancel_hide();
            animation?.reset();
            from_index = from;
            target_index = target;
            set_progress(0);
            show_feedback();
            var transition = new Singularity.Animation.TimedAnimation.with_curve(
                markers, 0, 1, Singularity.Motion.Duration.MEDIUM,
                Singularity.Motion.Curve.STANDARD);
            animation = transition;
            transition.tick.connect(() => set_progress(transition.value));
            transition.done.connect(() => {
                set_progress(1);
                animation = null;
                schedule_hide();
            });
            transition.play();
        }

        private void set_progress(double progress) {
            progress = progress.clamp(0, 1);
            for (int i = 0; i < markers.count; i++) {
                if (i == from_index) {
                    markers.set_level(i, 1.0 - progress);
                } else if (i == target_index) {
                    markers.set_level(i, progress);
                } else {
                    markers.set_level(i, 0);
                }
            }
        }

        private double transition_progress() {
            if (from_index < 0 || from_index >= markers.count) return 0;
            return 1.0 - markers.get_level(from_index);
        }

        private void set_resting_state() {
            for (int i = 0; i < markers.count; i++)
                markers.set_level(i, i == active_index ? 1 : 0);
        }

        private void show_feedback() {
            bool appearing = !visible || closing;
            closing = false;
            present();
            if (!appearing) return;
            card_motion.opacity = 0.0;
            if (!Singularity.Motion.reduced()) card_motion.scale = OPEN_SCALE;
            Singularity.Motion.tween(card_motion, "opacity", 1.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
            Singularity.Motion.tween(card_motion, "scale", 1.0,
                Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.ENTER);
        }

        private void schedule_hide() {
            cancel_hide();
            hide_timeout_id = Timeout.add(420, () => {
                hide_timeout_id = 0;
                closing = true;
                Singularity.Motion.tween(card_motion, "scale", CLOSE_SCALE,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT);
                Singularity.Motion.tween(card_motion, "opacity", 0.0,
                    Singularity.Motion.Duration.SMALL, Singularity.Motion.Curve.EXIT).done.connect(() => {
                    if (!closing) return;
                    closing = false;
                    visible = false;
                    card_motion.reset_transform();
                });
                return Source.REMOVE;
            });
        }

        private void cancel_hide() {
            if (hide_timeout_id == 0) return;
            Source.remove(hide_timeout_id);
            hide_timeout_id = 0;
        }

        private double workspace_span_width() {
            var display = Gdk.Display.get_default();
            if (display == null) return 1;
            var monitors = display.get_monitors();
            if (monitors.get_n_items() == 0) return 1;
            int left = int.MAX;
            int right = int.MIN;
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;
                var geometry = monitor.get_geometry();
                left = int.min(left, geometry.x);
                right = int.max(right, geometry.x + geometry.width);
            }
            return int.max(1, right - left);
        }

        protected override void dispose() {
            cancel_hide();
            animation?.reset();
            if (workspaces_changed_id != 0) {
                SignalHandler.disconnect(app_system, workspaces_changed_id);
                workspaces_changed_id = 0;
            }
            base.dispose();
        }
    }
}
