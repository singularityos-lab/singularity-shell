using GLib;
using Gtk;
using Gee;
using GtkLayerShell;

namespace Singularity {

    public class ScreenshotTool : Singularity.Shell.ShellDialog {
        private static ScreenshotTool? _instance = null;

        public void* focused_handle { get; set; default = null; }

        private Button _seg_screen;
        private Button _seg_window;
        private Button _seg_region;
        private string _active_mode = "screen";
        private Gtk.Entry _delay_entry;
        private Gtk.Switch _cursor_switch;
        private Gtk.Switch _audio_switch;
        private ScreenRecordingRequest? _last_recording = null;
        private GLib.Subprocess? _region_picker = null;
        private ulong screenshot_handler_id = 0;
        private bool _pending_region = false;
        private bool _pending_window = false;
        private Gdk.Monitor? _target_monitor = null;
        private string? _target_connector = null;
        private Gee.HashMap<uint, string> _screenshot_notification_actions = new Gee.HashMap<uint, string>();

        public static ScreenshotTool get_default(Gtk.Application? app = null) {
            if (_instance == null) {
                _instance = new ScreenshotTool(app);
            }
            return _instance;
        }

        private ScreenshotTool(Gtk.Application? app) {
            Object(
                application: app as Gtk.Application,
                anchor_bottom: true,
                margin_bottom_value: 80
            );
        }

