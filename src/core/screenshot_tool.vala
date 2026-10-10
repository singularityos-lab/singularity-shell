using GLib;
using Gtk;
using Gee;
using GtkLayerShell;

namespace Singularity {

    public class ScreenshotTool : Singularity.Shell.ShellDialog {
        private static ScreenshotTool? _instance = null;

        public void* focused_handle { get; set; default = null; }

        private Gtk.ToggleButton _region_tile;
        private Gtk.ToggleButton _screen_tile;
        private Gtk.ToggleButton _window_tile;
        private Gtk.ToggleButton _photo_btn;
        private Gtk.ToggleButton _video_btn;
        private Gtk.MenuButton _timer_btn;
        private Gtk.Label _timer_label;
        private int _delay = 0;
        private string _active_mode = "screen";
        private Gtk.ToggleButton _cursor_toggle;
        private Gtk.ToggleButton _audio_toggle;
        private Gtk.Button _capture_btn;
        private string? _frozen_plain = null;
        private string? _frozen_cursor = null;
        private Gdk.Rectangle _frozen_geo;
        private int _freeze_pending = 0;
        private uint _freeze_timeout = 0;
        private ScreenRecordingRequest? _last_recording = null;
        private GLib.Subprocess? _region_picker = null;
        private ulong screenshot_handler_id = 0;
        private bool _pending_region = false;
        private bool _pending_window = false;
        private Gdk.Monitor? _target_monitor = null;
        private string? _target_connector = null;
        private Gee.HashMap<uint, string> _screenshot_notification_actions = new Gee.HashMap<uint, string>();
        private bool _thumbnail_connected = false;

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

            var modes = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            modes.halign = Gtk.Align.CENTER;
            box.append(modes);
            _region_tile = make_tile("singularity-markup-crop-symbolic", _("Selection"), "region", null);
            _screen_tile = make_tile("video-display-symbolic", _("Screen"), "screen", _region_tile);
            _window_tile = make_tile("window-symbolic", _("Window"), "window", _region_tile);
            modes.append(_region_tile);
            modes.append(_screen_tile);
            modes.append(_window_tile);
            _screen_tile.active = true;

            var bottom = new Gtk.CenterBox();
            box.append(bottom);

            var kind = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            kind.add_css_class("screenshot-kind");
            kind.valign = Gtk.Align.CENTER;
            _photo_btn = new Gtk.ToggleButton();
            _photo_btn.icon_name = "camera-photo-symbolic";
            _photo_btn.tooltip_text = _("Screenshot");
            _photo_btn.active = true;
            _video_btn = new Gtk.ToggleButton();
            _video_btn.icon_name = "camera-video-symbolic";
            _video_btn.tooltip_text = _("Screen Recording");
            _video_btn.group = _photo_btn;
            _video_btn.toggled.connect(sync_kind);
            kind.append(_photo_btn);
            kind.append(_video_btn);
            bottom.start_widget = kind;

            _capture_btn = new Gtk.Button();
            _capture_btn.add_css_class("screenshot-shutter");
            _capture_btn.valign = Gtk.Align.CENTER;
            var dot = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            dot.add_css_class("shutter-dot");
            dot.halign = Gtk.Align.CENTER;
            dot.valign = Gtk.Align.CENTER;
            _capture_btn.child = dot;
            _capture_btn.clicked.connect(() => {
                if (_video_btn.active) on_video_clicked();
                else on_take_clicked();
            });
            bottom.center_widget = _capture_btn;
            default_widget = _capture_btn;

            var extras = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            extras.valign = Gtk.Align.CENTER;
            extras.halign = Gtk.Align.END;

