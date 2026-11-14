using Gtk;

namespace Singularity {

    // A simple emoji picker: a searchable grid of emoji. Activating one (click
    // or Enter) copies it to the clipboard (paste with Ctrl+V) and closes the
    // picker. Spawned with Super+. Direct insertion into the focused app would
    // need a compositor virtual-keyboard binding, so v1 uses the clipboard.
    public class EmojiPicker : Singularity.Shell.ShellDialog {
        private SearchEntry search;
        private FlowBox grid;
        private Label hint;

        // "emoji keywords ..." one per entry. Search matches any keyword.
        private const string[] EMOJI = {
            "😀 grinning smile happy face",
            "😃 smiley happy joy face",
            "😄 grin happy laugh",
            "😁 beaming grin smile",
            "😆 laugh haha satisfied",
            "😅 sweat laugh nervous",
            "🤣 rofl rolling laugh",
            "😂 joy tears laugh cry",
            "🙂 slight smile",
            "😉 wink",
            "😊 blush smile happy",
            "😇 innocent angel halo",
            "🥰 love hearts adore",
            "😍 heart eyes love",
            "🤩 star struck wow",
            "😘 kiss blow",
            "😗 kissing",
            "😋 yum tasty tongue",
            "😛 tongue playful",
            "😜 wink tongue crazy",
            "🤪 zany goofy crazy",
            "🤤 drool",
            "😎 cool sunglasses",
            "🤓 nerd glasses",
            "🧐 monocle thinking",
            "🤔 thinking hmm",
            "🤨 raised eyebrow doubt",
            "😐 neutral meh",
            "😑 expressionless",
            "😶 no mouth silent",
            "🙄 eye roll",
            "😏 smirk",
            "😣 persevere struggle",
            "😥 sad disappointed relieved",
            "😮 wow surprised open mouth",
            "😯 hushed surprised",
            "😪 sleepy tired",
            "😫 tired exhausted",
            "🥱 yawn bored",
            "😴 sleep zzz",
            "😌 relieved calm",
            "🤐 zipper mouth quiet",
            "🤢 nausea sick",
            "🤮 vomit sick",
            "🤧 sneeze sick",
            "🥵 hot heat sweat",
            "🥶 cold freezing",
            "😵 dizzy ko",
            "🤯 mind blown explode",
            "🤠 cowboy",
            "🥳 party celebrate hat",
            "😈 devil evil grin",
            "👿 imp angry devil",
            "💀 skull death",
            "💩 poop",
            "🤡 clown",
            "👻 ghost boo",
            "👽 alien ufo",
            "🤖 robot bot",
            "😺 cat happy",
            "😻 cat love heart",
            "🙈 see no evil monkey",
            "🙉 hear no evil monkey",
            "🙊 speak no evil monkey",
            "❤️ red heart love",
            "🧡 orange heart",
            "💛 yellow heart",
            "💚 green heart",
            "💙 blue heart",
            "💜 purple heart",
            "🖤 black heart",
            "🤍 white heart",
            "💔 broken heart",
            "💕 two hearts love",
            "💖 sparkling heart",
            "💯 hundred perfect score",
            "💢 anger angry",
            "💥 boom explosion collision",
            "💫 dizzy star",
            "💦 sweat droplets water",
            "💨 dash wind fast",
            "🔥 fire lit hot flame",
            "⭐ star",
            "🌟 glowing star sparkle",
            "✨ sparkles shine",
            "⚡ lightning bolt zap",
            "☀️ sun sunny",
            "🌈 rainbow",
            "☁️ cloud",
            "❄️ snowflake snow cold",
            "🎉 party tada celebrate",
            "🎊 confetti party",
            "🎈 balloon",
            "🎁 gift present",
            "🏆 trophy win award",
            "🥇 gold medal first",
            "👍 thumbs up like yes ok",
            "👎 thumbs down dislike no",
            "👌 ok perfect",
            "✌️ victory peace",
            "🤞 fingers crossed luck",
            "🤟 love you gesture",
            "🤘 rock horns",
            "👏 clap applause",
            "🙌 raised hands praise",
            "🙏 pray thanks please",
            "🤝 handshake deal",
            "💪 muscle strong flex",
            "👀 eyes look",
            "🧠 brain smart",
            "👋 wave hello hi bye",
            "✋ raised hand stop",
            "🖐️ hand fingers",
            "👈 point left",
            "👉 point right",
            "👆 point up",
            "👇 point down",
            "☝️ point up index",
            "✅ check mark done yes correct",
            "❌ cross no wrong cancel",
            "❓ question mark",
            "❗ exclamation",
            "⚠️ warning caution",
            "🚀 rocket launch ship fast",
            "💡 idea light bulb",
            "🔧 wrench tool fix",
            "🐛 bug insect",
            "💻 laptop computer code",
            "🖥️ desktop computer",
            "📱 phone mobile",
            "⌨️ keyboard",
            "🎮 game controller",
            "📷 camera photo",
            "🎵 music note",
            "🎧 headphones",
            "📚 books study",
            "✏️ pencil write edit",
            "📝 memo note write",
            "📌 pin",
            "📎 paperclip attach",
            "🔍 search magnify",
            "🔒 lock secure",
            "🔓 unlock open",
            "🔑 key",
            "🗑️ trash delete bin",
            "♻️ recycle",
            "🕐 clock time",
            "📅 calendar date",
            "☕ coffee tea drink",
            "🍕 pizza food",
            "🍔 burger food",
            "🍺 beer drink",
            "🍷 wine drink",
            "🎂 cake birthday",
            "🐶 dog puppy",
            "🐱 cat kitten",
            "🦊 fox",
            "🐼 panda",
            "🦄 unicorn",
            "🌍 earth world globe",
            "🌙 moon night",
            "💸 money cash fly",
            "💰 money bag"
        };

