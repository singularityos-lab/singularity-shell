using Gtk;

namespace Singularity {

    public class HubCard : Box {
        private const double BACK_COMMIT = 0.3;
        private const double BACK_FLING = 900.0;
        private const double SLOP = 12.0;

        public Hub.Item item { get; construct; }
        public Singularity.Animation.MotionBin frame { get; private set; }

        private HubStore store;
        private bool _dragging = false;
        private GestureSwipe _velocity;

        public signal void closed();

        public bool docked { get; construct; }

        public HubCard(Hub.Item item, Widget icon, bool docked = false) {
            Object(item: item, docked: docked, orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("hub-card");
            store = HubStore.get_default();

            var header = new Box(Orientation.HORIZONTAL, 10);
            header.add_css_class("hub-card-header");
            var back = new Button.from_icon_name("go-previous-symbolic");
            back.add_css_class("flat");
            back.tooltip_text = _("Back to Hub");
            back.valign = Align.CENTER;
            back.clicked.connect(() => dismiss());
            back.visible = !docked;
            header.append(back);
            icon.valign = Align.CENTER;
            header.append(icon);
            var who = new Box(Orientation.VERTICAL, 0);
            who.hexpand = true;
            who.valign = Align.CENTER;
            var sender = new Label(item.sender);
            sender.add_css_class("heading");
            sender.xalign = 0;
            sender.ellipsize = Pango.EllipsizeMode.END;
            who.append(sender);
            var when = new Label(new DateTime.from_unix_local(item.timestamp).format("%e %B %Y, %H:%M").strip());
            when.add_css_class("dim-label");
            when.add_css_class("caption");
            when.xalign = 0;
            who.append(when);
            header.append(who);
            if (item.app_id != "" && !HubStore.from_notifications(item.account)) {
                var open = new Button.from_icon_name("view-paged-symbolic");
                open.add_css_class("flat");
                open.tooltip_text = _("Open in App");
                open.valign = Align.CENTER;
                open.clicked.connect(() => store.open(item));
                header.append(open);
            }
            append(header);

            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.vexpand = true;
            scroller.child = Hub.Cards.build(item);
            append(scroller);

            var actions = store.actions_for(item);
            if (actions.size > 0) {
                var bar = new Box(Orientation.HORIZONTAL, 8);
                bar.add_css_class("hub-card-actions");
                bar.homogeneous = true;
                foreach (var a in actions) {
                    var action = a;
                    var content = new Box(Orientation.HORIZONTAL, 6);
                    content.halign = Align.CENTER;
                    if (action.icon_name != "") content.append(new Image.from_icon_name(action.icon_name));
                    var label = new Label(action.label);
                    label.ellipsize = Pango.EllipsizeMode.END;
                    content.append(label);
                    var b = new Button();
                    b.add_css_class("pill");
                    b.child = content;
                    b.clicked.connect(() => store.invoke(item, action.id));
                    bar.append(b);
                }
                append(bar);
            }

            frame = new Singularity.Animation.MotionBin(this);
            frame.transform_input = true;
            if (!docked) install_back_swipe();
        }

        public void present_from(double width) {
            frame.translate_x = width;
            Singularity.Motion.spring_to(frame, "translate-x", 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        public void dismiss(double velocity = 0.0) {
            if (docked) {
                closed();
                return;
            }
            double width = double.max(1.0, get_width());
            var anim = Singularity.Motion.spring_to(frame, "translate-x", width, Singularity.Motion.Spring.SNAPPY, velocity);
            anim.clamp = true;
            anim.done.connect(() => closed());
        }

        private void install_back_swipe() {
            var drag = new GestureDrag();
            drag.propagation_phase = PropagationPhase.CAPTURE;
            drag.drag_begin.connect(() => {
                _dragging = false;
            });
            drag.drag_update.connect((dx, dy) => {
                if (!_dragging) {
                    if (dx < SLOP || Math.fabs(dx) < Math.fabs(dy) * 1.2) return;
                    _dragging = true;
                    drag.set_state(EventSequenceState.CLAIMED);
                    Singularity.Motion.cancel(frame, "translate-x");
                }
                frame.translate_x = double.max(0.0, dx);
            });
            drag.drag_end.connect((dx, dy) => {
                if (!_dragging) return;
                _dragging = false;
                double vx = 0, vy = 0;
                if (!_velocity.get_velocity(out vx, out vy)) vx = 0;
                double width = double.max(1.0, get_width());
                bool leave = frame.translate_x > width * BACK_COMMIT;
                if (vx > BACK_FLING) leave = true;
                else if (vx < -BACK_FLING) leave = false;
                if (leave) {
                    dismiss(vx);
                } else {
                    Singularity.Motion.spring_to(frame, "translate-x", 0.0, Singularity.Motion.Spring.SNAPPY, vx);
                }
            });
            drag.cancel.connect(() => {
                if (!_dragging) return;
                _dragging = false;
                Singularity.Motion.spring_to(frame, "translate-x", 0.0, Singularity.Motion.Spring.SNAPPY);
            });
            frame.add_controller(drag);
            _velocity = new GestureSwipe();
            _velocity.propagation_phase = PropagationPhase.CAPTURE;
            frame.add_controller(_velocity);
        }
    }
}
