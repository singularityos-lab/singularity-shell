using Gtk;
using Singularity;

namespace Singularity {

    public class NotificationCenter : Box {
        private Box list_box;
        private Singularity.Widgets.StatusPage empty_label;
        private Singularity.Animation.ListAnimator animator;
        private Gee.HashMap<string, Widget> _rows = new Gee.HashMap<string, Widget>();
        private Gee.HashMap<string, string> _signatures = new Gee.HashMap<string, string>();
        private Gee.HashSet<string> _expanded = new Gee.HashSet<string>();
        private FocusBanner focus_banner;

        public NotificationCenter() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("notification-center");

            focus_banner = new FocusBanner();
            focus_banner.margin_start = 16;
            focus_banner.margin_end = 16;
            focus_banner.margin_top = 10;
            append(focus_banner);

            list_box = new Box(Orientation.VERTICAL, 10);
            list_box.margin_start = 16;
            list_box.margin_end = 16;
            list_box.margin_bottom = 20;
            list_box.margin_top = 10;
            append(list_box);
            animator = new Singularity.Animation.ListAnimator(list_box);

            empty_label = new Singularity.Widgets.StatusPage();
            empty_label.compact = true;
            empty_label.icon_name = "preferences-system-notifications-symbolic";
            empty_label.title = _("No New Notifications");
            empty_label.description = _("Messages from your apps will appear here.");
            empty_label.vexpand = true;
            empty_label.margin_bottom = 30;
            append(empty_label);

            var manager = SystemMonitor.get_default().notifications;
            ulong h = manager.history_changed.connect(update_list);
            destroy.connect(() => manager.disconnect(h));
            update_list();
        }

        private static string signature(Gee.List<unowned Notification> items, bool expanded) {
            var sb = new StringBuilder(expanded ? "e" : "c");
            foreach (var n in items) sb.append_printf(":%u", n.id);
            return sb.str;
        }

        private void update_list() {
            unowned var history = SystemMonitor.get_default().notifications.get_history();
            var order = new Gee.ArrayList<string>();
            var groups = new Gee.HashMap<string, Gee.ArrayList<unowned Notification>>();
            foreach (unowned Notification notif in history) {
                string key = notif.group_key;
                if (!groups.has_key(key)) {
                    groups[key] = new Gee.ArrayList<unowned Notification>();
                    order.add(key);
                }
                groups[key].add(notif);
            }

            empty_label.visible = order.size == 0;
            list_box.visible = true;

            var gone = new Gee.ArrayList<string>();
            foreach (string key in _rows.keys) {
                if (!groups.has_key(key)) gone.add(key);
            }
            foreach (string key in gone) {
                var row = _rows[key];
                _rows.unset(key);
                _signatures.unset(key);
                _expanded.remove(key);
                animator.remove(row, () => {
                    if (row.get_parent() == list_box) list_box.remove(row);
                });
            }

            Widget? previous = null;
            foreach (string key in order) {
                var items = groups[key];
                string sig = signature(items, _expanded.contains(key));
                if (_rows.has_key(key)) {
                    var row = _rows[key];
                    if (_signatures[key] != sig) {
                        var bin = row as Singularity.Animation.MotionBin;
                        if (bin != null) bin.child = build_group(key, items);
                        _signatures[key] = sig;
                    }
                    if (row.get_prev_sibling() != previous) {
                        Widget? after = previous;
                        animator.move(() => list_box.reorder_child_after(row, after));
                    }
                    previous = row;
                    continue;
                }
                var row = Singularity.Animation.ListAnimator.wrap(build_group(key, items));
                var swipe = new SwipeDismiss(row);
                string group_key = key;
                swipe.dismissed.connect(() => dismiss_group(group_key));
                row.set_data<SwipeDismiss>("swipe-dismiss", swipe);
                _rows[key] = row;
                _signatures[key] = sig;
                Widget? after = previous;
                animator.insert(row, () => list_box.insert_child_after(row, after));
                previous = row;
            }
        }