        public EmojiPicker(Gtk.Application app) {
            Object(
                application: app,
                anchor_top: true,
                anchor_bottom: true,
                anchor_left: true,
                anchor_right: true
            );
            add_css_class("emoji-picker");

            // The focused SearchEntry swallows Escape (stop-search) before it can
            // bubble up to ShellDialog's close handler, so close on Escape here in
            // the capture phase (#148).
            var esc = new EventControllerKey();
            esc.set_propagation_phase(PropagationPhase.CAPTURE);
            esc.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    close_dialog();
                    return true;
                }
                return false;
            });
            ((Widget)this).add_controller(esc);

            search = new SearchEntry();
            search.placeholder_text = _("Search emoji…");
            search.width_request = 420;
            search.add_css_class("emoji-search");
            search.search_changed.connect(() => {
                grid.invalidate_filter();
                select_first_visible();
            });
            // Enter picks the selected (or first visible) emoji.
            search.activate.connect(() => {
                var child = current_child();
                if (child != null) pick_child(child);
            });
            search.margin_top = 12;
            search.margin_start = 12;
            search.margin_end = 12;
            search.margin_bottom = 8;
            content_box.append(search);

            grid = new FlowBox();
            grid.selection_mode = SelectionMode.SINGLE;
            grid.activate_on_single_click = true;
            grid.homogeneous = true;
            grid.max_children_per_line = 9;
            grid.min_children_per_line = 6;
            grid.valign = Align.START;
            grid.vexpand = false;
            grid.row_spacing = 2;
            grid.column_spacing = 2;
            grid.add_css_class("emoji-grid");
            grid.set_filter_func(filter_child);
            grid.child_activated.connect((child) => pick_child(child));

            foreach (string entry in EMOJI) {
                int sp = entry.index_of_char(' ');
                if (sp <= 0) continue;
                string ch = entry.substring(0, sp);
                string kw = entry.substring(sp + 1);
                var lbl = new Label(ch);
                lbl.add_css_class("emoji-button");
                lbl.halign = Align.CENTER;
                lbl.valign = Align.CENTER;
                lbl.set_size_request(40, 40);
                var child = new FlowBoxChild();
                child.valign = Align.START;
                child.set_child(lbl);
                child.set_data<string>("emoji", ch);
                child.set_data<string>("kw", kw);
                grid.append(child);
            }

            var scroller = new ScrolledWindow();
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.min_content_height = 320;
            scroller.max_content_height = 420;
            scroller.set_child(grid);
            scroller.add_css_class("emoji-scroller");
            scroller.margin_start = 8;
            scroller.margin_end = 8;
            content_box.append(scroller);

            hint = new Label(_("Enter or click to copy, then paste with Ctrl+V. Esc to close."));
            hint.add_css_class("dim-label");
            hint.add_css_class("emoji-hint");
            hint.halign = Align.CENTER;
            hint.margin_top = 8;
            hint.margin_bottom = 12;
            content_box.append(hint);
        }

        private bool filter_child(FlowBoxChild child) {
            string q = search.text.strip().down();
            if (q == "") return true;
            string? kw = child.get_data<string>("kw");
            return kw != null && kw.down().contains(q);
        }

        // First child that currently passes the filter, in order.
        private FlowBoxChild? first_visible() {
            Widget? c = grid.get_first_child();
            while (c != null) {
                var fbc = c as FlowBoxChild;
                if (fbc != null && filter_child(fbc)) return fbc;
                c = c.get_next_sibling();
            }
            return null;
        }

        // The selected child if any, otherwise the first visible one.
        private FlowBoxChild? current_child() {
            var sel = grid.get_selected_children();
            if (sel != null && sel.length() > 0) {
                var fbc = sel.data;
                if (fbc != null && filter_child(fbc)) return fbc;
            }
            return first_visible();
        }

        private void select_first_visible() {
            var fbc = first_visible();
            if (fbc != null) grid.select_child(fbc);
            else grid.unselect_all();
        }

        private void pick_child(FlowBoxChild child) {
            string? emoji = child.get_data<string>("emoji");
            if (emoji == null) return;
            // Also copy to the clipboard as a fallback (Ctrl+V).
            var display = Gdk.Display.get_default();
            if (display != null) display.get_clipboard().set_text(emoji);
            close_dialog();
            // Type it into whatever regains focus once the picker closes, via
            // the Wayland virtual keyboard, so it lands directly in the app.
            string e = emoji;
            GLib.Timeout.add(120, () => {
                Singularity.type_text(e);
                return GLib.Source.REMOVE;
            });
        }

        public void toggle() {
            if (visible) {
                close_dialog();
            } else {
                search.text = "";
                grid.invalidate_filter();
                open_dialog();
                select_first_visible();
                search.grab_focus();
            }
        }
    }
}
