using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class NotificationDisplay : Gtk.Window {
        private Box main_box;
        private HashTable<uint, NotificationBubble> bubbles;
        private HashTable<uint, SwipeDismiss> swipes;
        private Singularity.Animation.ListAnimator animator;
        private bool height_pinned = false;
        private const double ENTER_OFFSET = 24.0;

        public NotificationDisplay(Gtk.Application app) {
            Object(application: app);
            bubbles = new HashTable<uint, NotificationBubble>(null, null);
            swipes = new HashTable<uint, SwipeDismiss>(null, null);
            init_for_window(this);
            set_layer(this, GtkLayerShell.Layer.OVERLAY);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, false);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, false);
            set_margin(this, GtkLayerShell.Edge.TOP, 12);
            set_margin(this, GtkLayerShell.Edge.RIGHT, 12);
            add_css_class("singularity");
        add_css_class("singularity-shell");
        add_css_class("notification-display");
            main_box = new Box(Orientation.VERTICAL, 8);
            set_child(main_box);
            animator = new Singularity.Animation.ListAnimator(main_box);
            var manager = SystemMonitor.get_default().notifications;
            manager.new_notification.connect(on_new_notification);
            manager.close_notification_request.connect(on_close_request);
            this.visible = false;
        }

        private void on_new_notification(uint id, string app_name, string summary, string body, string icon, string[] actions) {
            var manager = SystemMonitor.get_default().notifications;
            if (!manager.should_show_banner(id)) return;

            if (bubbles.contains(id)) {
                var bubble = bubbles.get(id);
                bubble.update(summary, body, icon);
            } else {
                var bubble = new NotificationBubble(id, app_name, summary, body, icon, actions);
                bubble.closed.connect(() => {
                    remove_bubble(id, 2, true);
                });
                bubble.expired.connect(() => {
                    remove_bubble(id, 1, false);
                });
                bubble.action_invoked.connect((action) => {
                    SystemMonitor.get_default().notifications.invoke_action(id, action);
                });
                bubble.replied.connect((text) => {
                    SystemMonitor.get_default().notifications.reply(id, text, false);
                    remove_bubble(id, 2, true);
                });
                bubbles.set(id, bubble);
                var bin = new Singularity.Animation.MotionBin(bubble);
                bin.notify["translate-y"].connect(release_height_if_settled);
                var swipe = new SwipeDismiss(bin);
                swipe.started.connect(() => bubble.pause_expiry());
                swipe.cancelled.connect(() => bubble.resume_expiry());
                swipe.dismissed.connect(() => remove_bubble(id, 2, true));
                swipes.set(id, swipe);
                this.visible = true;
                animator.insert(bin, () => main_box.prepend(bin));
                if (!Singularity.Motion.reduced()) {
                    bin.origin_y = 0.0;
                    bin.translate_y = -ENTER_OFFSET;
                    Singularity.Motion.spring_to(bin, "translate-y", 0.0, Singularity.Motion.Spring.SNAPPY);
                }
            }
            this.visible = true;
        }

        private void on_close_request(uint id) {
            remove_bubble(id, 3, true);
        }

        /**
         * @param notify_daemon  Whether to also report the closure back to
         *                       the notification daemon. False for "timed
         *                       out on screen" - that scenario removes the
         *                       popup only; the notification stays in the
         *                       centre and plugins should keep their state.
         */
        private void release_keyboard_unless_replying() {
            foreach (var b in bubbles.get_values()) {
                if (b.replying) return;
            }
            GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
        }

        private void remove_bubble(uint id, uint reason, bool notify_daemon) {
            if (!bubbles.contains(id)) return;
            var bubble = bubbles.get(id);
            var swipe = swipes.get(id);
            bubbles.remove(id);
            swipes.remove(id);
            release_keyboard_unless_replying();
            var holder = bubble.get_parent();
            if (holder == null || holder.get_parent() != main_box) return;
            Singularity.Animation.ListChange change = () => {
                pin_height();
                if (holder.get_parent() == main_box) main_box.remove(holder);
                if (notify_daemon)
                    SystemMonitor.get_default().notifications.report_closed(id, reason);
                if (bubbles.size() == 0) {
                    GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.NONE);
                    height_pinned = false;
                    main_box.height_request = -1;
                    this.visible = false;
                    return;
                }
                main_box.add_tick_callback(() => {
                    release_height_if_settled();
                    return GLib.Source.REMOVE;
                });
            };
            if (swipe != null && swipe.leaving) animator.move((owned) change);
            else animator.remove(holder, (owned) change);
        }

        private void pin_height() {
            if (height_pinned) return;
            height_pinned = true;
            main_box.height_request = main_box.get_height();
        }

        private void release_height_if_settled() {
            if (!height_pinned) return;
            for (var child = main_box.get_first_child(); child != null; child = child.get_next_sibling()) {
                var bin = child as Singularity.Animation.MotionBin;
                if (bin != null && bin.translate_y != 0.0) return;
            }
            height_pinned = false;
            main_box.height_request = -1;
        }
    }
    public class NotificationBubble : Box {
        public uint id { get; private set; }
        // User explicitly closed the popup (X button) - notification should
        // be marked dismissed (reason=2) so it ALSO goes away from the
        // notification centre and plugins drop their derived state.
        public signal void closed();
        // Popup timed out on its own - notification stays in the history /
        // notification centre. Plugins should keep their derived state
        // (e.g. unread bubble) until the user actually dismisses the entry
        // in the centre. Reported as reason=1 (EXPIRED) per spec.
        public signal void expired();
        public signal void action_invoked(string action);
        public signal void replied(string text);
        private Label summary_label;
        private Label body_label;
        private Image icon_image;
        private uint _timeout_id = 0;
        private bool _expiry_paused = false;
        private Revealer? reply_revealer = null;
        public bool replying { get { return reply_revealer != null && reply_revealer.reveal_child; } }
        private Entry? reply_entry = null;

        public NotificationBubble(uint id, string app_name, string summary, string body, string icon_name, string[] actions) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.id = id;
            add_css_class("notification-bubble");

            // Top row: app name + close button
            var top_row = new Box(Orientation.HORIZONTAL, 0);
            top_row.add_css_class("notification-header");
            top_row.margin_top = 10;
            top_row.margin_start = 14;
            top_row.margin_end = 6;
            top_row.margin_bottom = 6;

            var app_label = new Label(app_name.up());
            app_label.add_css_class("notification-app-name");
            app_label.hexpand = true;
            app_label.halign = Align.START;
            app_label.ellipsize = Pango.EllipsizeMode.END;
            app_label.max_width_chars = 22;

            var close_btn = new Button();
            close_btn.add_css_class("notification-close");
            var close_icon = new Image.from_icon_name("window-close-symbolic");
            close_icon.pixel_size = 12;
            close_btn.set_child(close_icon);
            close_btn.clicked.connect(() => { closed(); });

            top_row.append(app_label);
            top_row.append(close_btn);
            append(top_row);

            // Content row: icon + title + body
            var content = new Box(Orientation.HORIZONTAL, 12);
            content.margin_bottom = 14;
            content.margin_start = 14;
            content.margin_end = 14;
            content.margin_top = 0;

            icon_image = new Image.from_icon_name("dialog-information-symbolic");
            icon_image.pixel_size = 42;
            icon_image.valign = Align.START;
            icon_image.add_css_class("notification-icon");
            load_notification_icon(icon_image, icon_name, app_name);

            var text_box = new Box(Orientation.VERTICAL, 3);
            text_box.valign = Align.CENTER;

            summary_label = new Label(summary);
            summary_label.add_css_class("notification-title");
            summary_label.halign = Align.START;
            summary_label.wrap = true;
            summary_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            summary_label.max_width_chars = 26;

            body_label = new Label(body);
            body_label.add_css_class("notification-body");
            body_label.halign = Align.START;
            body_label.wrap = true;
            body_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            body_label.max_width_chars = 26;
            body_label.visible = (body != "");

            text_box.append(summary_label);
            text_box.append(body_label);
            content.append(icon_image);
            content.append(text_box);
            append(content);

            int buttons = 0;
            for (int i = 0; i + 1 < actions.length; i += 2) {
                if (actions[i] == "default") {
                    var open = new GestureClick();
                    open.released.connect(() => { action_invoked("default"); });
                    content.add_controller(open);
                } else {
                    buttons++;
                }
            }

            if (buttons > 0) {
                var sep = new Separator(Orientation.HORIZONTAL);
                sep.add_css_class("notification-separator");
                append(sep);
                var actions_box = new Box(Orientation.HORIZONTAL, 0);
                actions_box.homogeneous = true;
                for (int i = 0; i < actions.length; i += 2) {
                    if (i + 1 < actions.length && actions[i] != "default") {
                        string key = actions[i];
                        string lbl = actions[i+1];
                        var btn = new Button.with_label(lbl != "" ? lbl : _("Reply"));
                        btn.add_css_class("notification-action");
                        if (key == "inline-reply") {
                            btn.clicked.connect(() => show_reply());
                        } else {
                            btn.clicked.connect(() => { action_invoked(key); });
                        }
                        actions_box.append(btn);
                    }
                }
                append(actions_box);
            }

            var stored = SystemMonitor.get_default().notifications.find(id);
            if (stored != null && stored.has_inline_reply) {
                reply_revealer = new Revealer();
                reply_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
                reply_revealer.transition_duration = Singularity.Motion.Duration.SMALL.ms();
                var reply_box = new Box(Orientation.HORIZONTAL, 6);
                reply_box.add_css_class("notification-reply");
                reply_box.margin_start = 12;
                reply_box.margin_end = 12;
                reply_box.margin_bottom = 12;
                reply_entry = new Entry();
                reply_entry.hexpand = true;
                reply_entry.placeholder_text = stored.reply_placeholder != "" ? stored.reply_placeholder : _("Reply");
                reply_entry.activate.connect(() => {
                    if (reply_entry.text.strip() != "") replied(reply_entry.text.strip());
                });
                var send = new Button.from_icon_name("mail-send-symbolic");
                send.add_css_class("suggested-action");
                send.add_css_class("circular");
                send.tooltip_text = _("Send");
                send.clicked.connect(() => {
                    if (reply_entry.text.strip() != "") replied(reply_entry.text.strip());
                });
                reply_box.append(reply_entry);
                reply_box.append(send);
                reply_revealer.set_child(reply_box);
                append(reply_revealer);
            }

            uint seconds = stored != null && stored.time_sensitive ? 10 : 5;
            if (id != 999999u && !SystemMonitor.get_default().notifications.is_critical(id)) {
                _timeout_id = Timeout.add_seconds(seconds, () => {
                    _timeout_id = 0;
                    expired ();
                    return false;
                });
            }
        }
        ~NotificationBubble() {
            if (_timeout_id != 0) {
                Source.remove(_timeout_id);
                _timeout_id = 0;
            }
        }

        private void show_reply() {
            if (reply_revealer == null) return;
            if (_timeout_id != 0) {
                Source.remove(_timeout_id);
                _timeout_id = 0;
            }
            reply_revealer.reveal_child = true;
            var esc = new EventControllerKey();
            esc.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                closed();
                return true;
            });
            reply_entry.add_controller(esc);
            var win = get_root() as Gtk.Window;
            if (win != null) GtkLayerShell.set_keyboard_mode(win, GtkLayerShell.KeyboardMode.EXCLUSIVE);
            reply_entry.grab_focus();
        }

        public void pause_expiry() {
            if (_timeout_id == 0) return;
            Source.remove(_timeout_id);
            _timeout_id = 0;
            _expiry_paused = true;
        }

        public void resume_expiry() {
            if (!_expiry_paused) return;
            _expiry_paused = false;
            _timeout_id = Timeout.add_seconds(3, () => {
                _timeout_id = 0;
                expired ();
                return false;
            });
        }

        public void update(string summary, string body, string icon_name) {
            summary_label.label = summary;
            body_label.label = body;
            body_label.visible = (body != "");
            load_notification_icon(icon_image, icon_name, "");
        }
    }
}
