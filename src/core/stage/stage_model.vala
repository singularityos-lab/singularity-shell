namespace Singularity {

    public class StageSet : Object {
        public uint id { get; construct; }
        public Gee.ArrayList<string> windows = new Gee.ArrayList<string>();

        public StageSet(uint id) {
            Object(id: id);
        }
    }

    public class StagePlan : Object {
        public Gee.ArrayList<string> hide = new Gee.ArrayList<string>();
        public Gee.ArrayList<string> show = new Gee.ArrayList<string>();

        public bool is_empty() {
            return hide.size == 0 && show.size == 0;
        }
    }

    public class StageModel : Object {
        private static uint _next_id = 1;
        private Gee.ArrayList<StageSet> _inactive = new Gee.ArrayList<StageSet>();
        private Gee.HashMap<string, StageSet> _owner = new Gee.HashMap<string, StageSet>();
        private Gee.HashSet<string> _hidden = new Gee.HashSet<string>();
        private Gee.HashSet<string> _user_minimized = new Gee.HashSet<string>();

        public StageSet? active { get; private set; default = null; }

        public signal void changed();

        public Gee.List<StageSet> inactive_sets() {
            return _inactive.read_only_view;
        }

        public int set_count() {
            return _inactive.size + (active != null ? 1 : 0);
        }

        public StageSet? find_set(uint id) {
            if (active != null && active.id == id) return active;
            foreach (var s in _inactive) if (s.id == id) return s;
            return null;
        }

        public StageSet? set_for(string key) {
            return _owner.has_key(key) ? _owner[key] : null;
        }

        public bool contains(string key) {
            return _owner.has_key(key);
        }

        public bool is_hidden(string key) {
            return _hidden.contains(key);
        }

        public bool is_user_minimized(string key) {
            return _user_minimized.contains(key);
        }

        public int inactive_index(uint id) {
            for (int i = 0; i < _inactive.size; i++) if (_inactive[i].id == id) return i;
            return -1;
        }

        private StageSet new_set() {
            return new StageSet(_next_id++);
        }

        public static void reserve_id(uint id) {
            if (id >= _next_id) _next_id = id + 1;
        }

        public Gee.List<uint> set_order() {
            var order = new Gee.ArrayList<uint>();
            foreach (var s in _inactive) order.add(s.id);
            return order;
        }

        public Gee.List<string> all_windows() {
            var keys = new Gee.ArrayList<string>();
            if (active != null) keys.add_all(active.windows);
            foreach (var s in _inactive) keys.add_all(s.windows);
            return keys;
        }

        public void restore_window(string key, uint set_id, bool minimized, bool hidden) {
            if (_owner.has_key(key)) return;
            if (set_id == 0) {
                add_window(key);
                if (minimized && hidden) _hidden.add(key);
                else if (minimized) _user_minimized.add(key);
                return;
            }
            reserve_id(set_id);
            var target = find_set(set_id);
            if (target == null) {
                target = new StageSet(set_id);
                _inactive.add(target);
            }
            target.windows.add(key);
            _owner[key] = target;
            if (minimized && hidden) _hidden.add(key);
            else if (minimized) _user_minimized.add(key);
            changed();
        }

        public StagePlan restore_finish(uint active_id, Gee.List<uint>? order) {
            var plan = new StagePlan();
            var wanted = active_id != 0 ? find_set(active_id) : null;
            if (wanted == null && _inactive.size > 0) {
                wanted = first_visible_set() ?? _inactive[0];
            }
            if (wanted != null && wanted != active) {
                _inactive.remove(wanted);
                if (active != null) {
                    foreach (var key in active.windows) {
                        wanted.windows.add(key);
                        _owner[key] = wanted;
                    }
                }
                active = wanted;
            }
            if (active == null) active = new_set();
            if (order != null && order.size > 0) {
                var sorted = new Gee.ArrayList<StageSet>();
                foreach (var id in order) {
                    foreach (var s in _inactive) {
                        if (s.id == id && !sorted.contains(s)) sorted.add(s);
                    }
                }
                foreach (var s in _inactive) if (!sorted.contains(s)) sorted.add(s);
                _inactive.clear();
                _inactive.add_all(sorted);
            }
            foreach (var key in active.windows) {
                if (_hidden.contains(key)) {
                    _hidden.remove(key);
                    plan.show.add(key);
                }
            }
            foreach (var s in _inactive) {
                foreach (var key in s.windows) {
                    if (_hidden.contains(key) || _user_minimized.contains(key)) continue;
                    _hidden.add(key);
                    plan.hide.add(key);
                }
            }
            var empty = new Gee.ArrayList<StageSet>();
            foreach (var s in _inactive) if (s.windows.size == 0) empty.add(s);
            _inactive.remove_all(empty);
            changed();
            return plan;
        }

        private StageSet? first_visible_set() {
            foreach (var s in _inactive) {
                foreach (var key in s.windows) {
                    if (!_hidden.contains(key) && !_user_minimized.contains(key)) return s;
                }
            }
            return null;
        }

        public void adopt(StageModel other) {
            var other_active = other.active;
            if (other_active != null && other_active.windows.size > 0) {
                if (active == null) active = new_set();
                foreach (var key in other_active.windows) {
                    active.windows.add(key);
                    _owner[key] = active;
                    if (other._user_minimized.contains(key)) _user_minimized.add(key);
                }
            }
            foreach (var s in other._inactive) {
                if (s.windows.size == 0) continue;
                _inactive.add(s);
                foreach (var key in s.windows) {
                    _owner[key] = s;
                    if (other._hidden.contains(key)) _hidden.add(key);
                    if (other._user_minimized.contains(key)) _user_minimized.add(key);
                }
            }
            other._owner.clear();
            other._hidden.clear();
            other._user_minimized.clear();
            other._inactive.clear();
            other.active = null;
            changed();
        }

        public StageSet add_window(string key) {
            if (_owner.has_key(key)) return _owner[key];
            if (active == null) active = new_set();
            active.windows.add(key);
            _owner[key] = active;
            changed();
            return active;
        }

        public void remove_window(string key) {
            if (!_owner.has_key(key)) return;
            var s = _owner[key];
            s.windows.remove(key);
            _owner.unset(key);
            _hidden.remove(key);
            _user_minimized.remove(key);
            if (s != active && s.windows.size == 0) _inactive.remove(s);
            changed();
        }

        public void set_user_minimized(string key, bool minimized) {
            if (!_owner.has_key(key)) return;
            if (minimized) _user_minimized.add(key);
            else _user_minimized.remove(key);
        }

        public StagePlan activate(uint id) {
            var plan = new StagePlan();
            var target = find_set(id);
            if (target == null || target == active) return plan;
            _inactive.remove(target);
            var previous = active;
            if (previous != null) {
                foreach (var key in previous.windows) {
                    if (_user_minimized.contains(key) || _hidden.contains(key)) continue;
                    _hidden.add(key);
                    plan.hide.add(key);
                }
                if (previous.windows.size > 0) _inactive.insert(0, previous);
            }
            active = target;
            foreach (var key in target.windows) {
                if (!_hidden.contains(key)) continue;
                _hidden.remove(key);
                plan.show.add(key);
            }
            changed();
            return plan;
        }

        public StagePlan move_window(string key, uint target_id) {
            var plan = new StagePlan();
            if (!_owner.has_key(key)) return plan;
            var source = _owner[key];
            StageSet? target = target_id == 0 ? null : find_set(target_id);
            if (target_id != 0 && target == null) return plan;
            if (target == source) return plan;
            if (target == null) {
                target = new_set();
                _inactive.insert(0, target);
            }
            source.windows.remove(key);
            target.windows.add(key);
            _owner[key] = target;
            if (target == active) {
                if (_hidden.contains(key)) {
                    _hidden.remove(key);
                    plan.show.add(key);
                }
            } else if (source == active) {
                if (!_user_minimized.contains(key) && !_hidden.contains(key)) {
                    _hidden.add(key);
                    plan.hide.add(key);
                }
            }
            if (source != active && source.windows.size == 0) _inactive.remove(source);
            changed();
            return plan;
        }

        public void mark_shown(string key) {
            _hidden.remove(key);
            _user_minimized.remove(key);
        }

        public Gee.List<string> clear() {
            var restore = new Gee.ArrayList<string>();
            foreach (var key in _hidden) restore.add(key);
            _hidden.clear();
            _user_minimized.clear();
            _owner.clear();
            _inactive.clear();
            active = null;
            changed();
            return restore;
        }
    }
}
