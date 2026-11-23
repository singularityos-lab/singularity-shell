using Gtk;
using Singularity.Calendar;

namespace Singularity {

    public class HubAgenda : Widget {
        private const int DAYS = 7;
        private const int MAX_HEIGHT = 360;

        private Box _content;
        private Singularity.Widgets.CalendarAgenda _agenda;
        private ScrolledWindow _scroller;
        private Label _empty;
        private double _reveal = 0;
        private bool _stale = true;
        private bool _loading = false;

        public signal void event_activated(CalendarEvent evt);

        public double reveal {
            get { return _reveal; }
            set {
                double v = double.max(0, value);
                if (_reveal == v) return;
                bool opening = _reveal <= 0 && v > 0;
                _reveal = v;
                _content.can_target = v > 0;
                if (opening && _stale) load.begin();
                queue_resize();
            }
        }

        public HubAgenda() {
            add_css_class("hub-agenda");
            overflow = Overflow.HIDDEN;
            _agenda = new Singularity.Widgets.CalendarAgenda();
            _agenda.compact = true;
            _agenda.margin_start = 12;
            _agenda.margin_end = 12;
            _agenda.event_activated.connect((evt, row) => event_activated(evt));
            _scroller = new ScrolledWindow();
            _scroller.hscrollbar_policy = PolicyType.NEVER;
            _scroller.propagate_natural_height = true;
            _scroller.max_content_height = MAX_HEIGHT;
            _scroller.child = _agenda;
            _empty = new Label(_("Nothing planned in the next 7 days"));
            _empty.add_css_class("dim-label");
            _empty.margin_top = 16;
            _empty.margin_bottom = 16;
            _empty.visible = false;
            _content = new Box(Orientation.VERTICAL, 0);
            _content.margin_bottom = 12;
            _content.append(_scroller);
            _content.append(_empty);
            _content.can_target = false;
            _content.set_parent(this);
            CalendarManager.get_default().events_changed.connect(() => {
                _stale = true;
                if (_reveal > 0) load.begin();
            });
        }

        public override void dispose() {
            if (_content != null) {
                _content.unparent();
                _content = null;
            }
            base.dispose();
        }

        public int open_height() {
            int min, nat;
            _content.measure(Orientation.VERTICAL, int.max(1, get_width()), out min, out nat, null, null);
            return int.max(min, nat);
        }

        private async void load() {
            if (_loading) return;
            _loading = true;
            _stale = false;
            var now = new DateTime.now_local();
            var from = Singularity.Widgets.CalendarLayout.day_start(now);
            var events = yield CalendarManager.get_default().get_events(from, from.add_days(DAYS));
            var upcoming = new Gee.ArrayList<CalendarEvent?>();
            foreach (var evt in events) {
                if (evt.end_time != null && evt.end_time.compare(now) <= 0 && !evt.all_day) continue;
                upcoming.add(evt);
            }
            upcoming.sort((a, b) => a.start_time.compare(b.start_time));
            _agenda.show_events(upcoming);
            _scroller.visible = upcoming.size > 0;
            _empty.visible = upcoming.size == 0;
            _loading = false;
            queue_resize();
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (orientation == Orientation.HORIZONTAL) {
                int min, nat;
                _content.measure(orientation, -1, out min, out nat, null, null);
                minimum = 0;
                natural = nat;
                return;
            }
            minimum = (int) Math.round(_reveal);
            natural = minimum;
        }

        public override void size_allocate(int width, int height, int baseline) {
            _content.allocate(width, int.max(open_height(), height), -1, null);
        }
    }
}
