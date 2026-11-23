namespace Singularity {

    public class HomeCover : Object {
        private static HomeCover? instance = null;
        private Gee.HashSet<Gdk.Monitor> _covered = new Gee.HashSet<Gdk.Monitor>();

        private Gee.HashMap<Gdk.Monitor, double?> _amount = new Gee.HashMap<Gdk.Monitor, double?>();
        private Gee.HashMap<Gdk.Monitor, double?> _shift = new Gee.HashMap<Gdk.Monitor, double?>();

        public signal void changed(Gdk.Monitor monitor);
        public signal void amount_changed(Gdk.Monitor monitor, double amount);
        public signal void shift_changed(Gdk.Monitor monitor, double shift);

        public static HomeCover get_default() {
            if (instance == null) instance = new HomeCover();
            return instance;
        }

        public bool covered(Gdk.Monitor? monitor) {
            return monitor != null && _covered.contains(monitor);
        }

        public double amount(Gdk.Monitor? monitor) {
            if (monitor == null || !_amount.has_key(monitor)) return 0.0;
            return _amount[monitor];
        }

        public double shift(Gdk.Monitor? monitor) {
            if (monitor == null || !_shift.has_key(monitor)) return 0.0;
            return _shift[monitor];
        }

        public void set_shift(Gdk.Monitor monitor, double shift) {
            if (_shift.has_key(monitor) && _shift[monitor] == shift) return;
            _shift[monitor] = shift;
            shift_changed(monitor, shift);
        }

        public void set_amount(Gdk.Monitor monitor, double amount) {
            double v = amount.clamp(0.0, 1.0);
            if (_amount.has_key(monitor) && _amount[monitor] == v) return;
            _amount[monitor] = v;
            amount_changed(monitor, v);
            set_covered(monitor, v >= 1.0);
        }

        public void set_covered(Gdk.Monitor monitor, bool covered) {
            if (covered == _covered.contains(monitor)) return;
            if (covered) _covered.add(monitor);
            else _covered.remove(monitor);
            changed(monitor);
        }
    }
}