            _timer_btn = new Gtk.MenuButton();
            _timer_btn.add_css_class("screenshot-option");
            _timer_btn.tooltip_text = _("Timer");
            var timer_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
            timer_box.halign = Gtk.Align.CENTER;
            timer_box.append(new Gtk.Image.from_icon_name("alarm-symbolic"));
            _timer_label = new Gtk.Label("");
            _timer_label.visible = false;
            timer_box.append(_timer_label);
            _timer_btn.child = timer_box;
            var timer_pop = new Gtk.Popover();
            var timer_list = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            int[] delays = { 0, 3, 5, 10 };
            foreach (int d in delays) {
                var item = new Gtk.Button.with_label(d == 0 ? _("No Timer") : ngettext("%d Second", "%d Seconds", d).printf(d));
                item.add_css_class("flat");
                item.child.halign = Gtk.Align.START;
                item.clicked.connect(() => {
                    _delay = d;
                    _timer_label.label = "%d".printf(d);
                    _timer_label.visible = d > 0;
                    if (d > 0) _timer_btn.add_css_class("active");
                    else _timer_btn.remove_css_class("active");
                    timer_pop.popdown();
                });
                timer_list.append(item);
            }
            timer_pop.child = timer_list;
            _timer_btn.popover = timer_pop;
            extras.append(_timer_btn);

            _cursor_toggle = new Gtk.ToggleButton();
            _cursor_toggle.icon_name = "input-mouse-symbolic";
            _cursor_toggle.tooltip_text = _("Show Pointer");
            _cursor_toggle.add_css_class("screenshot-option");
            _cursor_toggle.active = true;
            extras.append(_cursor_toggle);

            _audio_toggle = new Gtk.ToggleButton();
            _audio_toggle.icon_name = "audio-volume-high-symbolic";
            _audio_toggle.tooltip_text = _("Record Audio");
            _audio_toggle.add_css_class("screenshot-option");
            extras.append(_audio_toggle);
            bottom.end_widget = extras;

            var keys = new Gtk.EventControllerKey();
            keys.propagation_phase = Gtk.PropagationPhase.CAPTURE;
            keys.key_pressed.connect((keyval, code, state) => {
                if (keyval != Gdk.Key.Return && keyval != Gdk.Key.KP_Enter) return false;
                if (!_capture_btn.sensitive || _timer_btn.active) return false;
                if (_video_btn.active) on_video_clicked();
                else on_take_clicked();
                return true;
            });
            ((Gtk.Widget) this).add_controller(keys);
            sync_kind();
            notify["visible"].connect(() => {
                if (!visible) drop_frozen();
            });

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
            if (_freeze_pending > 0) return;
            freeze_screen();
        }

        private void show_dialog_now() {
            base.open_dialog();
        }

        private delegate void CaptureDone(string? path);

        private void freeze_screen() {
            drop_frozen();
            if (_target_monitor == null) {
                show_dialog_now();
                return;
            }
            _frozen_geo = _target_monitor.get_geometry();
            _freeze_pending = 2;
            _freeze_timeout = GLib.Timeout.add(1000, () => {
                _freeze_timeout = 0;
                finish_freeze(true);
                return GLib.Source.REMOVE;
            });
            capture_to_temp(monitor_args(false), (path) => {
                _frozen_plain = path;
                finish_freeze(false);
            });
            capture_to_temp(monitor_args(true), (path) => {
                _frozen_cursor = path;
                finish_freeze(false);
            });
        }

        private void finish_freeze(bool timed_out) {
            if (_freeze_pending <= 0) return;
            if (!timed_out && --_freeze_pending > 0) return;
            _freeze_pending = 0;
            if (_freeze_timeout != 0) {
                GLib.Source.remove(_freeze_timeout);
                _freeze_timeout = 0;
            }
            show_dialog_now();
        }

        private void drop_frozen() {
            if (_frozen_plain != null) GLib.FileUtils.unlink(_frozen_plain);
            if (_frozen_cursor != null) GLib.FileUtils.unlink(_frozen_cursor);
            _frozen_plain = null;
            _frozen_cursor = null;
        }

        private string? take_frozen() {
            string? chosen = _cursor_toggle.active ? _frozen_cursor : _frozen_plain;
            if (chosen == _frozen_cursor) _frozen_cursor = null;
            else _frozen_plain = null;
            return chosen;
        }

