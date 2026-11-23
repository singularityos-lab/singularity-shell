using Gtk;

namespace Singularity {

    public class HubView : Box {
        private const int PEEK_EDGE = 64;
        private const int DOCKED_ACCOUNTS = 300;
        private const string[] ACCOUNT_COLORS = {
            "#2f8fdd", "#e2a52b", "#3fae6a", "#d9534f", "#8e6bd8", "#1fa7a0", "#e0742f", "#c2499b"
        };

        private HubStore store;
        private string? _account = null;
        private bool _unread_only = false;
        private bool _sidebar_open = false;

        private Label _title;
        private Label _count;
        private Box _groups;
        private ScrolledWindow _scroller;
        private Box _accounts;
        private Singularity.Animation.MotionBin _sheet;
        private Singularity.Widgets.ToastOverlay _toasts;
        private Label _filter_note;
        private Singularity.Widgets.StatusPage? _empty = null;
        private uint _refresh_source = 0;
        private Overlay _sheet_layers;
        private HubCard? _card = null;
        private bool _docked = false;
        private Widget _list_column;
        private Box? _detail = null;
        private Singularity.Widgets.StatusPage? _detail_empty = null;
        private HubAgenda _agenda;

        public signal void close_requested();

        public HubView() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("hub-view");
            store = HubStore.get_default();

            var header = new Box(Orientation.HORIZONTAL, 8);
            header.add_css_class("hub-header");
            var sidebar_button = new Button.from_icon_name("sidebar-show-symbolic");
            sidebar_button.add_css_class("flat");
            sidebar_button.tooltip_text = _("Accounts");
            sidebar_button.clicked.connect(() => set_sidebar(!_sidebar_open));
            header.append(sidebar_button);
            _title = new Label(_("Hub"));
            _title.add_css_class("title-3");
            _title.xalign = 0;
            _title.ellipsize = Pango.EllipsizeMode.END;
            header.append(_title);
            _count = new Label("");
            _count.add_css_class("hub-count");
            _count.valign = Align.CENTER;
            header.append(_count);
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            header.append(spacer);
            var filter = new Button.from_icon_name("mail-unread-symbolic");
            filter.add_css_class("flat");
            filter.tooltip_text = _("Unread Only");
            filter.clicked.connect(() => set_unread_only(!_unread_only));
            header.append(filter);
            var more = new Button.from_icon_name("view-more-symbolic");
            more.add_css_class("flat");
            more.tooltip_text = _("More");
            more.clicked.connect(() => show_more(more));
            header.append(more);

            _filter_note = new Label(_("Unread"));
            _filter_note.add_css_class("hub-filter-note");
            _filter_note.visible = false;

            _groups = new Box(Orientation.VERTICAL, 12);
            _groups.add_css_class("hub-list");
            _groups.margin_start = 12;
            _groups.margin_end = 12;
            _groups.margin_bottom = 24;
            _scroller = new ScrolledWindow();
            _scroller.hscrollbar_policy = PolicyType.NEVER;
            _scroller.vexpand = true;
            _scroller.child = _groups;

            var list_column = new Box(Orientation.VERTICAL, 0);
            _list_column = list_column;
            list_column.add_css_class("hub-sheet");
            list_column.append(header);
            list_column.append(_filter_note);
            _agenda = new HubAgenda();
            _agenda.event_activated.connect(open_event);
            list_column.append(_agenda);
            list_column.append(_scroller);
            _sheet_layers = new Overlay();
            _docked = Singularity.FormFactor.get_default().kind == Singularity.FormFactorKind.TABLET;
            if (_docked) {
                _detail = new Box(Orientation.VERTICAL, 0);
                _detail.add_css_class("hub-detail");
                _detail.hexpand = true;
                _detail_empty = new Singularity.Widgets.StatusPage();
                _detail_empty.icon_name = "mail-inbox-symbolic";
                _detail_empty.title = _("Nothing Selected");
                _detail_empty.description = _("Choose a message to read it here.");
                _detail_empty.vexpand = true;
                _detail.append(_detail_empty);
                var split = new Singularity.Widgets.SplitView(list_column, _detail);
                split.list_fraction = 0.45;
                split.detail_min_width = 0;
                list_column.remove_css_class("hub-sheet");
                split.add_css_class("hub-sheet");
                _sheet_layers.child = split;
            } else {
                _sheet_layers.child = list_column;
            }
            _sheet = new Singularity.Animation.MotionBin(_sheet_layers);
            _sheet.transform_input = true;

