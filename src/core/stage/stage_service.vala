namespace Singularity {

    [DBus (name = "dev.sinty.Shell.Stage")]
    public class StageService : Object {
        public bool enabled {
            get { return StageManager.get_default().enabled; }
        }

        public double last_switch_ms {
            get { return StageManager.get_default().last_switch_us / 1000.0; }
        }

        public void set_enabled(bool on) throws DBusError, IOError {
            StageManager.get_default().request_enabled(on);
        }

        public string list_sets() throws DBusError, IOError {
            var manager = StageManager.get_default();
            var builder = new Json.Builder();
            builder.begin_array();
            foreach (var connector in manager.monitors()) {
                var model = manager.model_for(connector);
                if (model == null) continue;
                if (model.active != null) add_set(builder, manager, connector, model.active, true);
                foreach (var s in model.inactive_sets()) add_set(builder, manager, connector, s, false);
            }
            builder.end_array();
            var gen = new Json.Generator();
            gen.set_root(builder.get_root());
            return gen.to_data(null);
        }

        private void add_set(Json.Builder builder, StageManager manager, string connector, StageSet s, bool active) {
            builder.begin_object();
            builder.set_member_name("monitor");
            builder.add_string_value(connector);
            builder.set_member_name("id");
            builder.add_int_value(s.id);
            builder.set_member_name("active");
            builder.add_boolean_value(active);
            builder.set_member_name("windows");
            builder.begin_array();
            foreach (var key in s.windows) {
                var win = manager.window_for(key);
                builder.begin_object();
                builder.set_member_name("key");
                builder.add_string_value(key);
                builder.set_member_name("app_id");
                builder.add_string_value(win != null ? win.app_id : "");
                builder.set_member_name("title");
                builder.add_string_value(win != null ? win.title : "");
                builder.set_member_name("minimized");
                builder.add_boolean_value(win != null && win.is_minimized);
                builder.end_object();
            }
            builder.end_array();
            builder.end_object();
        }

        public void activate(uint id) throws DBusError, IOError {
            StageManager.get_default().activate(id);
        }

        public void move_window(string key, uint target_set) throws DBusError, IOError {
            StageManager.get_default().move_window(key, target_set);
        }
    }
}
