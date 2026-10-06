using Gtk;

namespace Singularity {

    public class RecordingIndicator : Gtk.Button {
        private static bool _styled = false;
        private Label _time_label;
        private ulong _tick_id = 0;
        private ulong _state_id = 0;

        public RecordingIndicator() {
            Object();
            ensure_style();
            has_frame = false;
            valign = Align.CENTER;
            visible = false;
            add_css_class("system-pill-button");
            add_css_class("recording-indicator");
            tooltip_text = _("Stop Recording");
            update_property(Gtk.AccessibleProperty.LABEL, _("Stop Recording"), -1);

            var box = new Box(Orientation.HORIZONTAL, 6);
            var dot = new Box(Orientation.HORIZONTAL, 0);
            dot.add_css_class("recording-dot");
            dot.valign = Align.CENTER;
            box.append(dot);
            _time_label = new Label("00:00");
            _time_label.add_css_class("numeric");
            box.append(_time_label);
            set_child(box);

            var recorder = ScreenRecorder.get_default();
            clicked.connect(() => recorder.stop());
            _tick_id = recorder.tick.connect((seconds) => {
                _time_label.label = format_elapsed(seconds);
            });
            _state_id = recorder.notify["recording"].connect(() => sync(recorder));
            sync(recorder);
        }

        public override void dispose() {
            var recorder = ScreenRecorder.get_default();
            if (_tick_id != 0) {
                recorder.disconnect(_tick_id);
                _tick_id = 0;
            }
            if (_state_id != 0) {
                recorder.disconnect(_state_id);
                _state_id = 0;
            }
            base.dispose();
        }

        public static string format_elapsed(int64 seconds) {
            if (seconds < 0) seconds = 0;
            return "%02d:%02d".printf((int) (seconds / 60), (int) (seconds % 60));
        }

        private void sync(ScreenRecorder recorder) {
            visible = recorder.recording;
            _time_label.label = format_elapsed(recorder.elapsed_seconds);
        }

        private static void ensure_style() {
            if (_styled) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            _styled = true;
            var provider = new Gtk.CssProvider();
            provider.load_from_data(RECORDING_CSS.data);
            Gtk.StyleContext.add_provider_for_display(display, provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string RECORDING_CSS = """
.recording-indicator .recording-dot {
    background-color: @destructive_color;
    min-width: 8px;
    min-height: 8px;
    border-radius: 999px;
}
.recording-indicator label {
    font-feature-settings: "tnum";
}
""";
    }
}