            _accounts = new Box(Orientation.VERTICAL, 2);
            _accounts.add_css_class("hub-accounts");
            var accounts_scroller = new ScrolledWindow();
            accounts_scroller.hscrollbar_policy = PolicyType.NEVER;
            accounts_scroller.child = _accounts;
            accounts_scroller.margin_end = PEEK_EDGE;
            if (_docked) {
                accounts_scroller.margin_end = 0;
                accounts_scroller.halign = Align.START;
                accounts_scroller.width_request = DOCKED_ACCOUNTS;
            }

            var layers = new Overlay();
            layers.child = accounts_scroller;
            layers.add_overlay(_sheet);
            _toasts = new Singularity.Widgets.ToastOverlay();
            _toasts.child = layers;
            _toasts.vexpand = true;
            append(_toasts);

            install_gestures(list_column);
            store.changed.connect(queue_refresh);
            HubConfig.get_default().changed.connect(queue_refresh);
            refresh();
        }

        public double close_swipe_from(double fallback) {
            if (!_docked || _sidebar_open) return fallback;
            Graphene.Rect bounds;
            if (!_list_column.compute_bounds(this, out bounds)) return fallback;
            return double.min(fallback, bounds.origin.x + bounds.size.width);
        }

        private double sidebar_travel() {
            if (_docked) return double.min(DOCKED_ACCOUNTS, double.max(0, get_width() - PEEK_EDGE));
            return double.max(0, get_width() - PEEK_EDGE);
        }

