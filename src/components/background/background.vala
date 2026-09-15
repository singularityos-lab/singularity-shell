using Gtk;
using GtkLayerShell;
// GLib.Markup.escape_text -- used by the attribution overlay to safely
// embed third-party OCS/Bing caption text in a Pango-markup Label.
using GLib;

namespace Singularity {

    public class Background : Gtk.Window {
        private Picture picture_a;
        private Picture picture_b;
        private Stack wp_stack;
        private bool _wp_showing_a = true;
        private uint _wp_clear_id = 0;
        // Live-toggle for the attribution overlay. Background.vala reads
        // show-wallpaper-attribution and routes through the existing
        // empty-title-and-empty-author early-return path when false, so
        // toggling it live (via the desktop settings page) hides or
        // re-shows the overlay without waiting for the next wallpaper
        // change. The schema id matches the rest of the shell
        // (desktop_page.vala initialises the same way).
        private GLib.Settings settings;

        // Attribution overlay. wp_stack is the wallpaper cross-fade;
        // the attribution Label sits on top of it in a Gtk.Overlay so
        // the wallpaper texture is the lower layer and the text is
        // painted over the corner of the screen. The label is hidden
        // when both WallpaperManager.attribution_title and
        // attribution_author are empty (the schema-default state and
        // the explicit-clear state at every background-picture-uri
        // write site).
        private Gtk.Overlay? wp_overlay;
        private Label attribution_label;
        // Loads the attribution-label CSS once per process. Static +
        // null-guarded the same way panel.vala's compact_rows_provider is,
        // since Background windows are created per-monitor and the rules
        // are process-global, not per-instance.
        private static Gtk.CssProvider? attribution_css_provider = null;
        // Corner-sample parameters. Sampled as a fractional rect inside
        // the cached medium pixbuf so the sample tracks whatever size
        // the manager uses for its display texture (currently 320x180,
        // but the manager owns that decision). Bottom-left, 40% width x
        // 30% height, with a small margin from the very edge so the
        // sample doesn't include the empty space around the label.
        private const double CORNER_SAMPLE_X_FRAC = 0.0;
        private const double CORNER_SAMPLE_Y_FRAC = 0.65;
        private const double CORNER_SAMPLE_W_FRAC = 0.40;
        private const double CORNER_SAMPLE_H_FRAC = 0.30;
        // Pixel margin from the screen edge to the attribution label.
        // Bottom-left is clear of the dock (which is bottom-anchored
        // and horizontally centered) at any reasonable screen width,
        // but a 24px gutter keeps the scrim from clipping into the
        // screen edge on rounded displays / ultrawide aspects.
        private const int ATTRIBUTION_MARGIN = 24;
        // topbar_lum_threshold -- copied from panel.vala (kept in sync
        // with that constant by convention rather than a shared header,
        // matching how the rest of the codebase pairs these CSS-class
        // and contrast decisions). Above this luminance the wallpaper
        // under the corner is "light", and the overlay switches to
        // dark text; below it stays light text. 0.72 matches the
        // value panel.vala uses for the top band.
        private const double ATTRIBUTION_LUM_THRESHOLD = 0.72;

        public signal void first_painted();
        private bool _first_painted_done = false;