        construct {
            setup_styles();
            add_css_class("screenshot-tool");

            ScreenshotPortal.get_default().screenshot_failed.connect((err) => {
                if (err.down().contains("cancel")) return;
                _show_unavailable_dialog();
            });

            // Same surface as every other shell dialog: the ShellDialog window
            // is transparent, the visible card is a `.dialog-card` child, and a
            // gutter around it (SHADOW_MARGIN = 20px) leaves room for its shadow.
            var gutter = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            gutter.margin_top = 20;
            gutter.margin_bottom = 20;
            gutter.margin_start = 20;
            gutter.margin_end = 20;
            content_box.append(gutter);

            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.add_css_class("dialog-card");
            gutter.append(card);

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 14;
            box.margin_end = 14;
            card.append(box);

            // Single row, left to right: mode selector, delay stepper,
            // video/photo capture, cursor switch.
            var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
            row.halign = Gtk.Align.CENTER;
            box.append(row);

            // 1. Mode selector (three icons: screen, window, region).
            var seg_inner = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            seg_inner.add_css_class("segmented-inner");
            var seg_wrap = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            seg_wrap.add_css_class("segmented-control");
            seg_wrap.valign = Gtk.Align.CENTER;
            seg_wrap.append(seg_inner);

            _seg_screen = make_mode_button("video-display-symbolic", "Screen", "screen");
            _seg_screen.add_css_class("active");
            seg_inner.append(_seg_screen);

            _seg_window = make_mode_button("focus-windows-symbolic", "Window", "window");
            seg_inner.append(_seg_window);

            _seg_region = make_mode_button("selection-mode-symbolic", "Region", "region");
            seg_inner.append(_seg_region);

            row.append(seg_wrap);

            // 2. Delay field - leading timer icon, then a -/value/+ stepper.
            var delay_field = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
            delay_field.add_css_class("screenshot-delay-field");
            delay_field.valign = Gtk.Align.CENTER;

            var timer_icon = new Gtk.Image.from_icon_name("alarm-symbolic");
            timer_icon.add_css_class("dim-label");
            timer_icon.margin_end = 4;
            delay_field.append(timer_icon);

            var minus_btn = new Gtk.Button.from_icon_name("list-remove-symbolic");
            minus_btn.add_css_class("flat");
            minus_btn.add_css_class("delay-step");
            minus_btn.tooltip_text = _("Decrease delay");
            minus_btn.clicked.connect(() => adjust_delay(-1));
            delay_field.append(minus_btn);

            _delay_entry = new Gtk.Entry();
            _delay_entry.text = "0";
            _delay_entry.width_chars = 2;
            _delay_entry.max_width_chars = 3;
            _delay_entry.xalign = 0.5f;
            _delay_entry.input_purpose = Gtk.InputPurpose.DIGITS;
            _delay_entry.add_css_class("flat");
            _delay_entry.valign = Gtk.Align.CENTER;
            delay_field.append(_delay_entry);

            var plus_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
            plus_btn.add_css_class("flat");
            plus_btn.add_css_class("delay-step");
            plus_btn.tooltip_text = _("Increase delay");
            plus_btn.clicked.connect(() => adjust_delay(1));
            delay_field.append(plus_btn);

            row.append(delay_field);

            // 3. Video (record) / photo (capture) as a segmented control.
            var act_inner = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            act_inner.add_css_class("segmented-inner");
            var act_wrap = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            act_wrap.add_css_class("segmented-control");
            act_wrap.valign = Gtk.Align.CENTER;
            act_wrap.append(act_inner);

            var video_btn = new Gtk.Button();
            video_btn.icon_name = "camera-video-symbolic";
            video_btn.tooltip_text = _("Record Video");
            video_btn.add_css_class("segmented-button");
            video_btn.has_frame = false;
            video_btn.clicked.connect(on_video_clicked);
            act_inner.append(video_btn);

            var photo_btn = new Gtk.Button();
            photo_btn.icon_name = "camera-photo-symbolic";
            photo_btn.tooltip_text = _("Take Screenshot");
            photo_btn.add_css_class("segmented-button");
            photo_btn.has_frame = false;
            photo_btn.clicked.connect(on_take_clicked);
            act_inner.append(photo_btn);

            row.append(act_wrap);

            // 4. Mouse icon with an include-cursor switch to its right.
            var cursor_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            cursor_box.valign = Gtk.Align.CENTER;
            var mouse_icon = new Gtk.Image.from_icon_name("input-mouse-symbolic");
            cursor_box.append(mouse_icon);
            _cursor_switch = new Gtk.Switch();
            _cursor_switch.active = true;
            _cursor_switch.valign = Gtk.Align.CENTER;
            _cursor_switch.tooltip_text = _("Include cursor");
            cursor_box.append(_cursor_switch);
            row.append(cursor_box);

            var audio_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            audio_box.valign = Gtk.Align.CENTER;
            var audio_icon = new Gtk.Image.from_icon_name("audio-volume-high-symbolic");
            audio_box.append(audio_icon);
            _audio_switch = new Gtk.Switch();
            _audio_switch.active = false;
            _audio_switch.valign = Gtk.Align.CENTER;
            _audio_switch.tooltip_text = _("Record system audio");
            audio_box.append(_audio_switch);
            row.append(audio_box);

            var mgr = SystemMonitor.get_default().notifications;
            mgr.action_invoked.connect((id, action) => {
                _handle_notification_action(id, action);
            });

            var recorder = ScreenRecorder.get_default();
            recorder.finished.connect(_notify_recording_saved);
            recorder.failed.connect(_notify_recording_failed);
        }

        public override void open_dialog() {
            var recorder = ScreenRecorder.get_default();
            if (recorder.busy) {
                recorder.stop();
                return;
            }
            base.open_dialog();
        }

        private Gtk.Button make_mode_button(string icon, string tooltip, string mode) {
            var btn = new Gtk.Button();
            btn.icon_name = icon;
            btn.tooltip_text = tooltip;
            btn.add_css_class("segmented-button");
            btn.has_frame = false;
            btn.clicked.connect(() => set_mode(mode));
            return btn;
        }

        // Current delay in seconds, parsed from the entry and clamped to >= 0.
        private int current_delay() {
            int v = int.parse(_delay_entry.text);
            return v < 0 ? 0 : v;
        }

        // Step the delay entry by `step` seconds, never below zero.
        private void adjust_delay(int step) {
            int v = current_delay() + step;
            if (v < 0) v = 0;
            _delay_entry.text = v.to_string();
        }