        public void set_sidebar(bool open) {
            _sidebar_open = open;
            if (open) rebuild_accounts();
            Singularity.Motion.spring_to(_sheet, "translate-x", open ? sidebar_travel() : 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        public void reset() {
            drop_card();
            Singularity.Motion.cancel(_agenda, "reveal");
            _agenda.reveal = 0;
            _sidebar_open = false;
            _sheet.translate_x = 0;
            _scroller.vadjustment.value = 0;
        }

        private void set_unread_only(bool on) {
            _unread_only = on;
            _filter_note.visible = on;
            refresh();
        }

        private void select_account(string? id) {
            _account = id;
            var a = id != null ? store.account(id) : null;
            _title.label = a != null ? a.name : _("Hub");
            set_sidebar(false);
            _scroller.vadjustment.value = 0;
            refresh();
        }

        private void install_gestures(Widget sheet) {
            var zoom = new GestureZoom();
            zoom.end.connect(() => {
                double scale = zoom.get_scale_delta();
                if (scale < 0.85 && !_unread_only) set_unread_only(true);
                else if (scale > 1.15 && _unread_only) set_unread_only(false);
            });
            sheet.add_controller(zoom);

            var peek = new GestureDrag();
            double origin = 0;
            bool active = false;
            peek.drag_begin.connect((x, y) => {
                active = false;
                origin = _sheet.translate_x;
                bool from_edge = _sidebar_open ? x < PEEK_EDGE : x < 24;
                if (!from_edge) peek.set_state(EventSequenceState.DENIED);
            });
            peek.drag_update.connect((dx, dy) => {
                if (!active) {
                    if (Math.fabs(dx) < 12 || Math.fabs(dx) < Math.fabs(dy)) return;
                    active = true;
                    peek.set_state(EventSequenceState.CLAIMED);
                    Singularity.Motion.cancel(_sheet, "translate-x");
                    rebuild_accounts();
                }
                _sheet.translate_x = (origin + dx).clamp(0, sidebar_travel());
            });
            peek.drag_end.connect((dx, dy) => {
                if (!active) return;
                active = false;
                set_sidebar(_sheet.translate_x > sidebar_travel() * 0.5);
            });
            sheet.add_controller(peek);

            var pull = new GestureDrag();
            pull.propagation_phase = PropagationPhase.CAPTURE;
            double pull_origin = 0;
            bool pulling = false;
            pull.drag_begin.connect((x, y) => {
                pulling = false;
                pull_origin = _agenda.reveal;
                if (_sidebar_open || (pull_origin <= 0 && _scroller.vadjustment.value > 0.5)) {
                    pull.set_state(EventSequenceState.DENIED);
                }
            });
            pull.drag_update.connect((dx, dy) => {
                if (!pulling) {
                    if (Math.fabs(dy) < 12 || Math.fabs(dy) < Math.fabs(dx)) return;
                    if (pull_origin <= 0 && (dy < 0 || _scroller.vadjustment.value > 0.5)) {
                        pull.set_state(EventSequenceState.DENIED);
                        return;
                    }
                    pulling = true;
                    pull.set_state(EventSequenceState.CLAIMED);
                    Singularity.Motion.cancel(_agenda, "reveal");
                }
                double full = _agenda.open_height();
                double target = pull_origin + dy;
                if (target > full) target = full + (target - full) * 0.3;
                _agenda.reveal = double.max(0, target);
            });
            pull.drag_end.connect((dx, dy) => {
                if (!pulling) return;
                pulling = false;
                double full = _agenda.open_height();
                bool open = pull_origin <= 0 ? _agenda.reveal > full * 0.3 : _agenda.reveal > full * 0.7;
                set_agenda(open);
            });
            sheet.add_controller(pull);

            var close_tap = new GestureClick();
            close_tap.propagation_phase = PropagationPhase.CAPTURE;
            close_tap.pressed.connect((n, x, y) => {
                if (!_sidebar_open) return;
                close_tap.set_state(EventSequenceState.CLAIMED);
                set_sidebar(false);
            });
            sheet.add_controller(close_tap);

            var keys = new EventControllerKey();
            keys.key_pressed.connect((keyval, code, state) => {
                if ((state & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.ALT_MASK)) != 0) return false;
                switch (keyval) {
                    case Gdk.Key.t: _scroller.vadjustment.value = 0; return true;
                    case Gdk.Key.b: _scroller.vadjustment.value = _scroller.vadjustment.upper; return true;
                    case Gdk.Key.u: next_unread(); return true;
                    case Gdk.Key.Escape: return close_card();
                    default: return false;
                }
            });
            add_controller(keys);
        }

        private void set_agenda(bool open) {
            Singularity.Motion.spring_to(_agenda, "reveal", open ? _agenda.open_height() : 0.0, Singularity.Motion.Spring.SNAPPY);
        }

        private void open_event(Singularity.Calendar.CalendarEvent evt) {
            var start = evt.occurrence_start ?? evt.start_time;
            string arg = ("%s\t%s\t%" + int64.FORMAT).printf(evt.calendar_id ?? "", evt.id ?? "", start.to_unix());
            HubPeek.get_default().expect("dev.sinty.calendar");
            AppActions.activate.begin("dev.sinty.calendar", "open-event", new Variant.string(arg));
        }

        private void next_unread() {
            foreach (var item in visible_items()) {
                if (item.unread) {
                    show_card(item);
                    return;
                }
            }
        }

        private Gee.List<Hub.Item> visible_items() {
            var list = new Gee.ArrayList<Hub.Item>();
            foreach (var item in store.items(_account)) {
                if (_unread_only && !item.unread) continue;
                if (_account == null && HubConfig.get_default().is_hidden(item.account)) continue;
                list.add(item);
            }
            return list;
        }

        private void queue_refresh() {
            if (_refresh_source != 0) return;
            _refresh_source = Idle.add(() => {
                _refresh_source = 0;
                refresh();
                if (_sidebar_open) rebuild_accounts();
                return Source.REMOVE;
            });
        }

        private void refresh() {
            for (Widget? c = _groups.get_first_child(); c != null; ) {
                var next = c.get_next_sibling();
                _groups.remove(c);
                c = next;
            }
            int unread = store.unread(_account);
            _count.label = unread > 0 ? unread.to_string() : "";
            _count.visible = unread > 0;

            var items = visible_items();
            if (items.size == 0) {
                if (_empty == null) {
                    _empty = new Singularity.Widgets.StatusPage();
                    _empty.icon_name = "mail-inbox-symbolic";
                    _empty.vexpand = true;
                }
                _empty.title = _unread_only ? _("No Unread Items") : _("Nothing Here");
                _empty.description = _unread_only ? _("Pinch out to show everything again.")
                    : _("Messages, calls and notifications appear here as they arrive.");
                _groups.append(_empty);
                return;
            }

            Singularity.Widgets.PreferencesGroup? group = null;
            string day = "";
            foreach (var item in items) {
                var when = new DateTime.from_unix_local(item.timestamp);
                string key = when.format("%Y-%m-%d");
                if (group == null || key != day) {
                    day = key;
                    group = new Singularity.Widgets.PreferencesGroup(day_title(when));
                    group.add_css_class("hub-day");
                    _groups.append(group);
                }
                group.add_row(build_row(item));
            }
        }

        private static string day_title(DateTime when) {
            var now = new DateTime.now_local();
            var today = new DateTime.local(now.get_year(), now.get_month(), now.get_day_of_month(), 0, 0, 0);
            var that = new DateTime.local(when.get_year(), when.get_month(), when.get_day_of_month(), 0, 0, 0);
            int days = (int) (today.difference(that) / TimeSpan.DAY);
            if (days == 0) return _("Today");
            if (days == 1) return _("Yesterday");
            if (days < 7) return capitalize(when.format("%A"));
            if (when.get_year() == now.get_year()) return capitalize(when.format("%A %e %B").replace("  ", " "));
            return capitalize(when.format("%e %B %Y").strip());
        }

        private static string capitalize(string s) {
            if (s == "") return s;
            unichar first = s.get_char(0);
            return first.totitle().to_string() + s.substring(s.index_of_nth_char(1));
        }

        private string account_color(string id) {
            int i = 0;
            foreach (var a in store.accounts) {
                if (a.id == id) return ACCOUNT_COLORS[i % ACCOUNT_COLORS.length];
                i++;
            }
            return ACCOUNT_COLORS[0];
        }

        private Widget color_strip(string id, string css) {
            var strip = new DrawingArea();
            strip.add_css_class(css);
            strip.width_request = 4;
            strip.vexpand = true;
            Gdk.RGBA rgba = Gdk.RGBA();
            rgba.parse(css == "hub-priority-strip" ? "#d9363e" : account_color(id));
            strip.set_draw_func((area, cr, w, h) => {
                Gdk.cairo_set_source_rgba(cr, rgba);
                cr.rectangle(0, 0, w, h);
                cr.fill();
            });
            return strip;
        }

        private const int ROW_ICON = 32;

        private static GLib.Icon? app_icon(string app_id) {
            if (app_id == "") return null;
            string desktop = app_id.has_suffix(".desktop") ? app_id : app_id + ".desktop";
            var info = new DesktopAppInfo(desktop);
            var theme = IconTheme.get_for_display(Gdk.Display.get_default());
            if (info != null && info.get_icon() != null) {
                var icon = info.get_icon();
                if (!(icon is ThemedIcon) || theme.has_gicon(icon)) return icon;
            }
            string name = app_id.has_suffix(".desktop") ? app_id.substring(0, app_id.length - 8) : app_id;
            return theme.has_icon(name) ? new ThemedIcon(name) : null;
        }

        private Widget row_icon(Hub.Item item) {
            var image = new Image();
            image.pixel_size = ROW_ICON;
            var acc = store.account(item.account);
            GLib.Icon? gicon = null;
            if (item.icon.has_prefix("/")) {
                gicon = new FileIcon(File.new_for_path(item.icon));
            } else if (item.icon != "" && !HubStore.from_notifications(item.account)
                    && IconTheme.get_for_display(Gdk.Display.get_default()).has_icon(item.icon)) {
                gicon = new ThemedIcon(item.icon);
            }
            if (gicon == null) gicon = app_icon(item.app_id);
            if (gicon == null && acc != null) gicon = app_icon(acc.app_id);
            if (gicon == null) gicon = app_icon(item.kind.app_id());
            if (gicon != null) {
                image.gicon = gicon;
            } else if (HubStore.from_notifications(item.account)) {
                load_notification_icon(image, item.icon, item.sender);
                image.pixel_size = ROW_ICON;
            } else {
                image.icon_name = item.kind.icon_name(item.unread);
            }
            var holder = new Overlay();
            holder.child = image;
            var dot = new Box(Orientation.HORIZONTAL, 0);
            dot.add_css_class("hub-unread-dot");
            dot.halign = Align.END;
            dot.valign = Align.START;
            dot.set_size_request(10, 10);
            dot.visible = item.unread;
            holder.add_overlay(dot);
            return holder;
        }

        private Singularity.Widgets.PreferencesRow build_row(Hub.Item item) {
            var row = new Singularity.Widgets.PreferencesRow();
            row.add_css_class("hub-row");
            if (item.unread) row.add_css_class("unread");

            var content = new Box(Orientation.HORIZONTAL, 0);
            content.append(color_strip(item.account, "hub-account-strip"));

            var mark = new Button();
            mark.child = row_icon(item);
            mark.add_css_class("flat");
            mark.add_css_class("hub-kind");
            mark.valign = Align.START;
            mark.tooltip_text = item.unread ? _("Mark as Read") : _("Mark as Unread");
            mark.clicked.connect(() => store.set_unread(item, !item.unread));
            content.append(mark);

            var text = new Box(Orientation.VERTICAL, 2);
            text.hexpand = true;
            text.margin_top = 8;
            text.margin_bottom = 8;
            text.margin_end = 8;
            var top = new Box(Orientation.HORIZONTAL, 8);
            var sender = new Label(item.count > 1 ? "%s (%d)".printf(item.sender, item.count) : item.sender);
            sender.add_css_class("hub-sender");
            sender.xalign = 0;
            sender.hexpand = true;
            sender.ellipsize = Pango.EllipsizeMode.END;
            top.append(sender);
            if (item.flagged) {
                var flag = new Image.from_icon_name("emoji-flags-symbolic");
                flag.add_css_class("hub-flag");
                top.append(flag);
            }
            if (item.attachment) top.append(new Image.from_icon_name("mail-attachment-symbolic"));
            var time = new Label(new DateTime.from_unix_local(item.timestamp).format("%H:%M"));
            time.add_css_class("dim-label");
            time.add_css_class("numeric");
            top.append(time);
            text.append(top);
            if (item.subject != "") {
                var subject = new Label(item.subject);
                subject.add_css_class("hub-subject");
                subject.xalign = 0;
                subject.ellipsize = Pango.EllipsizeMode.END;
                text.append(subject);
            }
            if (item.preview != "") {
                var preview = new Label(item.preview.replace("\n", " "));
                preview.add_css_class("dim-label");
                preview.xalign = 0;
                preview.ellipsize = Pango.EllipsizeMode.END;
                text.append(preview);
            }
            content.append(text);
            if (HubConfig.get_default().is_priority(item)) content.append(color_strip(item.account, "hub-priority-strip"));
            row.child = content;

            var config = HubConfig.get_default();
            var start = swipe_action(item, config.swipe_start);
            if (start != null) row.add_swipe_action(Singularity.Widgets.SwipeEdge.LEADING, start);
            var end = swipe_action(item, config.swipe_end);
            if (end != null) row.add_swipe_action(Singularity.Widgets.SwipeEdge.TRAILING, end);

            var open = new GestureClick();
            open.released.connect((n, x, y) => {
                if (n != 1 || _sidebar_open) return;
                Widget? hit = row.pick(x, y, PickFlags.DEFAULT);
                for (Widget? w = hit; w != null && w != row; w = w.get_parent()) {
                    if (w is Button) return;
                }
                show_card(item);
            });
            row.add_controller(open);
            return row;
        }

        private Singularity.Widgets.SwipeAction? swipe_action(Hub.Item item, string kind) {
            switch (kind) {
                case "read":
                    var read = new Singularity.Widgets.SwipeAction(item.unread ? _("Read") : _("Unread"),
                        item.unread ? "mail-read-symbolic" : "mail-unread-symbolic", Singularity.Widgets.SwipeStyle.ACCENT);
                    read.activated.connect(() => store.set_unread(item, !item.unread));
                    return read;
                case "flag":
                    if (HubStore.from_notifications(item.account)) return null;
                    var flag = new Singularity.Widgets.SwipeAction(item.flagged ? _("Unflag") : _("Flag"),
                        "emoji-flags-symbolic", Singularity.Widgets.SwipeStyle.WARNING);
                    flag.activated.connect(() => store.set_flagged(item, !item.flagged));
                    return flag;
                case "delete":
                    var remove = new Singularity.Widgets.SwipeAction(_("Delete"), "user-trash-symbolic", Singularity.Widgets.SwipeStyle.DESTRUCTIVE);
                    remove.activated.connect(() => delete_item(item));
                    return remove;
                default:
                    return null;
            }
        }

        public void show_card(Hub.Item item) {
            if (_card != null) drop_card();
            store.mark_seen(item);
            var icon = row_icon(item);
            _card = new HubCard(item, icon, _docked);
            var card = _card;
            card.closed.connect(() => {
                if (_card == card) drop_card();
            });
            if (_docked) {
                _detail_empty.visible = false;
                card.frame.vexpand = true;
                _detail.append(card.frame);
                card.frame.opacity = 0.0;
                Singularity.Motion.spring_to(card.frame, "opacity", 1.0, Singularity.Motion.Spring.SNAPPY);
            } else {
                _sheet_layers.add_overlay(card.frame);
                card.present_from(double.max(1.0, _sheet_layers.get_width()));
            }
            card.frame.grab_focus();
        }

        public bool close_card() {
            if (_card == null) return false;
            _card.dismiss();
            return true;
        }

        private void drop_card() {
            if (_card == null) return;
            if (_docked) {
                _detail.remove(_card.frame);
                _detail_empty.visible = true;
            } else {
                _sheet_layers.remove_overlay(_card.frame);
            }
            _card = null;
        }

        private void delete_item(Hub.Item item) {
            store.remove(item);
            if (HubStore.from_notifications(item.account)) return;
            var toast = new Singularity.Widgets.Toast(_("Deleted"));
            toast.button_label = _("Undo");
            toast.button_clicked.connect(() => store.restore(item));
            _toasts.add_toast(toast);
        }

        private void show_more(Widget anchor) {
            var menu = new Singularity.Widgets.ContextMenu(anchor);
            menu.add_item(_("Mark All as Read"), "mail-read-symbolic", () => {
                foreach (var item in store.items(_account)) store.set_unread(item, false);
            });
            menu.add_item(_("Hub Settings"), "emblem-system-symbolic", () => {
                close_requested();
                var app = GLib.Application.get_default() as SingularityApp;
                if (app != null) app.open_settings_page("hub");
            });
            menu.popup();
        }

        private void rebuild_accounts() {
            for (Widget? c = _accounts.get_first_child(); c != null; ) {
                var next = c.get_next_sibling();
                _accounts.remove(c);
                c = next;
            }
            _accounts.append(account_row("mail-inbox-symbolic", _("Hub"), "", store.unread(), null));
            foreach (var a in store.accounts) {
                if (HubStore.from_notifications(a.id) && !HubConfig.get_default().show_notifications) continue;
                _accounts.append(account_row(a.icon_name, a.name, a.detail, store.unread(a.id), a.id));
            }
        }

        private Widget account_row(string icon, string name, string detail, int unread, string? id) {
            var row = new Singularity.Widgets.SidebarRow(icon, name);
            row.add_css_class("hub-account");
            row.set_active(id == _account);
            row.detail = detail;
            row.badge = unread > 0 ? unread.to_string() : "";
            row.clicked.connect(() => select_account(id));
            return row;
        }
    }
}