        public Background(Gtk.Application app, Gdk.Monitor? monitor = null) {
            Object(application: app);
            init_for_window(this);
            if (monitor != null) {
                GtkLayerShell.set_monitor(this, monitor);
            }
            set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("background-window");
            ensure_attribution_css();

            picture_a = new Picture();
            picture_a.content_fit = ContentFit.COVER;
            picture_b = new Picture();
            picture_b.content_fit = ContentFit.COVER;

            wp_stack = new Stack();
            wp_stack.transition_type = StackTransitionType.CROSSFADE;
            wp_stack.transition_duration = 600;
            wp_stack.add_named(picture_a, "a");
            wp_stack.add_named(picture_b, "b");

            // Attribution overlay. The label is bottom-left-anchored
            // (halign=START, valign=END, ATTRIBUTION_MARGIN gutter)
            // and click-through so it never intercepts desktop mouse
            // events. can_target=false is GTK4's correct way to make a
            // widget hit-test-transparent; setting can_focus=false
            // prevents the label from grabbing Tab focus out of the
            // desktop. The scrim + padding + font live in the
            // `attribution-label` CSS class, loaded by
            // ensure_attribution_css() above (wallpaper-specific styling
            // lives here, not in libsingularity, per review on
            // libsingularity#13). The `light-bg` class on the Background
            // window (toggled below) is the same one panel.vala uses, so
            // the contrast rule is consistent across panel + overlay.
            attribution_label = new Label("");
            attribution_label.add_css_class("attribution-label");
            attribution_label.halign = Align.START;
            attribution_label.valign = Align.END;
            attribution_label.xalign = 0.0f;
            attribution_label.yalign = 1.0f;
            attribution_label.margin_start = ATTRIBUTION_MARGIN;
            attribution_label.margin_end = ATTRIBUTION_MARGIN;
            attribution_label.margin_bottom = ATTRIBUTION_MARGIN;
            attribution_label.margin_top = ATTRIBUTION_MARGIN;
            attribution_label.visible = false;
            attribution_label.can_focus = false;
            attribution_label.can_target = false;
            wp_overlay = new Gtk.Overlay();
            wp_overlay.set_child(wp_stack);
            wp_overlay.add_overlay(attribution_label);
            set_child(wp_overlay);

            var manager = WallpaperManager.get_default();
            // GSettings backing for the attribution toggle. Same schema id
            // string as desktop_page.vala (dev.sinty.desktop). The
            // changed[] handler re-runs update_attribution() so flipping
            // the toggle in Settings immediately hides or re-shows the
            // overlay for the wallpaper that's currently displayed.
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["show-wallpaper-attribution"].connect(() => {
                update_attribution(WallpaperManager.get_default());
            });
            // First load: set both pictures to avoid flash, no animation needed
            if (manager.display_texture != null) {
                picture_a.set_paintable(manager.display_texture);
                picture_b.set_paintable(manager.display_texture);
                schedule_hidden_wallpaper_clear();
            }
            manager.wallpaper_changed.connect(() => {
                update_wallpaper(manager);
                update_attribution(manager);
            });
            // Initial bind for the case where WallpaperManager already
            // has a display_texture and attribution on startup (warm
            // restart): wallpaper_changed would not re-fire, so we
            // call update_attribution() once explicitly.
            update_attribution(manager);
            map.connect_after(() => {
                if (_first_painted_done) return;
                var clock = get_frame_clock();
                if (clock == null) {
                    GLib.Timeout.add(50, () => { emit_first_painted(); return GLib.Source.REMOVE; });
                    return;
                }
                ulong handler = 0;
                handler = clock.after_paint.connect(() => {
                    clock.disconnect(handler);
                    emit_first_painted();
                });
                queue_draw();
            });

            present();
            var click_controller = new GestureClick();
            click_controller.button = 3;
            click_controller.pressed.connect((n_press, x, y) => {
                show_context_menu(x, y);
            });
            ((Gtk.Widget)this).add_controller(click_controller);

            // Left-click on desktop, switch global menu to OS menu
            var left_click = new GestureClick();
            left_click.button = 1;
            left_click.pressed.connect((n_press, x, y) => {
                AppSystem.get_default().notify_desktop_focused();
            });
            ((Gtk.Widget)this).add_controller(left_click);
        }

        private void emit_first_painted() {
            if (_first_painted_done) return;
            _first_painted_done = true;
            first_painted();
        }

        public void play_intro() {
            wp_stack.add_css_class("wallpaper-intro");
            GLib.Timeout.add(950, () => {
                wp_stack.remove_css_class("wallpaper-intro");
                return GLib.Source.REMOVE;
            });
        }

        // Wallpaper attribution overlay (Background.vala).
        //
        // Sits in the bottom-left corner of the live desktop background
        // as a single Gtk.Label over the wallpaper cross-fade. The scrim
        // is a semi-transparent rounded rectangle so the text reads
        // against both bright and dark wallpapers without an aggressive
        // box, and the light-bg / non-light-bg pair matches the
        // convention panel.vala already uses for the top band -- same
        // colour tokens, same threshold (ATTRIBUTION_LUM_THRESHOLD = 0.72,
        // defined above).
        //
        // The luminance class selects an opposing scrim/text pair
        // independently of the active application theme, since wallpaper
        // contrast cannot be inferred from the theme's text colour.
        //
        // Moved here from libsingularity's style.css (review on
        // libsingularity#13: that stylesheet should stay limited to
        // reusable widget styling, and this rule only exists for the
        // wallpaper attribution overlay singularity-shell owns) -- rules
        // and rationale unchanged, just relocated to the actual consumer.
        private const string ATTRIBUTION_CSS = """
.background-window .attribution-label {
    border-radius: 8px;
    padding: 6px 12px;
    font-size: 13px;
    font-weight: 400;
}
.background-window.light-bg .attribution-label {
    /* Bright wallpaper: dark scrim with light foreground. */
    background-color: alpha(black, 0.65);
    color: white;
    text-shadow: 0 1px 2px alpha(black, 0.45);
}
.background-window:not(.light-bg) .attribution-label {
    /* Dark wallpaper: light scrim with dark foreground. */
    background-color: alpha(white, 0.72);
    color: black;
    text-shadow: 0 1px 2px alpha(white, 0.35);
}
""";

