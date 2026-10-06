using Gtk;
using Gee;

namespace Singularity {

    /**
     * `dev.sinty.Dock` service: lets external apps inject widgets in the
     * suffix slot of their own dock item, override its icon, and pin it
     * expanded.
     *
     * The widget specs are restricted to a small vocabulary (circular_progress,
     * bubble, button, label, badge) - no arbitrary GTK trees over DBus. Apps
     * identify themselves with their .desktop id; identity is best-effort
     * (no sandboxing).
     */
    [DBus (name = "dev.sinty.Dock")]
    public class DockDBusService : Object, Singularity.DockItemExtension, Singularity.DockContextMenuProvider {
        public signal void action_invoked(string app_id, string action_id);

        private HashMap<string, Variant> _menus = new HashMap<string, Variant>();
        private DBusConnection? _connection = null;

        private HashMap<string, Variant> _suffix_specs = new HashMap<string, Variant>();
        private HashMap<string, Gdk.Texture> _icon_overrides = new HashMap<string, Gdk.Texture>();
        // Track which DBus peer owns each app_id's state so we can auto-clear
        // when the peer disconnects (process exited / crashed).
        private HashMap<string, string> _owner_of = new HashMap<string, string>();
        private HashMap<string, uint> _watch_ids = new HashMap<string, uint>();
        private uint _own_id = 0;
        private uint _reg_id = 0;

        public DockDBusService() {}

        private void track_owner(string nid, string sender) {
            // Drop any old watcher for this app_id.
            if (_owner_of.has_key(nid)) {
                string prev = _owner_of[nid];
                if (prev != sender && _watch_ids.has_key(prev)) {
                    // Only unwatch the previous owner if no other app_id is
                    // still bound to it.
                    bool still_used = false;
                    foreach (var k in _owner_of.keys) {
                        if (k != nid && _owner_of[k] == prev) {
                            still_used = true; break;
                        }
                    }
                    if (!still_used) {
                        Bus.unwatch_name(_watch_ids[prev]);
                        _watch_ids.unset(prev);
                    }
                }
            }
            _owner_of[nid] = sender;
            if (!_watch_ids.has_key(sender)) {
                uint id = Bus.watch_name(BusType.SESSION, sender,
                    BusNameWatcherFlags.NONE,
                    null,  // appeared - no-op
                    (conn, name) => {
                        // Peer vanished - clear every app_id it owned.
                        on_peer_vanished(name);
                    });
                _watch_ids[sender] = id;
            }
        }

        private void on_peer_vanished(string sender) {
            var to_clear = new ArrayList<string>();
            foreach (var k in _owner_of.keys) {
                if (_owner_of[k] == sender) to_clear.add(k);
            }
            foreach (var nid in to_clear) {
                _suffix_specs.unset(nid);
                _icon_overrides.unset(nid);
                _menus.unset(nid);
                _owner_of.unset(nid);
                this.changed(nid);
            }
            if (_watch_ids.has_key(sender)) {
                Bus.unwatch_name(_watch_ids[sender]);
                _watch_ids.unset(sender);
            }
        }

        public void own_bus() {
            _own_id = Bus.own_name(
                BusType.SESSION,
                "dev.sinty.Dock",
                BusNameOwnerFlags.REPLACE | BusNameOwnerFlags.ALLOW_REPLACEMENT,
                (conn) => {
                    _connection = conn;
                    try {
                        _reg_id = conn.register_object("/dev/sinty/Dock", this);
                    } catch (Error e) {
                        warning("DockDBusService register_object failed: %s", e.message);
                    }
                },
                null,
                () => {
                    warning("DockDBusService: name lost");
                }
            );
        }

        // DockItemExtension
        [DBus (visible = false)]
        public bool matches(string app_id) {
            return _suffix_specs.has_key(normalize_id(app_id)) ||
                   _icon_overrides.has_key(normalize_id(app_id));
        }

        [DBus (visible = false)]
        public Gdk.Paintable? get_icon_override(string app_id) {
            var t = _icon_overrides[normalize_id(app_id)];
            return t;
        }

        [DBus (visible = false)]
        public Gtk.Widget? create_suffix_widget(string app_id) {
            string nid = normalize_id(app_id);
            if (!_suffix_specs.has_key(nid)) return null;
            return build_widget_from_spec(nid, _suffix_specs[nid]);
        }

