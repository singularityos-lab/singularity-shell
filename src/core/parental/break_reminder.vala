namespace Singularity {

    public class BreakReminder : Object {
        private int64 last_tick = -1;
        private int64 continuous = 0;
        private bool was_active = false;

        public void reset() {
            last_tick = -1;
            continuous = 0;
            was_active = false;
        }

        public bool advance(int64 now, bool active, int interval_seconds) {
            int64 elapsed = last_tick < 0 ? 0 : (now - last_tick) / 1000000;
            last_tick = now;
            if (!active || !was_active || elapsed < 0 || elapsed > 60) continuous = 0;
            else continuous += elapsed;
            was_active = active;
            if (!active || interval_seconds <= 0 || continuous < interval_seconds) return false;
            continuous = 0;
            return true;
        }
    }
}
