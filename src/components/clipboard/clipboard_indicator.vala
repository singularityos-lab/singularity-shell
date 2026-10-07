using Gtk;

namespace Singularity {

    public class ClipboardIndicator : Gtk.Button {
        private ulong _changed_id = 0;

        public ClipboardIndicator() {
            Object();
            has_frame = false;
            valign = Align.CENTER;
            add_css_class("system-pill-button");
            add_css_class("clipboard-indicator");
            var icon = new Image.from_icon_name("edit-paste-symbolic");
            icon.pixel_size = 16;
            set_child(icon);
            tooltip_text = _("Clipboard History");
            clicked.connect(() => SystemMonitor.get_default().shortcuts.clipboard_history_triggered());
            var history = ClipboardHistory.get_default();
            if (history.settings != null) _changed_id = history.settings.changed.connect(() => sync(history));
            sync(history);
        }

        public override void dispose() {
            var history = ClipboardHistory.get_default();
            if (_changed_id != 0 && history.settings != null) {
                history.settings.disconnect(_changed_id);
                _changed_id = 0;
            }
            base.dispose();
        }

        private void sync(ClipboardHistory history) {
            visible = history.settings != null
                && history.settings.settings_schema.has_key("show-in-panel")
                && history.settings.get_boolean("show-in-panel")
                && history.settings.get_boolean("history-enabled");
        }
    }
}
