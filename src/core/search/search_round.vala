namespace Singularity {

    public class SearchRound : GLib.Object {
        private int pending;
        private bool emitted = false;

        public bool finished {
            get { return pending <= 0; }
        }

        public SearchRound(int providers) {
            pending = providers;
        }

        public bool provider_done(bool has_results) {
            pending--;
            if (has_results) {
                emitted = true;
                return true;
            }
            if (pending <= 0 && !emitted) {
                emitted = true;
                return true;
            }
            return false;
        }
    }
}