        // DBus methods

        /**
         * Set the suffix-area contents for `app_id`. `widgets` is an array
         * of (kind:s, props:a{sv}) tuples. Calling SetSuffix replaces any
         * previously-set widgets for the same app.
         */
        public void SetSuffix(string app_id, Variant widgets, GLib.BusName sender)
                throws GLib.DBusError, GLib.IOError {
            string nid = normalize_id(app_id);
            _suffix_specs[nid] = widgets;
            track_owner(nid, sender);
            this.changed(nid);
        }

        /** Update a single child widget identified by its action_id (id). */
        public void UpdateWidget(string app_id, string widget_id, Variant props, GLib.BusName sender)
                throws GLib.DBusError, GLib.IOError {
            string nid = normalize_id(app_id);
            if (!_suffix_specs.has_key(nid)) return;
            track_owner(nid, sender);
            // Easiest: walk array, rebuild a new array with the matching widget's props merged.
            var iter = _suffix_specs[nid].iterator();
            var builder = new VariantBuilder(new VariantType("a(sa{sv})"));
            Variant? entry = null;
            while ((entry = iter.next_value()) != null) {
                string kind = entry.get_child_value(0).get_string();
                Variant p = entry.get_child_value(1);
                string? id = lookup_string(p, "id");
                if (id == widget_id) {
                    // Merge: copy old keys, override with new
                    var merged = new VariantBuilder(VariantType.VARDICT);
                    var pi = p.iterator();
                    Variant? kv = null;
                    while ((kv = pi.next_value()) != null) {
                        string k = kv.get_child_value(0).get_string();
                        Variant v = kv.get_child_value(1).get_variant();
                        if (props.lookup_value(k, null) == null) {
                            merged.add("{sv}", k, v);
                        }
                    }
                    var npi = props.iterator();
                    Variant? nkv = null;
                    while ((nkv = npi.next_value()) != null) {
                        string k = nkv.get_child_value(0).get_string();
                        Variant v = nkv.get_child_value(1).get_variant();
                        merged.add("{sv}", k, v);
                    }
                    builder.add("(sa{sv})", kind, merged.end());
                } else {
                    builder.add_value(entry);
                }
            }
            _suffix_specs[nid] = builder.end();
            this.changed(nid);
        }

        public void ClearSuffix(string app_id) throws GLib.DBusError, GLib.IOError {
            string nid = normalize_id(app_id);
            _suffix_specs.unset(nid);
            _owner_of.unset(nid);
            this.changed(nid);
        }

        /**
         * Set an icon override. `icon_data` should be a Variant of type
         * (path:s) (file:// or absolute path) - kept simple on purpose.
         */
        public void SetIcon(string app_id, string path, GLib.BusName sender)
                throws GLib.DBusError, GLib.IOError {
            string nid = normalize_id(app_id);
            track_owner(nid, sender);
            try {
                string p = path.has_prefix("file://") ? GLib.Uri.unescape_string(path.substring(7)) : path;
                if (!GLib.FileUtils.test(p, GLib.FileTest.EXISTS)) {
                    _icon_overrides.unset(nid);
                } else {
                    var pixbuf = new Gdk.Pixbuf.from_file_at_scale(p, 256, 256, true);
                    _icon_overrides[nid] = Gdk.Texture.for_pixbuf(pixbuf);
                }
            } catch (Error e) {
                _icon_overrides.unset(nid);
            }
            this.changed(nid);
        }

        public void ClearIcon(string app_id) throws GLib.DBusError, GLib.IOError {
            string nid = normalize_id(app_id);
            _icon_overrides.unset(nid);
            // Only clear owner tracking if no suffix is still registered.
            if (!_suffix_specs.has_key(nid)) _owner_of.unset(nid);
            this.changed(nid);
        }

