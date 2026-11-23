using Gtk;

namespace Singularity {

    public class HubReveal : Widget {
        private Widget _child;
        private double _reveal = 0;
        private int _inset = 0;

        public int inset {
            get { return _inset; }
            set {
                if (_inset == value) return;
                _inset = value;
                queue_allocate();
            }
        }

        public double reveal {
            get { return _reveal; }
            set {
                if (_reveal == value) return;
                _reveal = value;
                _child.can_target = value > 0;
                queue_draw();
            }
        }

        public HubReveal(Widget child) {
            _child = child;
            _child.can_target = false;
            _child.set_parent(this);
            overflow = Overflow.HIDDEN;
            hexpand = true;
            vexpand = true;
        }

        public override void dispose() {
            if (_child != null) _child.unparent();
            base.dispose();
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.CONSTANT_SIZE;
        }

        public override void measure(Orientation orientation, int for_size, out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            _child.measure(orientation, for_size, out minimum, out natural, null, null);
            minimum_baseline = -1;
            natural_baseline = -1;
        }

        public override void size_allocate(int width, int height, int baseline) {
            _child.allocate(int.max(0, width - _inset), height, baseline, null);
        }

        public override bool contains(double x, double y) {
            return x >= 0 && x < double.min(_reveal, get_width() - _inset) && y >= 0 && y < get_height();
        }

        public override void snapshot(Snapshot snapshot) {
            if (_reveal <= 0) return;
            var clip = Graphene.Rect();
            clip.init(0, 0, (float) double.min(_reveal + _inset, get_width()), get_height());
            snapshot.push_clip(clip);
            snapshot_child(_child, snapshot);
            snapshot.pop();
        }
    }
}