        // Registers ATTRIBUTION_CSS once per process, the same way
        // panel.vala's compact_rows_provider is registered: a static
        // nullable CssProvider, guarded by a null-check, loaded on first
        // Background construction.
        private static void ensure_attribution_css() {
            if (attribution_css_provider != null) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            attribution_css_provider = new Gtk.CssProvider();
            attribution_css_provider.load_from_string(ATTRIBUTION_CSS);
            Gtk.StyleContext.add_provider_for_display(
                display,
                attribution_css_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        }

        // Bind the attribution overlay to the WallpaperManager. Called
        // on every wallpaper_changed signal -- which now fires on URI
        // changes AND on attribution-only changes (see WallpaperManager
        // reload()), so a single signal covers both cases.
        //
        // Text format: title (bold) and author (dim-label) concatenated
        // with a middle-dot separator. Markup-escape both because the
        // data comes from third-party OCS / Bing caption strings that
        // the parsers accept leniently -- an unescaped & < > in the
        // text would otherwise be a Pango parse error and crash the
        // label render.
        //
        // Contrast: sample the bottom-left corner rectangle from
        // WallpaperManager.corner_luminance_frac() and compare against
        // ATTRIBUTION_LUM_THRESHOLD. Above threshold = light
        // background under the text = use dark text via .light-bg
        // class on the Background window; below = dark background =
        // use light text. Same `light-bg` CSS class the panel uses,
        // extended in the stylesheet for .background-window.light-bg.
        private void update_attribution(WallpaperManager manager) {
            string title = manager.attribution_title ?? "";
            string author = manager.attribution_author ?? "";
            // The user-toggleable show-wallpaper-attribution gsettings key
            // shares the same early-return path as the no-title-and-no-author
            // case below: when the overlay is hidden for any reason we
            // clear the contrast class too, so re-enabling the toggle (or
            // loading a wallpaper that carries attribution) re-samples
            // cleanly on the next wallpaper_changed.
            if (!settings.get_boolean("show-wallpaper-attribution")) {
                title = "";
                author = "";
            }
            if (title == "" && author == "") {
                attribution_label.visible = false;
                attribution_label.label = "";
                // Remove the contrast class too: a hidden overlay
                // shouldn't keep the .light-bg class set on the
                // window, because if a future wallpaper is loaded
                // without attribution we still want the window to
                // re-sample cleanly on the next wallpaper_changed.
                remove_css_class("light-bg");
                return;
            }
            string safe_title = Markup.escape_text(title, -1);
            string safe_author = Markup.escape_text(author, -1);
            string markup;
            if (title != "" && author != "") {
                markup = "<b>%s</b>  ·  %s".printf(safe_title, safe_author);
            } else if (title != "") {
                markup = "<b>%s</b>".printf(safe_title);
            } else {
                markup = safe_author;
            }
            // CSS class is not a supported Pango span attribute.
            attribution_label.set_markup(markup);
            attribution_label.visible = true;

            // Sample the corner. The pixbuf aspect matches the screen
            // aspect so a fractional bottom-left corner maps 1:1 to a
            // fractional bottom-left corner of the screen at the same
            // proportional position.
            double lum = manager.corner_luminance_frac(
                CORNER_SAMPLE_X_FRAC,
                CORNER_SAMPLE_Y_FRAC,
                CORNER_SAMPLE_W_FRAC,
                CORNER_SAMPLE_H_FRAC);
            if (lum >= 0.0) {
                bool light_bg = lum > ATTRIBUTION_LUM_THRESHOLD;
                if (light_bg) add_css_class("light-bg");
                else remove_css_class("light-bg");
            }
        }

        private void update_wallpaper(WallpaperManager manager) {
            if (manager.display_texture == null) return;
            // Write to the off-screen picture, then crossfade to it
            if (_wp_showing_a) {
                picture_b.set_paintable(manager.display_texture);
                wp_stack.visible_child_name = "b";
            } else {
                picture_a.set_paintable(manager.display_texture);
                wp_stack.visible_child_name = "a";
            }
            _wp_showing_a = !_wp_showing_a;
            schedule_hidden_wallpaper_clear();
        }

        private void schedule_hidden_wallpaper_clear() {
            if (_wp_clear_id != 0) {
                GLib.Source.remove(_wp_clear_id);
                _wp_clear_id = 0;
            }
            bool showing_a = _wp_showing_a;
            _wp_clear_id = GLib.Timeout.add(650, () => {
                _wp_clear_id = 0;
                if (showing_a == _wp_showing_a) {
                    if (_wp_showing_a) picture_b.set_paintable(null);
                    else picture_a.set_paintable(null);
                }
                return GLib.Source.REMOVE;
            });
        }

        private void show_context_menu(double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(this);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item("Set Background", "preferences-desktop-wallpaper-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("background");
            });
            menu.add_item("Settings", "emblem-system-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("home");
            });
            menu.popup();
        }
    }
}