        /**
         * Sets the dynamic entries of the dock menu of `app_id`. Each entry
         * is an a{sv} with `id` and `label` strings, an optional `icon`
         * string and `enabled` boolean, or `separator` set to true. Picking
         * an entry emits MenuItemActivated to the caller only; an entry with
         * a `reply` object path is answered by calling
         * dev.sinty.DockMenu1.ActivateItem there instead, and its copy reply
         * is executed by the shell. The entries are dropped when the caller
         * leaves the bus.
         */
        public void SetMenu(string app_id, HashTable<string, Variant>[] items, GLib.BusName sender)
                throws GLib.DBusError, GLib.IOError {
            var builder = new VariantBuilder(new VariantType("aa{sv}"));
            foreach (var item in items) {
                var dict = new VariantDict();
                item.foreach((key, value) => dict.insert_value(key, value));
                builder.add_value(dict.end());
            }
            string nid = normalize_id(app_id);
            _menus[nid] = builder.end();
            track_owner(nid, sender);
        }

        /** Removes the dynamic dock menu entries of `app_id`. */
        public void ClearMenu(string app_id) throws GLib.DBusError, GLib.IOError {
            string nid = normalize_id(app_id);
            _menus.unset(nid);
            if (!_suffix_specs.has_key(nid) && !_icon_overrides.has_key(nid)) _owner_of.unset(nid);
        }

        [DBus (visible = false)]
        public bool populate_context_menu(Singularity.Widgets.ContextMenu menu,
                                          Singularity.DockContextMenuRequest request) {
            string nid = normalize_id(request.app_id);
            if (!_menus.has_key(nid)) return false;
            bool added = false;
            var iter = _menus[nid].iterator();
            Variant? entry = null;
            while ((entry = iter.next_value()) != null) {
                var dict = new VariantDict(entry);
                bool separator = false;
                if (dict.lookup("separator", "b", out separator) && separator) {
                    if (added) menu.add_separator();
                    continue;
                }
                string? item_id = null;
                string? label = null;
                if (!dict.lookup("id", "s", out item_id) || !dict.lookup("label", "s", out label)) continue;
                string? icon = null;
                dict.lookup("icon", "s", out icon);
                bool enabled;
                if (!dict.lookup("enabled", "b", out enabled)) enabled = true;
                string? reply_path = null;
                dict.lookup("reply", "o", out reply_path);
                if (enabled) {
                    string captured_app = nid;
                    string captured_item = item_id;
                    if (reply_path != null) {
                        string captured_path = reply_path;
                        menu.add_item(label, icon, () => request_reply.begin(captured_app, captured_path, captured_item));
                    } else {
                        menu.add_item(label, icon, () => emit_menu_item_activated(captured_app, captured_item));
                    }
                } else {
                    var row = new Singularity.Widgets.MenuRow(label, icon);
                    row.halign = Align.FILL;
                    row.sensitive = false;
                    menu.add_widget(row);
                }
                added = true;
            }
            return added;
        }

        private async void request_reply(string nid, string path, string item_id) {
            if (_connection == null || !_owner_of.has_key(nid)) return;
            yield call_reply(_connection, _owner_of[nid], path, item_id, false);
        }

        [DBus (visible = false)]
        public static async bool call_reply(DBusConnection connection, string bus_name, string path,
                                            string item_id, bool auto_start) {
            try {
                var reply = yield connection.call(bus_name, path, "dev.sinty.DockMenu1", "ActivateItem",
                    new Variant("(s)", item_id), new VariantType("(a{sv})"),
                    auto_start ? DBusCallFlags.NONE : DBusCallFlags.NO_AUTO_START, 5000, null);
                var dict = new VariantDict(reply.get_child_value(0));
                string? text = null;
                if (!dict.lookup("copy-text", "s", out text)) return true;
                bool sensitive;
                if (!dict.lookup("copy-sensitive", "b", out sensitive)) sensitive = false;
                uint32 clear_after;
                if (!dict.lookup("copy-clear-after", "u", out clear_after)) clear_after = 0;
                SearchClipboard.copy(text, sensitive, clear_after);
                return true;
            } catch (Error e) {
                warning("DockDBusService: ActivateItem on %s failed: %s", bus_name, e.message);
                return false;
            }
        }

        private void emit_menu_item_activated(string nid, string item_id) {
            if (_connection == null || !_owner_of.has_key(nid)) return;
            try {
                _connection.emit_signal(_owner_of[nid], "/dev/sinty/Dock", "dev.sinty.Dock",
                    "MenuItemActivated", new Variant("(ss)", nid, item_id));
            } catch (Error e) {
                warning("DockDBusService: MenuItemActivated failed: %s", e.message);
            }
        }

        // Spec -> widget