        private void dismiss_group(string key) {
            unowned var manager = SystemMonitor.get_default().notifications;
            uint[] ids = {};
            foreach (unowned Notification notif in manager.get_history()) {
                if (notif.group_key == key) ids += notif.id;
            }
            foreach (var id in ids) manager.remove_from_history(id);
        }

        private Widget build_group(string key, Gee.List<unowned Notification> items) {
            if (items.size == 1) return new NotificationItem(items[0]);
            var group = new NotificationStack(items, _expanded.contains(key));
            group.toggled.connect((expanded) => {
                if (expanded) _expanded.add(key);
                else _expanded.remove(key);
                _signatures[key] = signature(items, expanded);
            });
            return group;
        }
    }

    public class FocusBanner : Box {
        private Image icon;
        private Label title;
        private Label subtitle;

        public FocusBanner() {
            Object(orientation: Orientation.HORIZONTAL, spacing: 10);
            add_css_class("focus-banner");
            icon = new Image();
            icon.pixel_size = 20;
            icon.valign = Align.CENTER;
            append(icon);
            var labels = new Box(Orientation.VERTICAL, 2);
            labels.hexpand = true;
            labels.valign = Align.CENTER;
            title = new Label("");
            title.add_css_class("focus-banner-title");
            title.halign = Align.START;
            title.ellipsize = Pango.EllipsizeMode.END;
            labels.append(title);
            subtitle = new Label("");
            subtitle.add_css_class("dim-label");
            subtitle.add_css_class("caption");
            subtitle.halign = Align.START;
            subtitle.wrap = true;
            subtitle.xalign = 0;
            labels.append(subtitle);
            append(labels);
            var off = new Button.with_label(_("Turn Off"));
            off.valign = Align.CENTER;
            off.clicked.connect(() => FocusManager.get_default().deactivate());
            append(off);
            var focus = FocusManager.get_default();
            ulong h = focus.changed.connect(sync);
            destroy.connect(() => focus.disconnect(h));
            sync();
        }

        private void sync() {
            var state = FocusManager.get_default().state;
            visible = state.active;
            if (!state.active) return;
            icon.icon_name = state.mode.icon_name;
            title.label = _("%s Is On").printf(FocusManager.display_name(state.mode));
            string why = state.reason == FocusReason.MANUAL ? "" : FocusManager.reason_label(state.reason) + ". ";
            subtitle.label = why + _("Notifications arrive quietly and wait here.");
        }
    }

    public class NotificationStack : Box {
        public signal void toggled(bool expanded);
        private bool expanded;
        private Revealer revealer;
        private Image expand_icon;
        private Gtk.Widget[] fan_items = {};

        public NotificationStack(Gee.List<unowned Notification> notifications, bool expanded) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.expanded = expanded;
            add_css_class("notification-group");
            add_css_class("notification-stack");

            unowned Notification newest = notifications[0];
            var header = new Box(Orientation.HORIZONTAL, 8);
            header.add_css_class("notification-group-header");
            header.margin_top = 10;
            header.margin_bottom = 4;
            header.margin_start = 12;
            header.margin_end = 10;

            var icon_img = new Image();
            icon_img.pixel_size = 16;
            load_notification_icon(icon_img, newest.icon, newest.app_name);
            header.append(icon_img);

            var app_label = new Label(newest.app_name);
            app_label.add_css_class("notification-group-appname");
            app_label.halign = Align.START;
            app_label.hexpand = true;
            app_label.ellipsize = Pango.EllipsizeMode.END;
            header.append(app_label);

            var count_label = new Label("%d".printf(notifications.size));
            count_label.add_css_class("notification-group-badge");
            count_label.set_size_request(20, 20);
            count_label.valign = Align.CENTER;
            header.append(count_label);

            var clear_btn = new Button.from_icon_name("edit-clear-all-symbolic");
            clear_btn.add_css_class("flat");
            clear_btn.add_css_class("circular");
            clear_btn.tooltip_text = _("Clear Stack");
            uint[] ids = {};
            foreach (var n in notifications) ids += n.id;
            clear_btn.clicked.connect(() => {
                unowned var mgr = SystemMonitor.get_default().notifications;
                foreach (var id in ids) mgr.remove_from_history(id);
            });
            header.append(clear_btn);

            expand_icon = new Image.from_icon_name(expanded ? "pan-up-symbolic" : "pan-down-symbolic");
            expand_icon.pixel_size = 12;
            var expand_btn = new Button();
            expand_btn.add_css_class("flat");
            expand_btn.add_css_class("circular");
            expand_btn.tooltip_text = expanded ? _("Show Less") : _("Show All");
            expand_btn.set_child(expand_icon);
            expand_btn.clicked.connect(toggle_expand);
            header.append(expand_btn);
            append(header);

            var summary = new Label(stack_summary(notifications));
            summary.add_css_class("notification-stack-summary");
            summary.add_css_class("caption");
            summary.halign = Align.START;
            summary.xalign = 0;
            summary.wrap = true;
            summary.margin_start = 36;
            summary.margin_end = 12;
            summary.margin_bottom = 6;
            append(summary);

            var top = new NotificationItem(newest, false);
            top.add_css_class("notification-stack-top");
            append(top);

            revealer = new Revealer();
            revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            revealer.transition_duration = Singularity.Motion.Duration.MEDIUM.ms();
            revealer.reveal_child = expanded;
            var items_box = new Box(Orientation.VERTICAL, 0);
            for (int i = 1; i < notifications.size; i++) {
                var item = new NotificationItem(notifications[i], false);
                item.add_css_class("notification-group-item");
                items_box.append(new Singularity.Animation.MotionBin(item));
                fan_items += item;
            }
            revealer.set_child(items_box);
            append(revealer);

            if (!expanded) {
                var edge = new Box(Orientation.VERTICAL, 0);
                edge.add_css_class("notification-stack-edge");
                append(edge);
            }

            var click = new GestureClick();
            click.button = 1;
            click.released.connect((n, x, y) => {
                var widget = header.pick(x, y, PickFlags.DEFAULT);
                if (widget is Button || (widget != null && widget.get_ancestor(typeof(Button)) != null)) return;
                toggle_expand();
            });
            header.add_controller(click);
        }

        public static string stack_summary(Gee.List<unowned Notification> notifications) {
            var names = new Gee.ArrayList<string>();
            int quiet = 0;
            foreach (var n in notifications) {
                if (n.silenced) quiet++;
                string s = n.summary.strip();
                if (s != "" && !names.contains(s)) names.add(s);
            }
            string text;
            if (names.size == 0) {
                text = ngettext("%d notification", "%d notifications", notifications.size).printf(notifications.size);
            } else if (names.size <= 2) {
                text = string.joinv(", ", names.to_array());
            } else {
                text = _("%s, %s and %d more").printf(names[0], names[1], names.size - 2);
            }
            if (quiet > 0) text += ", " + ngettext("%d delivered quietly", "%d delivered quietly", quiet).printf(quiet);
            return text;
        }

        private void toggle_expand() {
            expanded = !expanded;
            revealer.reveal_child = expanded;
            if (expanded && fan_items.length > 0) {
                Singularity.Motion.cascade(fan_items, Singularity.Motion.Preset.FADE_SLIDE);
            }
            expand_icon.icon_name = expanded ? "pan-up-symbolic" : "pan-down-symbolic";
            toggled(expanded);
        }
    }

    public class NotificationItem : Box {
        private Revealer reply_revealer;
        private Entry reply_entry;

        public NotificationItem(Notification notif, bool card = true) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            if (card) add_css_class("notification-item-card");
            else add_css_class("notification-item-plain");
            if (notif.silenced) add_css_class("notification-quiet");

            var header = new Box(Orientation.HORIZONTAL, 8);
            header.margin_top = 10;
            header.margin_start = 12;
            header.margin_end = 10;

            var icon_img = new Image();
            icon_img.pixel_size = 16;
            load_notification_icon(icon_img, notif.icon, notif.app_name);
            header.append(icon_img);

            var app_label = new Label(notif.app_name);
            app_label.add_css_class("caption");
            app_label.add_css_class("dim-label");
            app_label.hexpand = true;
            app_label.halign = Align.START;
            app_label.ellipsize = Pango.EllipsizeMode.END;
            header.append(app_label);

            var time_label = new Label(format_time(notif.timestamp));
            time_label.add_css_class("caption");
            time_label.add_css_class("dim-label");
            header.append(time_label);

            var close_btn = new Button.from_icon_name("window-close-symbolic");
            close_btn.add_css_class("flat");
            close_btn.add_css_class("circular");
            close_btn.tooltip_text = _("Dismiss");
            uint nid = notif.id;
            close_btn.clicked.connect(() => {
                var mgr = SystemMonitor.get_default().notifications;
                mgr.remove_from_history(nid);
                if (!notif.restored) mgr.report_closed(nid, 2);
            });
            header.append(close_btn);
            append(header);

            var content_box = new Box(Orientation.VERTICAL, 2);
            content_box.margin_start = 12;
            content_box.margin_end = 12;
            content_box.margin_bottom = 12;
            content_box.margin_top = 4;

            if (notif.summary != "") {
                var summary = new Label(notif.summary);
                summary.add_css_class("bold");
                summary.halign = Align.START;
                summary.wrap = true;
                summary.wrap_mode = Pango.WrapMode.WORD_CHAR;
                summary.xalign = 0;
                content_box.append(summary);
            }

            if (notif.body != "") {
                var body = new Label(notif.body);
                body.add_css_class("caption");
                body.halign = Align.START;
                body.wrap = true;
                body.wrap_mode = Pango.WrapMode.WORD_CHAR;
                body.xalign = 0;
                body.lines = 6;
                body.ellipsize = Pango.EllipsizeMode.END;
                content_box.append(body);
            }

            if (notif.silenced || notif.time_sensitive) {
                var tag = new Label(notif.silenced ? _("Delivered quietly") : _("Time-sensitive"));
                tag.add_css_class("caption");
                tag.add_css_class(notif.silenced ? "notification-quiet-tag" : "notification-urgent-tag");
                tag.halign = Align.START;
                tag.margin_top = 4;
                content_box.append(tag);
            }
            append(content_box);

            var open = new GestureClick();
            open.released.connect(() => open_notification(notif));
            content_box.add_controller(open);

            if (!notif.restored && notif.actions.length > 0) {
                var actions_box = new Box(Orientation.HORIZONTAL, 4);
                actions_box.homogeneous = true;
                actions_box.margin_bottom = 8;
                actions_box.margin_start = 8;
                actions_box.margin_end = 8;

                for (int i = 0; i + 1 < notif.actions.length; i += 2) {
                    string key = notif.actions[i];
                    string label = notif.actions[i + 1];
                    if (key == "default") continue;
                    var btn = new Button.with_label(label != "" ? label : _("Reply"));
                    btn.add_css_class("flat");
                    if (key == "inline-reply") {
                        btn.clicked.connect(() => toggle_reply());
                    } else {
                        btn.clicked.connect(() => {
                            SystemMonitor.get_default().notifications.invoke_action(nid, key);
                        });
                    }
                    actions_box.append(btn);
                }
                if (actions_box.get_first_child() != null) {
                    append(actions_box);
                }
            }

            if (notif.has_inline_reply) {
                reply_revealer = new Revealer();
                reply_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
                reply_revealer.transition_duration = Singularity.Motion.Duration.SMALL.ms();
                var reply_box = new Box(Orientation.HORIZONTAL, 6);
                reply_box.add_css_class("notification-reply");
                reply_box.margin_start = 10;
                reply_box.margin_end = 10;
                reply_box.margin_bottom = 10;
                reply_entry = new Entry();
                reply_entry.hexpand = true;
                reply_entry.placeholder_text = notif.reply_placeholder != "" ? notif.reply_placeholder : _("Reply");
                var send = new Button.from_icon_name("mail-send-symbolic");
                send.add_css_class("suggested-action");
                send.add_css_class("circular");
                send.tooltip_text = notif.reply_submit != "" ? notif.reply_submit : _("Send");
                send.sensitive = false;
                reply_entry.changed.connect(() => send.sensitive = reply_entry.text.strip() != "");
                reply_entry.activate.connect(() => send_reply(nid));
                send.clicked.connect(() => send_reply(nid));
                reply_box.append(reply_entry);
                reply_box.append(send);
                reply_revealer.set_child(reply_box);
                append(reply_revealer);
            }
        }

        private void toggle_reply() {
            if (reply_revealer == null) return;
            reply_revealer.reveal_child = !reply_revealer.reveal_child;
            if (reply_revealer.reveal_child) reply_entry.grab_focus();
        }

        private void send_reply(uint id) {
            string text = reply_entry.text.strip();
            if (text == "") return;
            SystemMonitor.get_default().notifications.reply(id, text);
        }

        public static void open_notification(Notification notif) {
            var mgr = SystemMonitor.get_default().notifications;
            if (!notif.restored) {
                for (int i = 0; i + 1 < notif.actions.length; i += 2) {
                    if (notif.actions[i] == "default") {
                        mgr.invoke_action(notif.id, "default");
                        return;
                    }
                }
            }
            DesktopAppInfo? info = null;
            if (notif.desktop_entry != "") {
                string id = notif.desktop_entry.has_suffix(".desktop") ? notif.desktop_entry : notif.desktop_entry + ".desktop";
                info = new DesktopAppInfo(id);
            }
            if (info == null) info = AppNotificationSettings.app_info(notif.app_key);
            if (info == null) return;
            try {
                info.launch(null, Gdk.Display.get_default().get_app_launch_context());
            } catch (Error e) {
                warning("notification: could not open %s: %s", info.get_id(), e.message);
            }
        }

        public static string format_time(int64 timestamp) {
            var now = GLib.get_real_time();
            var diff = (now - timestamp) / 1000000;

            if (diff < 60) return _("Just now");
            if (diff < 3600) return _("%dm ago").printf((int) (diff / 60));
            if (diff < 86400) return _("%dh ago").printf((int) (diff / 3600));
            var dt = new DateTime.from_unix_local(timestamp / 1000000);
            return dt.format("%x");
        }
    }

    public static void load_notification_icon(Image img, string icon_str, string app_name) {
        if (icon_str.has_prefix("/")) {
            try {
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(icon_str, 48, 48, true);
                img.paintable = Gdk.Texture.for_pixbuf(pixbuf);
                return;
            } catch {}
        } else if (icon_str.has_prefix("file://")) {
            try {
                var path = GLib.Filename.from_uri(icon_str);
                var pixbuf = new Gdk.Pixbuf.from_file_at_scale(path, 48, 48, true);
                img.paintable = Gdk.Texture.for_pixbuf(pixbuf);
                return;
            } catch {}
        }

        if (icon_str != "") {
            var theme = Gtk.IconTheme.get_for_display(Gdk.Display.get_default());
            if (theme.has_icon(icon_str)) {
                img.icon_name = icon_str;
                return;
            }
        }

        if (app_name != "") {
            string needle = app_name.down();
            string needle_compact = needle.replace(" ", "").replace("-", "").replace("_", "");
            foreach (var info in GLib.AppInfo.get_all()) {
                string nm = info.get_name().down();
                string nm_compact = nm.replace(" ", "").replace("-", "").replace("_", "");
                string aid = info.get_id().down();
                if (aid.has_suffix(".desktop"))
                    aid = aid.substring(0, aid.length - ".desktop".length);
                string aid_compact = aid.replace(".", "").replace("-", "").replace("_", "");
                if (nm.contains(needle) ||
                    needle.contains(nm) ||
                    nm_compact.contains(needle_compact) ||
                    needle_compact.contains(nm_compact) ||
                    aid_compact.contains(needle_compact) ||
                    needle_compact.contains(aid_compact)) {
                    var gicon = info.get_icon();
                    if (gicon != null) {
                        img.gicon = gicon;
                        return;
                    }
                }
            }
        }

        img.icon_name = "dialog-information-symbolic";
    }
}
