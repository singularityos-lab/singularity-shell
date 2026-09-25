using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class NotificationDisplay : Gtk.Window {
        private Box main_box;
        private HashTable<uint, NotificationBubble> bubbles;
        private GLib.List<Singularity.Animation.TimedAnimation> _active_anims = new GLib.List<Singularity.Animation.TimedAnimation>();

        public NotificationDisplay(Gtk.Application app) {
            Object(application: app);
            bubbles = new HashTable<uint, NotificationBubble>(null, null);
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
            var manager = SystemMonitor.get_default().notifications;
            manager.new_notification.connect(on_new_notification);
            manager.close_notification_request.connect(on_close_request);
            this.visible = false;
        }

        private void on_new_notification(uint id, string app_name, string summary, string body, string icon, string[] actions) {
            // DnD: the daemon now ALWAYS fires new_notification (plugins like
            // messaging-dock need the event to update their dock bubble state
            // even when popups are silenced). We're the one screen-popup
            // consumer, so we gate visibility here instead.
            if (SystemMonitor.get_default().notifications.do_not_disturb_active) return;

            if (bubbles.contains(id)) {
                var bubble = bubbles.get(id);
                bubble.update(summary, body, icon);
            } else {
                var bubble = new NotificationBubble(id, app_name, summary, body, icon, actions);
                // X-button click: user explicitly dismisses -> mirror to the
                // notification centre (reason=2) and let plugins clear state.
                bubble.closed.connect(() => {
                    remove_bubble(id, 2, true);
                });
                // Timeout: the popup goes away but the notification stays
                // in the centre. Notify plugins with reason=1 so they keep
                // showing their derived state (dock bubbles, badges) until
                // the user actually dismisses the entry.
                bubble.expired.connect(() => {
                    remove_bubble(id, 1, false);
                });
                bubble.action_invoked.connect((action) => {
                    SystemMonitor.get_default().notifications.invoke_action(id, action);
                });
                bubbles.set(id, bubble);
                bubble.opacity = 0;
                main_box.prepend(bubble);
                // Fade in. A previous slide animated a negative margin_end,
                // which allocated the bubble below its minimum width and
                // flooded the log with "must not decrease below min" warnings.
                var anim = new Singularity.Animation.TimedAnimation(
                    bubble, 0, 1, 250,
                    Singularity.Animation.TimedAnimation.Easing.EASE_OUT_CUBIC
                );
                anim.tick.connect(() => {
                    bubble.opacity = anim.value;
                });
                anim.play();
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
        private void remove_bubble(uint id, uint reason, bool notify_daemon) {
            if (!bubbles.contains(id)) return;
            var bubble = bubbles.get(id);
            bubbles.remove(id);
            var anim = new Singularity.Animation.TimedAnimation(
                bubble, 1, 0, 200,
                Singularity.Animation.TimedAnimation.Easing.EASE_IN_CUBIC
            );
            _active_anims.append(anim);
            anim.tick.connect(() => {
                bubble.opacity = anim.value;
            });
            anim.done.connect(() => {
                _active_anims.remove(anim);
                if (bubble.get_parent() != null) main_box.remove(bubble);
                if (notify_daemon)
                    SystemMonitor.get_default().notifications.report_closed(id, reason);
                if (bubbles.size() == 0) {
                    this.visible = false;
                }
            });
            anim.play();
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
        private Label summary_label;
        private Label body_label;
        private Image icon_image;
        private uint _timeout_id = 0;

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
                        var btn = new Button.with_label(lbl);
                        btn.add_css_class("notification-action");
                        btn.clicked.connect(() => { action_invoked(key); });
                        actions_box.append(btn);
                    }
                }
                append(actions_box);
            }

            if (id != 999999u && !SystemMonitor.get_default().notifications.is_critical(id)) {
                _timeout_id = Timeout.add_seconds(5, () => {
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

        public void update(string summary, string body, string icon_name) {
            summary_label.label = summary;
            body_label.label = body;
            body_label.visible = (body != "");
            load_notification_icon(icon_image, icon_name, "");
        }
    }
}
