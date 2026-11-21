using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class QuickUnlockPage : SettingsPage {
        private PasswordRow pin_row;
        private PreferencesGroup choice_group;
        private PreferencesGroup setup_group;
        private Box pattern_box;
        private PatternPad pad;
        private Label pattern_hint;
        private Label status;
        private string? first_pattern = null;
        private bool busy;

        public QuickUnlockPage(SettingsView view, string back) {
            base(_("Quick Unlock"));
            back_clicked.connect(() => view.navigate_to(back));

            var pin_group = new PreferencesGroup(_("Confirm With Your PIN"),
                _("A quick PIN or a pattern opens the lock screen once you have signed in with your PIN. After a restart, after five wrong tries or after Lockdown, the full PIN is needed again."));
            pin_row = new PasswordRow(_("PIN"));
            pin_group.add_row(pin_row);
            add_group(pin_group);

            choice_group = new PreferencesGroup(_("Unlock With"));
            add_group(choice_group);

            setup_group = new PreferencesGroup(_("Quick PIN"));
            setup_group.visible = false;
            add_group(setup_group);

            pattern_box = new Box(Orientation.VERTICAL, 12);
            pattern_box.margin_top = 12;
            pattern_box.visible = false;
            pattern_hint = new Label("");
            pattern_hint.add_css_class("dim-label");
            pattern_hint.wrap = true;
            pad = new PatternPad();
            pad.node_added.connect(() => Singularity.Haptics.get_default().key());
            pad.too_short.connect(() => pattern_hint.label = _("Connect at least four dots."));
            pad.drawn.connect(on_pattern);
            pattern_box.append(pattern_hint);
            pattern_box.append(pad);
            add_widget(pattern_box);

            status = status_label();
            add_widget(status);
            refresh();
        }

        private void say(string text) {
            status.label = text;
            status.visible = text != "";
        }

        private void refresh() {
            choice_group.clear();
            var current = QuickUnlock.kind();
            choice_group.add_row(choice(QuickUnlockKind.PIN, _("Four to twelve digits"), "input-dialpad-symbolic", current));
            choice_group.add_row(choice(QuickUnlockKind.PATTERN, _("Connect at least four dots"), "view-app-grid-symbolic", current));
            if (current != QuickUnlockKind.NONE) {
                var off = new ActionRow(_("Turn Off"), _("Unlock with the full PIN only"), "channel-secure-symbolic");
                var button = row_button(_("Turn Off"), false);
                button.add_css_class("destructive-action");
                button.clicked.connect(() => turn_off.begin());
                off.add_suffix(button);
                choice_group.add_row(off);
            }
        }

        private ActionRow choice(QuickUnlockKind kind, string subtitle, string icon, QuickUnlockKind current) {
            bool active = kind == current;
            var row = new ActionRow(kind.to_label(), active ? _("In use") : subtitle, icon);
            var button = row_button(active ? _("Change…") : _("Set Up…"), !active);
            button.clicked.connect(() => start(kind));
            row.add_suffix(button);
            return row;
        }

        private bool pin_ready() {
            if (pin_row.text != "") return true;
            say(_("Enter the PIN first."));
            return false;
        }

        private void start(QuickUnlockKind kind) {
            if (!pin_ready()) return;
            say("");
            first_pattern = null;
            pad.reset();
            setup_group.clear();
            setup_group.visible = kind == QuickUnlockKind.PIN;
            pattern_box.visible = kind == QuickUnlockKind.PATTERN;
            if (kind == QuickUnlockKind.PATTERN) {
                pattern_hint.label = _("Draw a pattern.");
                return;
            }
            var neu = new PasswordRow(_("New Quick PIN"));
            var con = new PasswordRow(_("Confirm Quick PIN"));
            neu.input_purpose = InputPurpose.PIN;
            con.input_purpose = InputPurpose.PIN;
            var save = row_button(_("Save"), true);
            con.add_suffix(save);
            setup_group.add_row(neu);
            setup_group.add_row(con);
            save.clicked.connect(() => save_pin.begin(neu, con));
            con.entry_activated.connect(() => save_pin.begin(neu, con));
        }

        private async void save_pin(PasswordRow neu, PasswordRow con) {
            if (busy || !pin_ready()) return;
            if (neu.text != con.text) {
                say(_("The quick PINs do not match."));
                return;
            }
            yield store(QuickUnlockKind.PIN, neu.text);
        }

        private void on_pattern(string sequence) {
            if (first_pattern == null) {
                first_pattern = sequence;
                pad.reset();
                pattern_hint.label = _("Draw it again to confirm.");
                return;
            }
            if (sequence != first_pattern) {
                first_pattern = null;
                pad.show_error();
                pattern_hint.label = _("The patterns do not match. Draw a pattern.");
                return;
            }
            store.begin(QuickUnlockKind.PATTERN, sequence);
        }

        private async void store(QuickUnlockKind kind, string secret) {
            if (busy || !pin_ready()) return;
            busy = true;
            say(_("Checking the PIN…"));
            var result = yield QuickUnlock.set(pin_row.text, kind, secret);
            busy = false;
            first_pattern = null;
            switch (result) {
                case QuickUnlockResult.OK:
                    say(kind == QuickUnlockKind.PATTERN ? _("The lock screen now opens with your pattern.")
                                                        : _("The lock screen now opens with your quick PIN."));
                    setup_group.visible = false;
                    pattern_box.visible = false;
                    pin_row.text = "";
                    refresh();
                    break;
                case QuickUnlockResult.INVALID:
                    say(kind == QuickUnlockKind.PATTERN ? _("Use at least four dots.")
                                                        : _("Use four to twelve digits."));
                    pad.reset();
                    if (kind == QuickUnlockKind.PATTERN) pattern_hint.label = _("Draw a pattern.");
                    break;
                case QuickUnlockResult.UNAVAILABLE:
                    say(_("Quick unlock is not available right now."));
                    break;
                default:
                    say(_("The PIN is not correct."));
                    pad.reset();
                    if (kind == QuickUnlockKind.PATTERN) pattern_hint.label = _("Draw a pattern.");
                    break;
            }
        }

        private async void turn_off() {
            if (busy || !pin_ready()) return;
            busy = true;
            say(_("Checking the PIN…"));
            var result = yield QuickUnlock.clear(pin_row.text);
            busy = false;
            if (result == QuickUnlockResult.OK) {
                say(_("The lock screen opens with the full PIN only."));
                setup_group.visible = false;
                pattern_box.visible = false;
                pin_row.text = "";
                refresh();
            } else {
                say(result == QuickUnlockResult.UNAVAILABLE ? _("Quick unlock is not available right now.")
                                                            : _("The PIN is not correct."));
            }
        }
    }
}