        private void capture_to_temp(string[]? capture_args, owned CaptureDone done) {
            if (capture_args == null) {
                done(null);
                return;
            }
            string temp_path;
            try {
                int fd = GLib.FileUtils.open_tmp("singularity-screenshot-XXXXXX.png", out temp_path);
                Posix.close(fd);
            } catch (Error e) {
                done(null);
                return;
            }
            string[] argv = { AppSystem.resolve_companion_bin("singularity-screenshot") };
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
                        ok = false;
                    }
                    if (!ok || !file_has_data(temp_path)) {
                        GLib.FileUtils.unlink(temp_path);
                        done(null);
                        return;
                    }
                    done(temp_path);
                });
            } catch (Error e) {
                GLib.FileUtils.unlink(temp_path);
                done(null);
            }
        }

        private void deliver_capture(string path, string message) {
            ScreenshotPortal.get_default().copy_to_clipboard(path);
            Singularity.Shell.ScreenFlash.flash();
            _notify_screenshot(message, path);
            GLib.Timeout.add(3000, () => {
                GLib.FileUtils.unlink(path);
                return GLib.Source.REMOVE;
            });
        }

        private void deliver_crop(string frozen, int x, int y, int w, int h, string message) {
            try {
                var full = new Gdk.Pixbuf.from_file(frozen);
                double scale = (double) full.width / int.max(1, _frozen_geo.width);
                int cx = int.max(0, (int) Math.round((x - _frozen_geo.x) * scale));
                int cy = int.max(0, (int) Math.round((y - _frozen_geo.y) * scale));
                int cw = int.min(full.width - cx, (int) Math.round(w * scale));
                int ch = int.min(full.height - cy, (int) Math.round(h * scale));
                GLib.FileUtils.unlink(frozen);
                if (cw <= 0 || ch <= 0) return;
                string temp_path;
                int fd = GLib.FileUtils.open_tmp("singularity-screenshot-XXXXXX.png", out temp_path);
                Posix.close(fd);
                new Gdk.Pixbuf.subpixbuf(full, cx, cy, cw, ch).savev(temp_path, "png", {}, {});
                deliver_capture(temp_path, message);
            } catch (Error e) {
                warning("[ScreenshotTool] crop failed: %s", e.message);
                GLib.FileUtils.unlink(frozen);
            }
        }

        private bool use_frozen() {
            string? frozen = take_frozen();
            if (frozen == null) return false;
            hide();
            if (_active_mode == "window" && focused_handle != null) {
                int x, y, w, h, maximized, fullscreen;
                string? connector;
                if (Singularity.wayland_get_window_geometry(focused_handle,
                        out x, out y, out w, out h, out maximized, out fullscreen, out connector) && w > 0 && h > 0) {
                    deliver_crop(frozen, x, y, w, h, "Window captured and copied to clipboard");
                    return true;
                }
            }
            if (_active_mode == "region") {
                pick_frozen_region(frozen);
                return true;
            }
            deliver_capture(frozen, "Saved and copied to clipboard");
            return true;
        }

        private void pick_frozen_region(string frozen) {
            if (_region_picker != null) {
                GLib.FileUtils.unlink(frozen);
                return;
            }
            GLib.Subprocess picker;
            try {
                picker = new GLib.Subprocess(GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_SILENCE,
                    AppSystem.resolve_companion_bin("singularity-region-picker"));
            } catch (Error e) {
                GLib.FileUtils.unlink(frozen);
                _do_region();
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
                int x = 0, y = 0, w = 0, h = 0;
                if (!picker.get_if_exited() || picker.get_exit_status() != 0 || output == null
                        || !_parse_region(output, out x, out y, out w, out h)) {
                    GLib.FileUtils.unlink(frozen);
                    return;
                }
                deliver_crop(frozen, x, y, w, h, "Region saved and copied to clipboard");
            });
        }

        private int current_delay() {
            return _delay;
        }

        private Gtk.ToggleButton make_tile(string icon, string tooltip, string mode, Gtk.ToggleButton? group) {
            var tile = new Gtk.ToggleButton();
            tile.add_css_class("screenshot-tile");
            tile.tooltip_text = tooltip;
            var image = new Gtk.Image.from_icon_name(icon);
            image.pixel_size = 24;
            tile.child = image;
            if (group != null) tile.group = group;
            tile.toggled.connect(() => {
                if (tile.active) _active_mode = mode;
            });
            return tile;
        }

        private void sync_kind() {
            bool video = _video_btn.active;
            _audio_toggle.visible = video;
            if (video) _capture_btn.add_css_class("recording");
            else _capture_btn.remove_css_class("recording");
            _capture_btn.tooltip_text = video ? _("Start Recording") : _("Take Screenshot");
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

            if (delay_secs == 0 && use_frozen()) return;
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
            request.cursor = _cursor_toggle.active;
            request.audio = _audio_toggle.active;
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
            var app = application as Gtk.Application;
            if (open_path != null && app != null) {
                var thumb = ScreenshotThumbnail.get_default(app);
                if (!_thumbnail_connected) {
                    _thumbnail_connected = true;
                    thumb.action_requested.connect((p, a) => _run_screenshot_action(p, a));
                }
                thumb.show_for(open_path, msg, _target_monitor);
                return;
            }
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
            _run_screenshot_action(path, action);
            _screenshot_notification_actions.remove(id);
        }

        private void _run_screenshot_action(string path, string action) {
            if (action == "copy") {
                ScreenshotPortal.get_default().copy_to_clipboard(path);
            } else if (action == "trash") {
                try {
                    File.new_for_path(path).trash();
                } catch (Error e) {
                    warning("[ScreenshotTool] Failed to trash: %s", e.message);
                }
            } else if (action == "markup" || action == "default") {
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
            if (_cursor_toggle.active) args += "-c";
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
            return monitor_args(_cursor_toggle.active);
        }

        private string[]? monitor_args(bool cursor) {
            string[] args = {};
            if (cursor) args += "-c";

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
                Gtk.STYLE_PROVIDER_PRIORITY_USER + 1);
        }

        private const string SCREENSHOT_CSS = """
.screenshot-tool button.screenshot-tile {
    min-width: 100px;
    min-height: 60px;
    border-radius: 14px;
    background: alpha(@text_color, 0.06);
    color: @text_color;
}
.screenshot-tool button.screenshot-tile:hover {
    background: alpha(@text_color, 0.10);
}
.screenshot-tool button.screenshot-tile:checked {
    background: @accent_bg_color;
    color: @accent_fg_color;
}
.screenshot-tool .screenshot-kind {
    background: alpha(@text_color, 0.06);
    border-radius: 999px;
    padding: 3px;
}
.screenshot-tool .screenshot-kind button {
    min-width: 36px;
    min-height: 30px;
    padding: 0;
    border: none;
    border-radius: 999px;
    background: transparent;
    box-shadow: none;
}
.screenshot-tool .screenshot-kind button:hover:not(:checked) {
    background: alpha(@text_color, 0.08);
}
.screenshot-tool .screenshot-kind button:checked {
    background: @accent_bg_color;
    color: @accent_fg_color;
}
.screenshot-tool button.screenshot-shutter {
    min-width: 52px;
    min-height: 52px;
    padding: 0;
    border-radius: 999px;
    background: none;
    box-shadow: inset 0 0 0 3px @text_color;
}
.screenshot-tool button.screenshot-shutter .shutter-dot {
    min-width: 40px;
    min-height: 40px;
    border-radius: 999px;
    background: @text_color;
    transition: background 150ms ease, min-width 150ms ease, min-height 150ms ease;
}
.screenshot-tool button.screenshot-shutter:hover .shutter-dot {
    min-width: 36px;
    min-height: 36px;
}
.screenshot-tool button.screenshot-shutter.recording .shutter-dot {
    background: #e5534b;
}
.screenshot-tool button.screenshot-option,
.screenshot-tool .screenshot-option > button {
    min-width: 36px;
    min-height: 36px;
    padding: 0;
    border: none;
    border-radius: 999px;
    background: transparent;
    box-shadow: none;
}
.screenshot-tool button.screenshot-option:hover,
.screenshot-tool .screenshot-option > button:hover {
    background: alpha(@text_color, 0.08);
}
.screenshot-tool button.screenshot-option:checked,
.screenshot-tool .screenshot-option.active > button {
    background: alpha(@accent_bg_color, 0.18);
    color: @accent_color;
}
""";
    }
}