        private void set_mode(string mode) {
            _active_mode = mode;
            if (mode == "screen") {
                _seg_screen.add_css_class("active");
                _seg_window.remove_css_class("active");
                _seg_region.remove_css_class("active");
            } else if (mode == "window") {
                _seg_screen.remove_css_class("active");
                _seg_window.add_css_class("active");
                _seg_region.remove_css_class("active");
            } else {
                _seg_screen.remove_css_class("active");
                _seg_window.remove_css_class("active");
                _seg_region.add_css_class("active");
            }
        }

        public void prepare_for_invocation(void* focused_handle) {
            this.focused_handle = focused_handle;
            _target_monitor = null;
            _target_connector = null;

            if (focused_handle != null) {
                _target_monitor = resolve_monitor_for_window(focused_handle);
            }
            if (_target_monitor == null) {
                _target_monitor = Singularity.Panel.find_primary_monitor();
            }
            if (_target_monitor == null) {
                _target_monitor = first_monitor();
            }
            if (_target_monitor != null) {
                _target_connector = _target_monitor.get_connector();
                GtkLayerShell.set_monitor(this, _target_monitor);
            }
        }

        private Gdk.Monitor? resolve_monitor_for_window(void* handle) {
            int x, y, w, h, maximized, fullscreen;
            string? connector;
            bool got_geometry = Singularity.wayland_get_window_geometry(handle,
                out x, out y, out w, out h, out maximized, out fullscreen, out connector);

            if (got_geometry && w > 0 && h > 0) {
                var monitor = monitor_for_connector(connector);
                if (monitor != null) return monitor;

                monitor = monitor_for_geometry(x, y, w, h);
                if (monitor != null) return monitor;
            }

            return Singularity.wayland_get_window_monitor(handle);
        }

        private Gdk.Monitor? monitor_for_connector(string? connector) {
            if (connector == null || connector == "") return null;

            var display = Gdk.Display.get_default();
            if (display == null) return null;

            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;
                if (monitor.get_connector() == connector) return monitor;
            }
            return null;
        }

        private Gdk.Monitor? monitor_for_geometry(int x, int y, int w, int h) {
            var display = Gdk.Display.get_default();
            if (display == null) return null;

            var monitors = display.get_monitors();
            int center_x = x + (w / 2);
            int center_y = y + (h / 2);
            Gdk.Monitor? best_monitor = null;
            int best_area = 0;

            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;

                var geo = monitor.get_geometry();
                if (center_x >= geo.x && center_x < geo.x + geo.width &&
                    center_y >= geo.y && center_y < geo.y + geo.height) {
                    return monitor;
                }

                int ix1 = x > geo.x ? x : geo.x;
                int iy1 = y > geo.y ? y : geo.y;
                int ix2 = (x + w) < (geo.x + geo.width) ? (x + w) : (geo.x + geo.width);
                int iy2 = (y + h) < (geo.y + geo.height) ? (y + h) : (geo.y + geo.height);
                int iw = ix2 - ix1;
                int ih = iy2 - iy1;
                int area = (iw > 0 && ih > 0) ? iw * ih : 0;

                if (area > best_area) {
                    best_area = area;
                    best_monitor = monitor;
                }
            }

