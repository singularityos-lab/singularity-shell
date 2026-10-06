namespace Singularity {

    public class StageManager : Object {
        public const string SETTINGS_KEY = "stage-manager";
        private const uint REFRESH_SECONDS = 5;
        private const int THUMB_MAX_W = 240;
        private const int THUMB_MAX_H = 160;

        private static StageManager? _instance = null;

        public bool enabled { get; private set; default = false; }
        public int64 last_switch_us { get; private set; default = 0; }

        private GLib.Settings _settings;
        private Gtk.Application? _app = null;
        private Gee.HashMap<string, StageModel> _models = new Gee.HashMap<string, StageModel>();
        private Gee.HashMap<string, StageStrip> _strips = new Gee.HashMap<string, StageStrip>();
        private Gee.ArrayList<string> _monitor_order = new Gee.ArrayList<string>();
        private Gee.HashMap<string, string> _monitor_of = new Gee.HashMap<string, string>();
        private Gee.HashMap<string, AppSystem.Window> _windows = new Gee.HashMap<string, AppSystem.Window>();
        private Gee.HashMap<string, bool> _expected = new Gee.HashMap<string, bool>();
        private Gee.HashMap<string, Gdk.Texture> _thumbs = new Gee.HashMap<string, Gdk.Texture>();
        private Gee.HashMap<string, uint> _tags = new Gee.HashMap<string, uint>();
        private Gee.HashMap<string, uint> _saved_active = new Gee.HashMap<string, uint>();
        private Gee.HashMap<string, Gee.ArrayList<uint>> _saved_order = new Gee.HashMap<string, Gee.ArrayList<uint>>();
        private uint _refresh_id = 0;
        private uint _save_id = 0;
        private uint _monitors_id = 0;
        private bool _switching = false;
        private bool _release_leftovers = false;
        private uint _pending_activate = 0;

        public signal void thumbnail_changed(string key);
        public signal void sets_changed(string connector);

        public static StageManager get_default() {
            if (_instance == null) _instance = new StageManager();
            return _instance;
        }

        private StageManager() {
            _settings = new GLib.Settings("dev.sinty.desktop");
        }

        public static string key_for(void* handle) {
            return "%lx".printf((ulong) handle);
        }

        public void start(Gtk.Application app) {
            _app = app;
            var apps = AppSystem.get_default();
            apps.app_opened.connect(on_window_opened);
            apps.app_closed.connect(on_window_closed);
            apps.window_state_changed.connect(on_window_state_changed);
            apps.window_focused.connect(on_window_focused);
            apps.window_output_changed.connect(on_window_output_changed);
            apps.app_title_changed.connect((win) => {
                string key = key_for(win.handle);
                if (enabled && _monitor_of.has_key(key)) rebuild_strip(_monitor_of[key], false);
            });
            apps.apps_changed.connect(() => {
                if (!enabled) return;
                foreach (var connector in _strips.keys) rebuild_strip(connector, false);
            });
            var display = Gdk.Display.get_default();
            if (display != null) {
                display.get_monitors().items_changed.connect(() => {
                    if (!enabled || _monitors_id != 0) return;
                    _monitors_id = Idle.add(() => {
                        _monitors_id = 0;
                        sync_monitors();
                        return Source.REMOVE;
                    });
                });
            }
            _settings.changed[SETTINGS_KEY].connect(() => apply_setting());
            apply_setting();
            if (!enabled && StageBridge.groups_supported()) {
                _release_leftovers = true;
                foreach (var win in apps.get_mru_windows()) release_leftover(win.handle);
                Timeout.add_seconds(10, () => {
                    _release_leftovers = false;
                    return Source.REMOVE;
                });
            }
        }

        private void release_leftover(void* handle) {
            uint group = 0;
            bool hidden = false;
            if (!StageBridge.get_group(handle, out group, out hidden) || group == 0) return;
            StageBridge.set_group(handle, 0);
            if (hidden) StageBridge.set_hidden(handle, false, 0, 0, 0, 0);
            message("[Stage] released window %s left from a previous session", key_for(handle));
        }

        public void request_enabled(bool on) {
            if (_settings.get_boolean(SETTINGS_KEY) != on) _settings.set_boolean(SETTINGS_KEY, on);
        }

        public Gee.List<string> monitors() {
            return _monitor_order.read_only_view;
        }

        public StageModel? model_for(string connector) {
            return _models.has_key(connector) ? _models[connector] : null;
        }

        public string? monitor_of_window(string key) {
            return _monitor_of.has_key(key) ? _monitor_of[key] : null;
        }

        public string? monitor_of_set(uint id) {
            foreach (var entry in _models.entries) {
                if (entry.value.find_set(id) != null) return entry.key;
            }
            return null;
        }

        private void apply_setting() {
            bool want = _settings.get_boolean(SETTINGS_KEY);
            if (want == enabled) return;
            if (want) enable();
            else disable();
        }

        private static string monitor_connector(Gdk.Monitor monitor, uint index) {
            string? connector = monitor.get_connector();
            return connector != null && connector != "" ? connector : "monitor-%u".printf(index);
        }

        private Gee.List<string> current_connectors() {
            var list = new Gee.ArrayList<string>();
            var display = Gdk.Display.get_default();
            if (display == null) return list;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                list.add(monitor_connector((Gdk.Monitor) monitors.get_item(i), i));
            }
            return list;
        }

        public Gdk.Monitor? monitor_for_connector(string connector) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = (Gdk.Monitor) monitors.get_item(i);
                if (monitor_connector(monitor, i) == connector) return monitor;
            }
            return null;
        }

        private string primary_connector() {
            if (_monitor_order.size > 0) return _monitor_order[0];
            var list = current_connectors();
            return list.size > 0 ? list[0] : "";
        }

        private string connector_for(AppSystem.Window win) {
            var monitor = Singularity.wayland_get_window_monitor(win.handle);
            if (monitor != null) {
                var display = Gdk.Display.get_default();
                if (display != null) {
                    var monitors = display.get_monitors();
                    for (uint i = 0; i < monitors.get_n_items(); i++) {
                        var m = (Gdk.Monitor) monitors.get_item(i);
                        if (m == monitor || (m.get_connector() != null && m.get_connector() == monitor.get_connector())) {
                            string c = monitor_connector(m, i);
                            if (_models.has_key(c)) return c;
                        }
                    }
                }
            }
            return primary_connector();
        }

        private StageModel ensure_model(string connector) {
            if (!_models.has_key(connector)) {
                _models[connector] = new StageModel();
                if (!_monitor_order.contains(connector)) _monitor_order.add(connector);
            }
            return _models[connector];
        }

        private void ensure_strip(string connector) {
            if (_app == null || _strips.has_key(connector)) return;
            var strip = new StageStrip(_app, this, connector);
            _strips[connector] = strip;
            strip.present();
        }

        private void rebuild_strip(string connector, bool cascade, bool arrive = false) {
            if (_strips.has_key(connector)) _strips[connector].rebuild(cascade, arrive);
            sets_changed(connector);
        }

        private Gdk.Rectangle? slot_rect(string connector, int slot) {
            if (slot < 0 || !_strips.has_key(connector)) return null;
            return _strips[connector].slot_rect(slot);
        }

        private void enable() {
            _release_leftovers = false;
            enabled = true;
            reset_state();
            load_state();
            foreach (var c in current_connectors()) ensure_model(c);
            if (_models.size == 0) ensure_model("");
            bool groups = StageBridge.groups_supported();
            bool restored = false;
            var apps = AppSystem.get_default();
            foreach (var win in apps.get_mru_windows()) {
                if (!is_stage_window(win)) continue;
                string key = key_for(win.handle);
                uint group = 0;
                bool hidden = false;
                if (groups) StageBridge.get_group(win.handle, out group, out hidden);
                if (group != 0) restored = true;
                string connector = connector_for(win);
                _windows[key] = win;
                _monitor_of[key] = connector;
                _models[connector].restore_window(key, group, win.is_minimized, hidden);
            }
            var hide = new Gee.ArrayList<string>();
            var show = new Gee.ArrayList<string>();
            foreach (var connector in _monitor_order) {
                var model = _models[connector];
                if (restored) {
                    var plan = model.restore_finish(saved_active(connector), saved_order(connector));
                    hide.add_all(plan.hide);
                    show.add_all(plan.show);
                } else {
                    hide.add_all(split_by_app(model));
                }
            }
            foreach (var connector in _monitor_order) {
                ensure_strip(connector);
                rebuild_strip(connector, true);
            }
            foreach (var key in hide) {
                string connector = _monitor_of[key];
                var owner = _models[connector].set_for(key);
                int slot = owner != null ? _models[connector].inactive_index(owner.id) : -1;
                set_hidden(key, true, slot_rect(connector, slot));
            }
            foreach (var key in show) set_hidden(key, false, null);
            sync_tags();
            schedule_save();
            refresh_thumbnails();
            _refresh_id = Timeout.add_seconds(REFRESH_SECONDS, () => {
                refresh_thumbnails();
                return Source.CONTINUE;
            });
            message("[Stage] enabled with %d windows on %d monitors, compositor support %s, groups %s",
                _windows.size, _monitor_order.size, StageBridge.available() ? "yes" : "no",
                restored ? "restored" : (groups ? "new" : "not remembered"));
        }

        private void reset_state() {
            _models.clear();
            _monitor_order.clear();
            _monitor_of.clear();
            _windows.clear();
            _thumbs.clear();
            _tags.clear();
            _expected.clear();
        }

        private void disable() {
            enabled = false;
            if (_refresh_id != 0) {
                Source.remove(_refresh_id);
                _refresh_id = 0;
            }
            foreach (var entry in _models.entries) {
                foreach (var key in entry.value.all_windows()) {
                    var win = window_for(key);
                    if (win != null) StageBridge.set_group(win.handle, 0);
                }
                foreach (var key in entry.value.clear()) set_hidden(key, false, null);
            }
            foreach (var strip in _strips.values) {
                close_layer_window(strip);
                strip.destroy();
            }
            _strips.clear();
            reset_state();
            delete_state();
            message("[Stage] disabled");
        }

        private void sync_monitors() {
            if (!enabled) return;
            var now = current_connectors();
            if (now.size == 0) return;
            foreach (var connector in now) ensure_model(connector);
            var gone = new Gee.ArrayList<string>();
            foreach (var connector in _monitor_order) if (!now.contains(connector)) gone.add(connector);
            _monitor_order.clear();
            _monitor_order.add_all(now);
            string target = _monitor_order[0];
            foreach (var connector in gone) {
                var model = _models[connector];
                foreach (var key in model.all_windows()) _monitor_of[key] = target;
                _models[target].adopt(model);
                _models.unset(connector);
                if (_strips.has_key(connector)) {
                    var strip = _strips[connector];
                    _strips.unset(connector);
                    close_layer_window(strip);
                    strip.destroy();
                }
                message("[Stage] monitor %s removed, groups moved to %s", connector, target);
            }
            foreach (var connector in _monitor_order) {
                ensure_strip(connector);
                _strips[connector].refresh_origin();
                rebuild_strip(connector, false);
            }
            foreach (var key in _windows.keys) on_window_output_changed(_windows[key].handle);
            schedule_save();
        }

        private Gee.List<string> split_by_app(StageModel model) {
            var hide = new Gee.ArrayList<string>();
            var active = model.active;
            if (active == null || active.windows.size < 2) return hide;
            string lead = _windows[active.windows[0]].app_id;
            var sets = new Gee.HashMap<string, uint>();
            var keys = new Gee.ArrayList<string>();
            keys.add_all(active.windows);
            for (int i = keys.size - 1; i >= 0; i--) {
                string key = keys[i];
                string app_id = _windows[key].app_id;
                if (app_id == lead) continue;
                var plan = model.move_window(key, sets.has_key(app_id) ? sets[app_id] : 0);
                if (!sets.has_key(app_id)) sets[app_id] = model.set_for(key).id;
                hide.add_all(plan.hide);
            }
            return hide;
        }

        private bool is_stage_window(AppSystem.Window win) {
            if (win.handle == null) return false;
            return Singularity.wayland_window_is_tileable(win.handle);
        }

        public AppSystem.Window? window_for(string key) {
            return _windows.has_key(key) ? _windows[key] : null;
        }

        public Gdk.Texture? thumbnail_for(string key) {
            return _thumbs.has_key(key) ? _thumbs[key] : null;
        }

        private StageModel? model_of_window(string key) {
            if (!_monitor_of.has_key(key)) return null;
            return model_for(_monitor_of[key]);
        }

        private void on_window_opened(void* handle, string app_id) {
            if (!enabled) {
                if (_release_leftovers) release_leftover(handle);
                return;
            }
            var win = AppSystem.get_default().get_window_by_handle(handle);
            if (win == null || !is_stage_window(win)) return;
            string key = key_for(handle);
            if (_monitor_of.has_key(key)) return;
            string connector = connector_for(win);
            var model = ensure_model(connector);
            _windows[key] = win;
            _monitor_of[key] = connector;
            uint group = 0;
            bool hidden = false;
            if (StageBridge.groups_supported()) StageBridge.get_group(handle, out group, out hidden);
            if (group != 0) {
                model.restore_window(key, group, win.is_minimized, hidden);
                uint keep = model.active != null && model.active.windows.size > 0
                    ? model.active.id : saved_active(connector);
                var plan = model.restore_finish(keep, saved_order(connector));
                foreach (var k in plan.hide) {
                    var owner = model.set_for(k);
                    set_hidden(k, true, slot_rect(connector, owner != null ? model.inactive_index(owner.id) : -1));
                }
                foreach (var k in plan.show) set_hidden(k, false, null);
                message("[Stage] restored window %s into set %u", key, group);
            } else {
                model.add_window(key);
            }
            sync_tags();
            schedule_save();
            rebuild_strip(connector, false);
        }

        private void on_window_closed(void* handle) {
            if (!enabled) return;
            string key = key_for(handle);
            var model = model_of_window(key);
            if (model == null) return;
            string connector = _monitor_of[key];
            model.remove_window(key);
            _windows.unset(key);
            _thumbs.unset(key);
            _expected.unset(key);
            _tags.unset(key);
            _monitor_of.unset(key);
            schedule_save();
            rebuild_strip(connector, false);
        }

        private void on_window_output_changed(void* handle) {
            if (!enabled || _switching) return;
            string key = key_for(handle);
            if (!_monitor_of.has_key(key)) return;
            var win = _windows[key];
            string from = _monitor_of[key];
            string to = connector_for(win);
            if (from == to || !_models.has_key(from)) return;
            var source = _models[from];
            bool was_hidden = source.is_hidden(key);
            source.remove_window(key);
            var dest = ensure_model(to);
            dest.add_window(key);
            if (win.is_minimized && !was_hidden) dest.set_user_minimized(key, true);
            _monitor_of[key] = to;
            if (was_hidden) set_hidden(key, false, null);
            sync_tags();
            schedule_save();
            rebuild_strip(from, false);
            rebuild_strip(to, false);
            message("[Stage] window %s moved from %s to %s", key, from, to);
        }

        private void on_window_state_changed(void* handle) {
            if (!enabled) return;
            string key = key_for(handle);
            var model = model_of_window(key);
            if (model == null) return;
            var win = _windows[key];
            if (_expected.has_key(key)) {
                bool want = _expected[key];
                if (want == win.is_minimized) {
                    _expected.unset(key);
                    return;
                }
            }
            var owner = model.set_for(key);
            if (owner == model.active) {
                model.set_user_minimized(key, win.is_minimized);
                return;
            }
            if (!win.is_minimized) {
                model.mark_shown(key);
                activate_later(owner.id);
            }
        }

        private void on_window_focused(void* handle) {
            if (!enabled || handle == null || _switching) return;
            string key = key_for(handle);
            var model = model_of_window(key);
            if (model == null) return;
            var owner = model.set_for(key);
            if (owner == null || owner == model.active) return;
            var win = window_for(key);
            if (win == null || win.is_minimized) return;
            if (_expected.has_key(key) && _expected[key]) return;
            activate_later(owner.id);
        }

        private void activate_later(uint id) {
            if (_pending_activate != 0) Source.remove(_pending_activate);
            _pending_activate = Idle.add(() => {
                _pending_activate = 0;
                activate(id);
                return Source.REMOVE;
            });
        }

        public void activate(uint id) {
            if (!enabled) return;
            string? connector = monitor_of_set(id);
            if (connector == null) return;
            var model = _models[connector];
            var target = model.find_set(id);
            if (target == null || target == model.active) return;
            int64 t0 = GLib.get_monotonic_time();
            _switching = true;
            int from_slot = model.inactive_index(id);
            Gdk.Rectangle? from_rect = slot_rect(connector, from_slot);
            var previous = model.active;
            if (previous != null) capture_now(previous.windows);
            var plan = model.activate(id);
            Gdk.Rectangle? to_rect = slot_rect(connector, 0);
            foreach (var key in plan.hide) set_hidden(key, true, to_rect);
            foreach (var key in order_for_restore(plan.show)) set_hidden(key, false, from_rect);
            rebuild_strip(connector, false, previous != null && previous.windows.size > 0);
            _switching = false;
            sync_tags();
            schedule_save();
            last_switch_us = GLib.get_monotonic_time() - t0;
            message("[Stage] switched to set %u on %s (%d shown, %d hidden) in %.2f ms",
                id, connector, plan.show.size, plan.hide.size, last_switch_us / 1000.0);
        }

        public void move_window(string key, uint target_id, string? connector = null) {
            if (!enabled || !_monitor_of.has_key(key)) return;
            string home = _monitor_of[key];
            if (connector != null && connector != home) {
                message("[Stage] window %s stays on %s, groups belong to one monitor", key, home);
                return;
            }
            if (target_id != 0 && monitor_of_set(target_id) != home) return;
            var model = _models[home];
            var source = model.set_for(key);
            int from_slot = source != null ? model.inactive_index(source.id) : -1;
            Gdk.Rectangle? from_rect = slot_rect(home, from_slot);
            if (source == model.active) capture_now(single(key));
            var plan = model.move_window(key, target_id);
            var dest = model.set_for(key);
            int to_slot = dest != null ? model.inactive_index(dest.id) : -1;
            Gdk.Rectangle? to_rect = slot_rect(home, to_slot);
            foreach (var k in plan.hide) set_hidden(k, true, to_rect);
            foreach (var k in plan.show) set_hidden(k, false, from_rect);
            rebuild_strip(home, false);
            sync_tags();
            schedule_save();
            message("[Stage] moved window %s to set %u", key, dest != null ? dest.id : 0);
        }

        private Gee.List<string> single(string key) {
            var list = new Gee.ArrayList<string>();
            list.add(key);
            return list;
        }

        private Gee.List<string> order_for_restore(Gee.List<string> keys) {
            var ordered = new Gee.ArrayList<string>();
            var mru = AppSystem.get_default().get_mru_windows();
            mru.reverse();
            foreach (var win in mru) {
                string k = key_for(win.handle);
                if (keys.contains(k)) ordered.add(k);
            }
            foreach (var k in keys) if (!ordered.contains(k)) ordered.add(k);
            return ordered;
        }

        private void set_hidden(string key, bool hidden, Gdk.Rectangle? rect) {
            var win = window_for(key);
            if (win == null) return;
            if (win.is_minimized == hidden) return;
            _expected[key] = hidden;
            if (rect != null) {
                StageBridge.set_hidden(win.handle, hidden, rect.x, rect.y, rect.width, rect.height);
            } else {
                StageBridge.set_hidden(win.handle, hidden, 0, 0, 0, 0);
            }
        }

        private void sync_tags() {
            foreach (var model in _models.values) {
                foreach (var key in model.all_windows()) {
                    var owner = model.set_for(key);
                    uint tag = owner != null ? owner.id : 0;
                    if (_tags.has_key(key) && _tags[key] == tag) continue;
                    var win = window_for(key);
                    if (win == null) continue;
                    StageBridge.set_group(win.handle, tag);
                    _tags[key] = tag;
                }
            }
        }

        private static string state_path() {
            return Path.build_filename(Environment.get_user_state_dir(), "singularity", "stage-groups.json");
        }

        private uint saved_active(string connector) {
            return _saved_active.has_key(connector) ? _saved_active[connector] : 0;
        }

        private Gee.List<uint>? saved_order(string connector) {
            return _saved_order.has_key(connector) ? _saved_order[connector] : null;
        }

        private void load_state() {
            _saved_active.clear();
            _saved_order.clear();
            var parser = new Json.Parser();
            try {
                parser.load_from_file(state_path());
            } catch (Error e) {
                return;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
            var monitors = root.get_object().get_object_member("monitors");
            if (monitors == null) return;
            foreach (var connector in monitors.get_members()) {
                var entry = monitors.get_object_member(connector);
                if (entry == null) continue;
                if (entry.has_member("active")) _saved_active[connector] = (uint) entry.get_int_member("active");
                var order = new Gee.ArrayList<uint>();
                var array = entry.has_member("order") ? entry.get_array_member("order") : null;
                if (array != null) {
                    array.foreach_element((a, i, node) => order.add((uint) node.get_int()));
                }
                _saved_order[connector] = order;
            }
        }

        private void schedule_save() {
            if (_save_id != 0) return;
            _save_id = Timeout.add(300, () => {
                _save_id = 0;
                save_state();
                return Source.REMOVE;
            });
        }

        private void save_state() {
            if (!enabled) return;
            var builder = new Json.Builder();
            builder.begin_object();
            builder.set_member_name("monitors");
            builder.begin_object();
            foreach (var connector in _monitor_order) {
                var model = _models[connector];
                builder.set_member_name(connector);
                builder.begin_object();
                builder.set_member_name("active");
                builder.add_int_value(model.active != null ? model.active.id : 0);
                builder.set_member_name("order");
                builder.begin_array();
                foreach (var id in model.set_order()) builder.add_int_value(id);
                builder.end_array();
                builder.end_object();
                _saved_active[connector] = model.active != null ? model.active.id : 0;
                var order = new Gee.ArrayList<uint>();
                order.add_all(model.set_order());
                _saved_order[connector] = order;
            }
            builder.end_object();
            builder.end_object();
            var gen = new Json.Generator();
            gen.set_root(builder.get_root());
            try {
                string path = state_path();
                DirUtils.create_with_parents(Path.get_dirname(path), 0700);
                FileUtils.set_contents(path, gen.to_data(null));
            } catch (Error e) {
                warning("[Stage] could not save groups: %s", e.message);
            }
        }

        private void delete_state() {
            _saved_active.clear();
            _saved_order.clear();
            FileUtils.remove(state_path());
        }

        private void capture_now(Gee.List<string> keys) {
            foreach (var key in keys) capture(key);
        }

        private void capture(string key) {
            var win = window_for(key);
            if (win == null) return;
            PreviewCache.get_default().request(win.handle, THUMB_MAX_W, THUMB_MAX_H, (texture) => {
                if (texture == null || !enabled || !_windows.has_key(key)) return;
                _thumbs[key] = texture;
                thumbnail_changed(key);
            });
        }

        private void refresh_thumbnails() {
            if (!enabled) return;
            foreach (var entry in _models.entries) {
                if (!_strips.has_key(entry.key) || !_strips[entry.key].get_mapped()) continue;
                foreach (var s in entry.value.inactive_sets()) {
                    foreach (var key in s.windows) capture(key);
                }
            }
        }
    }
}
