namespace Singularity {

    public class HomeCover : Object {
        private static HomeCover? instance = null;
        private Gee.HashSet<Gdk.Monitor> _covered = new Gee.HashSet<Gdk.Monitor>();

        public signal void changed(Gdk.Monitor monitor);

        public static HomeCover get_default() {
            if (instance == null) instance = new HomeCover();
            return instance;
        }

        public bool covered(Gdk.Monitor? monitor) {
            return monitor != null && _covered.contains(monitor);
        }

        public void set_covered(Gdk.Monitor monitor, bool covered) {
            if (covered == _covered.contains(monitor)) return;
            if (covered) _covered.add(monitor);
            else _covered.remove(monitor);
            changed(monitor);
        }
    }
}
