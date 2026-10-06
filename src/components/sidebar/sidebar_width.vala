using Gtk;

namespace Singularity {

    public class SidebarWidth : Widget {
        public const int CARD = 416;
        public const int CONTENT = 390;

        private Widget? _child = null;
        private Gee.HashSet<string> _reported = new Gee.HashSet<string>();

        public Widget? child {
            get { return _child; }
            set {
                if (_child == value) return;
                if (_child != null) _child.unparent();
                _child = value;
                if (_child != null) _child.set_parent(this);
                queue_resize();
            }
        }

        public SidebarWidth(Widget child) {
            overflow = Overflow.HIDDEN;
            this.child = child;
        }

        protected override void dispose() {
            child = null;
            base.dispose();
        }

        public override SizeRequestMode get_request_mode() {
            return SizeRequestMode.HEIGHT_FOR_WIDTH;
        }

        public override void measure(Orientation orientation, int for_size,
                                     out int minimum, out int natural,
                                     out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = -1;
            natural_baseline = -1;
            if (orientation == Orientation.HORIZONTAL) {
                minimum = CONTENT;
                natural = CONTENT;
                return;
            }
            minimum = 0;
            natural = 0;
            if (_child == null || !_child.visible) return;
            int child_min_w, child_nat_w;
            _child.measure(Orientation.HORIZONTAL, -1, out child_min_w, out child_nat_w, null, null);
            int width = int.max(for_size >= 0 ? for_size : CONTENT, child_min_w);
            _child.measure(Orientation.VERTICAL, width, out minimum, out natural, null, null);
        }

        public override void size_allocate(int width, int height, int baseline) {
            if (_child == null || !_child.visible) return;
            int child_min_w, child_nat_w;
            _child.measure(Orientation.HORIZONTAL, -1, out child_min_w, out child_nat_w, null, null);
            if (child_min_w > width) report_overflow(child_min_w, width);
            int child_width = int.max(width, child_min_w);
            int child_min_h, child_nat_h;
            _child.measure(Orientation.VERTICAL, child_width, out child_min_h, out child_nat_h, null, null);
            _child.allocate(child_width, int.max(height, child_min_h), -1, null);
        }

        private void report_overflow(int needed, int width) {
            var path = new StringBuilder();
            Widget? node = _child;
            int limit = width;
            while (node != null) {
                Widget? widest = null;
                int widest_min = 0;
                for (Widget? c = node.get_first_child(); c != null; c = c.get_next_sibling()) {
                    if (!c.should_layout()) continue;
                    int min_w, nat_w;
                    c.measure(Orientation.HORIZONTAL, -1, out min_w, out nat_w, null, null);
                    if (min_w > widest_min) {
                        widest_min = min_w;
                        widest = c;
                    }
                }
                if (widest == null || widest_min < limit - 64) break;
                node = widest;
                if (path.len > 0) path.append(" > ");
                path.append(node.get_type().name());
                var label = node as Label;
                if (label != null) path.append_printf(" \"%s\"", label.label);
            }
            string key = path.str;
            if (_reported.contains(key)) return;
            _reported.add(key);
            warning("Sidebar content needs %d px but the sidebar is %d px wide: %s", needed, width, key);
        }
    }
}
