using Gtk;
using GtkLayerShell;
using Gee;

namespace Singularity {

    public class WorkspaceSwitchFeedback : Gtk.Window {
        private const int ACTIVE_WIDTH = 26;
        private const int INACTIVE_WIDTH = 10;
        private const double ACTIVE_OPACITY = 1.0;
        private const double INACTIVE_OPACITY = 0.22;
        private Box card;
        private Box marker_box;
        private ArrayList<Box> markers = new ArrayList<Box>();
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
            marker_box = new Box(Orientation.HORIZONTAL, 6);
            marker_box.halign = Align.CENTER;
            marker_box.valign = Align.CENTER;
            card.append(marker_box);
            set_child(card);

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
            if (markers.size < 2 || active_index < 0) return;
            cancel_hide();
            animation?.reset();
            from_index = active_index;
            target_index = direction == 1
                ? (active_index + 1) % markers.size
                : (active_index - 1 + markers.size) % markers.size;
            gesture_active = true;
            set_progress(0);
            show_feedback();
        }

        private void finish_gesture(bool committed) {
            double start = transition_progress();
            double target = committed ? 1.0 : 0.0;
            var settle = new Singularity.Animation.TimedAnimation(
                marker_box, start, target, 192,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
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
            if (count != markers.size) rebuild_markers(count);
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
            while (marker_box.get_first_child() != null)
                marker_box.remove(marker_box.get_first_child());
            markers.clear();
            for (int i = 0; i < count; i++) {
                var marker = new Box(Orientation.HORIZONTAL, 0);
                marker.add_css_class("workspace-switch-marker");
                marker.set_size_request(INACTIVE_WIDTH, 10);
                marker_box.append(marker);
                markers.add(marker);
            }
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
            var transition = new Singularity.Animation.TimedAnimation(
                marker_box, 0, 1, 220,
                Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC);
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
            for (int i = 0; i < markers.size; i++) {
                if (i == from_index) {
                    apply_marker(markers[i], 1.0 - progress);
                } else if (i == target_index) {
                    apply_marker(markers[i], progress);
                } else {
                    apply_marker(markers[i], 0);
                }
            }
        }

        private double transition_progress() {
            if (from_index < 0 || from_index >= markers.size) return 0;
            return (ACTIVE_WIDTH - markers[from_index].width_request)
                / (double)(ACTIVE_WIDTH - INACTIVE_WIDTH);
        }

        private void apply_marker(Box marker, double active) {
            marker.set_size_request((int)Math.round(INACTIVE_WIDTH
                + (ACTIVE_WIDTH - INACTIVE_WIDTH) * active), 10);
            marker.opacity = INACTIVE_OPACITY
                + (ACTIVE_OPACITY - INACTIVE_OPACITY) * active;
        }

        private void set_resting_state() {
            for (int i = 0; i < markers.size; i++)
                apply_marker(markers[i], i == active_index ? 1 : 0);
        }

        private void show_feedback() {
            card.remove_css_class("closing");
            card.add_css_class("opening");
            present();
            Idle.add(() => {
                card.remove_css_class("opening");
                return Source.REMOVE;
            });
        }

        private void schedule_hide() {
            cancel_hide();
            hide_timeout_id = Timeout.add(420, () => {
                hide_timeout_id = 0;
                card.add_css_class("closing");
                hide_timeout_id = Timeout.add(150, () => {
                    hide_timeout_id = 0;
                    visible = false;
                    card.remove_css_class("closing");
                    return Source.REMOVE;
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