            return best_monitor;
        }

        private void on_take_clicked() {
            int delay_secs = current_delay();

            _pending_region = (_active_mode == "region");
            _pending_window = (_active_mode == "window");

            hide();

            if (delay_secs > 0) {
                GLib.Timeout.add_seconds(delay_secs, () => {
                    dispatch_capture();
                    return GLib.Source.REMOVE;
                });
            } else {
                dispatch_capture();
            }
        }

        private void on_video_clicked() {
            int delay_secs = current_delay();
            string mode = _active_mode;
            hide();

            if (mode == "region") {
                _pick_recording_region(delay_secs);
                return;
            }

            var request = mode == "window" ? _window_recording_request() : _screen_recording_request();
            if (request == null) {
                _notify_recording_failed(_("Could not find the screen to record."));
                return;
            }
            _start_recording_after(request, delay_secs);
        }

        private void _start_recording_after(ScreenRecordingRequest request, int delay_secs) {
            request.cursor = _cursor_switch.active;
            request.audio = _audio_switch.active;
            _last_recording = request;
            if (delay_secs > 0) {
                GLib.Timeout.add_seconds(delay_secs, () => {
                    ScreenRecorder.get_default().start(request);
                    return GLib.Source.REMOVE;
                });
            } else {
                ScreenRecorder.get_default().start(request);
            }
        }

        private ScreenRecordingRequest? _screen_recording_request() {
            if (_target_monitor == null) return null;
            var request = new ScreenRecordingRequest();
            request.output = _target_monitor.get_connector();
            var geo = _target_monitor.get_geometry();
            request.output_width = geo.width;
            request.output_height = geo.height;
            return request.output != null ? request : null;
        }

        private ScreenRecordingRequest? _window_recording_request() {
            void* handle = focused_handle;
            if (handle == null) return _screen_recording_request();

            int x, y, w, h, maximized, fullscreen;
            string? connector;
            bool got_geometry = Singularity.wayland_get_window_geometry(handle,
                out x, out y, out w, out h, out maximized, out fullscreen, out connector);

            Gdk.Monitor? monitor = got_geometry ? monitor_for_connector(connector) : null;
            if (monitor == null && got_geometry && w > 0 && h > 0) monitor = monitor_for_geometry(x, y, w, h);
            if (monitor == null) monitor = _target_monitor;
            if (monitor == null) return null;

            var request = new ScreenRecordingRequest();
            request.output = monitor.get_connector();
            var geo = monitor.get_geometry();
            request.output_width = geo.width;
            request.output_height = geo.height;
            if (got_geometry && w > 0 && h > 0) {
                request.crop_x = x - geo.x;
                request.crop_y = y - geo.y;
                request.crop_width = w;
                request.crop_height = h;
            }

            var win = AppSystem.get_default().get_window_by_handle(handle);
            if (win != null) {
                request.window_app_id = win.app_id;
                request.window_title = win.title;
            }
            return request.output != null ? request : null;
        }

        private void _pick_recording_region(int delay_secs) {
            if (_region_picker != null) return;
            string helper = AppSystem.resolve_companion_bin("singularity-region-picker");
            GLib.Subprocess picker;
            try {
                picker = new GLib.Subprocess(
                    GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_SILENCE, helper);
            } catch (Error e) {
                _notify_recording_failed(_("Could not open the region selector: %s").printf(e.message));
                return;
            }
            _region_picker = picker;
            picker.communicate_utf8_async.begin(null, null, (obj, res) => {
                string? output = null;
                try {
                    picker.communicate_utf8_async.end(res, out output, null);
                } catch (Error e) {
                    output = null;
                }
                _region_picker = null;
                if (!picker.get_if_exited() || picker.get_exit_status() != 0 || output == null) return;

                int x, y, w, h;
                if (!_parse_region(output, out x, out y, out w, out h)) {
                    _notify_recording_failed(_("The selected region is not valid."));
                    return;
                }
                var monitor = monitor_for_geometry(x, y, w, h);
                if (monitor == null || monitor.get_connector() == null) {
                    _notify_recording_failed(_("Could not find the screen to record."));
                    return;
                }
                var geo = monitor.get_geometry();
                var request = new ScreenRecordingRequest();
                request.output = monitor.get_connector();
                request.output_width = geo.width;
                request.output_height = geo.height;
                request.crop_x = x - geo.x;
                request.crop_y = y - geo.y;
                request.crop_width = w;
                request.crop_height = h;
                _start_recording_after(request, delay_secs);
            });
        }

        private bool _parse_region(string value, out int x, out int y, out int width, out int height) {
            x = y = width = height = 0;
            string[] fields = value.strip().split(" ");
            if (fields.length != 2) return false;
            string[] position = fields[0].split(",");
            string[] size = fields[1].split("x");
            if (position.length != 2 || size.length != 2) return false;
            return int.try_parse(position[0], out x)
                && int.try_parse(position[1], out y)
                && int.try_parse(size[0], out width)
                && int.try_parse(size[1], out height)
                && width > 0 && height > 0;
        }

        private void _notify_recording_saved(string path, string[] warnings) {
            var mgr = SystemMonitor.get_default().notifications;
            string body = _("Saved as %s").printf(GLib.Path.get_basename(path));
            foreach (var w in warnings) body += "\n" + w;
            string[] actions = { "open", _("Open"), "show", _("Show in Files"), "share", _("Share") };
            uint nid = mgr.notify(_("Screen Recording"), 0, "camera-video-symbolic",
                _("Screen Recording Saved"), body, actions,
                new HashTable<string, Variant>(str_hash, str_equal), -1);
            _screenshot_notification_actions.set(nid, path);
        }

        private void _notify_recording_failed(string message) {
            var mgr = SystemMonitor.get_default().notifications;
            var hints = new HashTable<string, Variant>(str_hash, str_equal);
            hints.insert("urgency", new Variant.byte(2));
            mgr.notify(_("Screen Recording"), 0, "dialog-error-symbolic",
                _("Screen Recording Failed"), message, {}, hints, -1);
            warning("[ScreenshotTool] recording failed: %s", message);

            var app = application as Gtk.Application;
            if (app == null || !mgr.do_not_disturb_active) return;
            var retry = _last_recording;
            new PowerConfirmDialog(
                app,
                _("Screen Recording Failed"),
                "camera-video-symbolic",
                message,
                _("Try Again"),
                () => {
                    if (retry != null) ScreenRecorder.get_default().start(retry);
                }
            ).open_dialog();
        }

        private void _notify_screenshot(string msg, string? file_path) {
            var mgr = SystemMonitor.get_default().notifications;
            string icon = file_path ?? "accessories-screenshot";
            string[] actions = {};
            string? saved_path = null;
            if (file_path != null) {
                saved_path = ScreenshotPortal.get_default().save_to_pictures("file://" + file_path);
            }
            string open_path = saved_path ?? file_path;
            if (open_path != null) {
                actions += "default";
                actions += _("Markup");
                actions += "markup";
                actions += _("Markup");
                actions += "open";
                actions += "Open";
                actions += "show";
                actions += "Show in Files";
                actions += "share";
                actions += _("Share");
                icon = open_path;
            }
            uint nid = mgr.notify("Screenshot", 0, icon,
                "Screenshot", msg, actions,
                new HashTable<string, Variant>(str_hash, str_equal), -1);
            _screenshot_notification_actions.set(nid, open_path);
        }

        private void _handle_notification_action(uint id, string action) {
            string? path = _screenshot_notification_actions.get(id);
            if (path == null) return;
            if (action == "markup" || action == "default") {
                open_markup(path);
            } else if (action == "open") {
                try {
                    AppInfo.launch_default_for_uri(File.new_for_path(path).get_uri(), null);
                } catch (Error e) {
                    warning("[ScreenshotTool] Failed to open: %s", e.message);
                }
            } else if (action == "show") {
                try {
                    var file = File.new_for_path(path);
                    if (!_show_item_in_files(file)) {
                        var parent = file.get_parent();
                        if (parent != null)
                            AppInfo.launch_default_for_uri(parent.get_uri(), null);
                    }
                } catch (Error e) {
                    warning("[ScreenshotTool] Failed to show in files: %s", e.message);
                }
            } else if (action == "share") {
                Singularity.ShareTargets.activate_app_action.begin("dev.sinty.files", "share-files",
                    new Variant.strv({ File.new_for_path(path).get_uri() }));
            }
            _screenshot_notification_actions.remove(id);
        }

        public static void open_markup(string path) {
            string helper = AppSystem.resolve_companion_bin("singularity-markup");
            try {
                new GLib.Subprocess.newv({ helper, "--in-place", path }, GLib.SubprocessFlags.NONE);
            } catch (Error e) {
                warning("[ScreenshotTool] could not open Markup: %s", e.message);
            }
        }

        private bool _show_item_in_files(File file) {
            try {
                var uris = new VariantBuilder(new VariantType("as"));
                uris.add("s", file.get_uri());

                var bus = Bus.get_sync(BusType.SESSION);
                bus.call_sync("org.freedesktop.FileManager1",
                    "/org/freedesktop/FileManager1",
                    "org.freedesktop.FileManager1",
                    "ShowItems",
                    new Variant("(ass)", uris, ""),
                    null, DBusCallFlags.NONE, -1, null);
                return true;
            } catch (Error e) {
                warning("[ScreenshotTool] Failed to reveal screenshot in files: %s", e.message);
                return false;
            }
        }

        private void dispatch_capture() {
            if (!ensure_screenshots()) return;
            if (_pending_region) {
                _do_region();
            } else if (_pending_window) {
                _do_window();
            } else {
                _do_screen();
            }
        }

        public bool ensure_screenshots() {
            if (!ScreenshotPortal.get_default().is_available()) {
                _show_unavailable_dialog();
                return false;
            }
            return true;
        }

        private void _show_unavailable_dialog() {
            var app = application as Gtk.Application;
            if (app == null) return;
            hide();
            new PowerConfirmDialog(
                app,
                _("Screenshots unavailable"),
                "camera-photo-symbolic",
                _("Singularity could not capture a screenshot. The screenshot service is not available in this session. This usually means you are not running inside the Singularity session, or xdg-desktop-portal-singularity is not installed. See the documentation for details."),
                _("Open documentation"),
                () => {
                    try {
                        AppInfo.launch_default_for_uri("https://sinty.dev/docs/troubleshooting/", null);
                    } catch (Error e) {
                        warning("[ScreenshotTool] could not open docs: %s", e.message);
                    }
                }
            ).open_dialog();
        }

        private void _do_screen(bool show_failure = true) {
            var args = target_monitor_capture_args();
            if (args == null) {
                warning("[ScreenshotTool] no target monitor for screen capture");
                if (show_failure) _show_unavailable_dialog();
                return;
            }
            run_local_screenshot(args, "Saved and copied to clipboard", false, show_failure);
        }

        private void _do_region() {
            var portal = ScreenshotPortal.get_default();
            if (screenshot_handler_id != 0) {
                portal.disconnect(screenshot_handler_id);
                screenshot_handler_id = 0;
            }
            screenshot_handler_id = portal.screenshot_taken.connect((uri) => {
                if (screenshot_handler_id != 0) {
                    portal.disconnect(screenshot_handler_id);
                    screenshot_handler_id = 0;
                }
                var file = GLib.File.new_for_uri(uri);
                string? path = file.get_path();
                if (path != null) portal.copy_to_clipboard(path);
                portal.save_to_pictures(uri);
                Singularity.Shell.ScreenFlash.flash();
                _notify_screenshot("Region saved and copied to clipboard", path);
            });
            portal.take_screenshot.begin(true);
        }

        private void _do_window() {
            void* handle = focused_handle;
            if (handle == null) {
                _do_screen();
                return;
            }

            int x, y, w, h, maximized, fullscreen;
            string? connector;
            bool got_geometry = Singularity.wayland_get_window_geometry(handle,
                out x, out y, out w, out h, out maximized, out fullscreen, out connector);
            if (!got_geometry || w <= 0 || h <= 0) {
                warning("[ScreenshotTool] no valid focused window geometry, falling back to monitor");
                _do_screen();
                return;
            }

            string[] args = {};
            if (_cursor_switch.active) args += "-c";
            string geometry = "%d,%d %dx%d".printf(x, y, w, h);
            args += "-g";
            args += geometry;
            run_local_screenshot(args, "Window captured and copied to clipboard", true);
        }

        private void run_local_screenshot(string[] capture_args, string notification_message,
                                          bool fallback_to_monitor = false,
                                          bool show_failure = true) {
            string temp_path;
            try {
                int fd = GLib.FileUtils.open_tmp("singularity-screenshot-XXXXXX.png", out temp_path);
                Posix.close(fd);
            } catch (Error e) {
                warning("[ScreenshotTool] temp file: %s", e.message);
                if (fallback_to_monitor) {
                    _do_screen(false);
                } else if (show_failure) {
                    _show_unavailable_dialog();
                }
                return;
            }

            string helper = AppSystem.resolve_companion_bin("singularity-screenshot");
            string[] argv = { helper };
            foreach (var arg in capture_args) argv += arg;
            argv += temp_path;

            try {
                var proc = new GLib.Subprocess.newv(argv,
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
                proc.wait_check_async.begin(null, (obj, res) => {
                    bool ok = false;
                    try {
                        ok = proc.wait_check_async.end(res);
                    } catch (Error e) {
                        warning("[ScreenshotTool] singularity-screenshot failed: %s", e.message);
                    }
                    if (!ok || !file_has_data(temp_path)) {
                        GLib.FileUtils.unlink(temp_path);
                        if (fallback_to_monitor) {
                            _do_screen(false);
                        } else if (show_failure) {
                            _show_unavailable_dialog();
                        }
                        return;
                    }
                    var portal = ScreenshotPortal.get_default();
                    portal.copy_to_clipboard(temp_path);
                    Singularity.Shell.ScreenFlash.flash();
                    _notify_screenshot(notification_message, temp_path);
                    GLib.Timeout.add(3000, () => {
                        GLib.FileUtils.unlink(temp_path);
                        return GLib.Source.REMOVE;
                    });
                });
            } catch (Error e) {
                warning("[ScreenshotTool] singularity-screenshot spawn failed: %s", e.message);
                GLib.FileUtils.unlink(temp_path);
                if (fallback_to_monitor) {
                    _do_screen(false);
                } else if (show_failure) {
                    _show_unavailable_dialog();
                }
            }
        }

        private string[]? target_monitor_capture_args() {
            string[] args = {};
            if (_cursor_switch.active) args += "-c";

            if (_target_connector != null && _target_connector != "") {
                args += "-o";
                args += _target_connector;
                return args;
            }

            if (_target_monitor != null) {
                var geo = _target_monitor.get_geometry();
                args += "-g";
                args += "%d,%d %dx%d".printf(geo.x, geo.y, geo.width, geo.height);
                return args;
            }

            return null;
        }

        private Gdk.Monitor? first_monitor() {
            var display = Gdk.Display.get_default();
            if (display == null) return null;
            var monitors = display.get_monitors();
            if (monitors.get_n_items() == 0) return null;
            return monitors.get_item(0) as Gdk.Monitor;
        }

        private bool file_has_data(string path) {
            try {
                var info = File.new_for_path(path).query_info(
                    "standard::size", FileQueryInfoFlags.NONE, null);
                return info.get_size() > 0;
            } catch (Error e) {
                return false;
            }
        }
        private void setup_styles() {
            var provider = new Gtk.CssProvider();
            provider.load_from_data(SCREENSHOT_CSS.data);
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string SCREENSHOT_CSS = """
/* Screenshot Tool. The card surface (background, border, shadow) comes from
   the shared `.dialog-card` style; only the inner controls are styled here. */
.screenshot-tool .segmented-button {
    padding: 6px 16px;
}
.screenshot-tool .screenshot-delay-field {
    background-color: alpha(@text_color, 0.06);
    border-radius: 8px;
    padding: 2px 6px;
}
.screenshot-tool .screenshot-delay-field button.delay-step {
    min-width: 18px;
    min-height: 18px;
    padding: 0;
    margin: 0;
}
.screenshot-tool .screenshot-delay-field button.delay-step image {
    -gtk-icon-size: 12px;
}
.screenshot-tool .screenshot-delay-field entry {
    background: none;
    box-shadow: none;
    border: none;
    outline: none;
    min-height: 24px;
    padding: 0;
}
""";
    }
}