        private static string? lookup_string(Variant dict, string key) {
            var v = dict.lookup_value(key, null);
            if (v == null) return null;
            if (v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (v.is_of_type(VariantType.STRING)) return v.get_string();
            return null;
        }

        private static double lookup_double(Variant dict, string key, double dflt) {
            var v = dict.lookup_value(key, null);
            if (v == null) return dflt;
            if (v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (v.is_of_type(VariantType.DOUBLE)) return v.get_double();
            if (v.is_of_type(VariantType.INT32)) return (double)v.get_int32();
            if (v.is_of_type(VariantType.UINT32)) return (double)v.get_uint32();
            return dflt;
        }

        private Gtk.Widget build_widget_from_spec(string app_id, Variant spec) {
            var box = new Gtk.Box(Orientation.HORIZONTAL, 4);
            box.valign = Align.CENTER;
            if (!spec.get_type().equal(new VariantType("a(sa{sv})"))) {
                // Malformed spec; ignore.
                return box;
            }
            var iter = spec.iterator();
            Variant? entry = null;
            while ((entry = iter.next_value()) != null) {
                string kind = entry.get_child_value(0).get_string();
                Variant props = entry.get_child_value(1);
                Gtk.Widget? w = build_one(app_id, kind, props);
                if (w != null) box.append(w);
            }
            return box;
        }

        private Gtk.Widget? build_one(string app_id, string kind, Variant props) {
            string? id = lookup_string(props, "id");
            string? tooltip = lookup_string(props, "tooltip");
            switch (kind) {
            case "circular_progress":
                int diameter = (int)lookup_double(props, "diameter", 30);
                var cp = new Singularity.Widgets.CircularProgress(diameter);
                cp.fraction = lookup_double(props, "fraction", 0);
                cp.label = lookup_string(props, "label") ?? "";
                cp.color = lookup_string(props, "color");
                if (tooltip != null) cp.tooltip_text = tooltip;
                return cp;
            case "label":
                var l = new Gtk.Label(lookup_string(props, "label") ?? "");
                l.add_css_class("dock-suffix-label");
                if (tooltip != null) l.tooltip_text = tooltip;
                return l;
            case "badge":
                var b = new Gtk.Label(lookup_string(props, "label") ?? "");
                b.add_css_class("dock-suffix-badge");
                if (tooltip != null) b.tooltip_text = tooltip;
                return b;
            case "bubble":
                var bb = new Gtk.Button();
                bb.add_css_class("dock-suffix-bubble");
                bb.has_frame = false;
                var inner = new Gtk.Box(Orientation.HORIZONTAL, 4);
                inner.valign = Align.CENTER;
                string? icon_path = lookup_string(props, "icon");
                if (icon_path != null && icon_path.length > 0) {
                    var img = new Gtk.Image();
                    img.pixel_size = 22;
                    if (icon_path.has_prefix("/") || icon_path.has_prefix("file://")) {
                        try {
                            string p = icon_path.has_prefix("file://") ? GLib.Uri.unescape_string(icon_path.substring(7)) : icon_path;
                            var pb = new Gdk.Pixbuf.from_file_at_scale(p, 22, 22, true);
                            img.paintable = Gdk.Texture.for_pixbuf(pb);
                        } catch {}
                    } else {
                        img.icon_name = icon_path;
                    }
                    inner.append(img);
                }
                string? text = lookup_string(props, "label");
                if (text != null && text.length > 0) {
                    var l = new Gtk.Label(text);
                    inner.append(l);
                }
                bb.set_child(inner);
                if (tooltip != null) bb.tooltip_text = tooltip;
                if (id != null) {
                    string captured = id.dup();
                    string captured_app = app_id.dup();
                    bb.clicked.connect(() => action_invoked(captured_app, captured));
                }
                return bb;
            case "button":
                var btn = new Gtk.Button();
                btn.has_frame = false;
                btn.add_css_class("dock-suffix-button");
                string? bi = lookup_string(props, "icon");
                if (bi != null && bi.length > 0) {
                    btn.icon_name = bi;
                }
                string? bl = lookup_string(props, "label");
                if (bl != null && bl.length > 0 && bi == null) {
                    btn.label = bl;
                }
                if (tooltip != null) btn.tooltip_text = tooltip;
                if (id != null) {
                    string captured = id.dup();
                    string captured_app = app_id.dup();
                    btn.clicked.connect(() => action_invoked(captured_app, captured));
                }
                return btn;
            case "vstack":
                return build_vstack(app_id, props);
            case "progress_row":
                return build_progress_row(app_id, props, id, tooltip);
            default:
                return null;
            }
        }

        /**
         * Container that stacks child widgets vertically. `children` is a
         * Variant of type a(sa{sv}) - the same shape as the SetSuffix arg -
         * built recursively. Use to lay out multi-row content (e.g. a list of
         * active downloads in the browser) without the dock's pill growing
         * horizontally per row.
         */
        private Gtk.Widget? build_vstack(string app_id, Variant props) {
            var children_var = props.lookup_value("children", null);
            if (children_var == null) return null;
            // Allow either a{sv}-boxed variant or raw array.
            if (children_var.is_of_type(VariantType.VARIANT))
                children_var = children_var.get_variant();
            if (!children_var.is_of_type(new VariantType("a(sa{sv})"))) return null;

            var box = new Gtk.Box(Orientation.VERTICAL, 4);
            box.add_css_class("dock-suffix-vstack");
            int max_rows = (int)lookup_double(props, "max_rows", 4);
            int rendered = 0;
            int total = (int)children_var.n_children();
            var iter = children_var.iterator();
            Variant? entry = null;
            while ((entry = iter.next_value()) != null) {
                if (rendered >= max_rows) break;
                string c_kind = entry.get_child_value(0).get_string();
                Variant c_props = entry.get_child_value(1);
                var w = build_one(app_id, c_kind, c_props);
                if (w != null) { box.append(w); rendered++; }
            }
            if (total > rendered) {
                var more = new Gtk.Label("+%d".printf(total - rendered));
                more.add_css_class("dock-suffix-badge");
                more.halign = Align.CENTER;
                box.append(more);
            }
            return box;
        }

        /**
         * Compact horizontal row: [icon] [label, ellipsized] [circular_progress].
         * Designed for download lists and similar "N things in progress"
         * scenarios where each row needs both a name and a progress indicator.
         */
        private Gtk.Widget? build_progress_row(string app_id, Variant props,
                                                string? id, string? tooltip) {
            var row = new Gtk.Box(Orientation.HORIZONTAL, 8);
            row.add_css_class("dock-suffix-progress-row");
            row.valign = Align.CENTER;

            string? icon_path = lookup_string(props, "icon");
            if (icon_path != null && icon_path.length > 0) {
                var img = new Gtk.Image();
                img.pixel_size = 18;
                if (icon_path.has_prefix("/") || icon_path.has_prefix("file://")) {
                    try {
                        string p = icon_path.has_prefix("file://")
                            ? GLib.Uri.unescape_string(icon_path.substring(7))
                            : icon_path;
                        var pb = new Gdk.Pixbuf.from_file_at_scale(p, 18, 18, true);
                        img.paintable = Gdk.Texture.for_pixbuf(pb);
                    } catch {}
                } else {
                    img.icon_name = icon_path;
                }
                row.append(img);
            }

            string label_text = lookup_string(props, "label") ?? "";
            var lbl = new Gtk.Label(label_text);
            lbl.ellipsize = Pango.EllipsizeMode.MIDDLE;
            lbl.max_width_chars = 22;
            lbl.halign = Align.START;
            lbl.hexpand = true;
            lbl.add_css_class("dock-suffix-progress-row-label");
            row.append(lbl);

            int diameter = (int)lookup_double(props, "diameter", 22);
            var cp = new Singularity.Widgets.CircularProgress(diameter);
            cp.fraction = lookup_double(props, "fraction", 0);
            cp.label = lookup_string(props, "progress_label") ?? "";
            cp.color = lookup_string(props, "color");
            row.append(cp);

            if (tooltip != null) row.tooltip_text = tooltip;
            else if (label_text.length > 0) row.tooltip_text = label_text;

            if (id != null) {
                var click = new Gtk.GestureClick();
                string captured = id.dup();
                string captured_app = app_id.dup();
                click.released.connect(() => action_invoked(captured_app, captured));
                row.add_controller(click);
                row.add_css_class("clickable");
            }
            return row;
        }

        private static string normalize_id(string id) {
            string s = id.down();
            if (s.has_suffix(".desktop")) return s[0:s.length - 8];
            return s;
        }
    }
}
