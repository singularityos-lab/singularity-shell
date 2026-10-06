using Gtk;
using Singularity.Widgets;
using Singularity.Crash;

namespace Singularity.Shell {

    public class CrashDetailsWindow : AppDialog {
        private Report report;
        private Config config;
        private TextView backtrace_view;
        private Spinner spinner;
        private Label backtrace_status;
        private Button copy_button;
        private ScrolledWindow trace_scroll;

        public CrashDetailsWindow(Report report, Config config) {
            base(GLib.Application.get_default() as Gtk.Application, false, true);
            this.report = report;
            this.config = config;
            add_css_class("crash-details");
            set_title(_("Problem Details"));
            set_default_size(620, 640);

            var body = new Box(Orientation.VERTICAL, 18);
            body.margin_start = 24;
            body.margin_end = 24;
            body.margin_top = 8;
            body.margin_bottom = 8;

            var header = new Box(Orientation.HORIZONTAL, 16);
            var icon = new Image();
            icon.pixel_size = 64;
            var app = Metadata.find_app(report);
            if (app != null && app.get_icon() != null) icon.gicon = app.get_icon();
            else icon.icon_name = "dialog-warning";
            icon.valign = Align.CENTER;
            header.append(icon);
            var titles = new Box(Orientation.VERTICAL, 4);
            titles.valign = Align.CENTER;
            titles.hexpand = true;
            var title = new Label(_("%s quit unexpectedly").printf(report.display_name()));
            title.add_css_class("title-2");
            title.xalign = 0;
            title.wrap = true;
            titles.append(title);
            string when = report.format_time();
            string signal_text = Report.signal_label(report.signal_number);
            var subtitle = new Label(when != "" ? "%s, %s".printf(signal_text, when) : signal_text);
            subtitle.add_css_class("dim-label");
            subtitle.xalign = 0;
            subtitle.wrap = true;
            titles.append(subtitle);
            header.append(titles);
            body.append(header);

            var trace = new PreferencesGroup(_("Backtrace"),
                _("The functions that were running when the app stopped."));
            var trace_box = new Box(Orientation.VERTICAL, 8);
            var status_row = new Box(Orientation.HORIZONTAL, 8);
            status_row.margin_start = 12;
            status_row.margin_end = 12;
            status_row.margin_top = 4;
            status_row.margin_bottom = 4;
            spinner = new Spinner();
            status_row.append(spinner);
            backtrace_status = new Label("");
            backtrace_status.add_css_class("dim-label");
            backtrace_status.xalign = 0;
            backtrace_status.wrap = true;
            backtrace_status.hexpand = true;
            status_row.append(backtrace_status);
            trace_box.append(status_row);
            backtrace_view = new TextView();
            backtrace_view.editable = false;
            backtrace_view.cursor_visible = false;
            backtrace_view.monospace = true;
            backtrace_view.wrap_mode = WrapMode.NONE;
            backtrace_view.top_margin = 10;
            backtrace_view.bottom_margin = 10;
            backtrace_view.left_margin = 12;
            backtrace_view.right_margin = 12;
            backtrace_view.add_css_class("card");
            trace_scroll = new ScrolledWindow();
            trace_scroll.min_content_height = 260;
            trace_scroll.vexpand = true;
            trace_scroll.child = backtrace_view;
            trace_box.append(trace_scroll);
            trace.add_row(trace_box);
            body.append(trace);

            var about = new PreferencesGroup(_("App and System"));
            add_info(about, _("Version"), report.app_version != "" ? report.app_version : _("Unknown"));
            add_info(about, _("Program"), report.executable);
            add_info(about, _("Process"), report.pid.to_string());
            add_info(about, _("Collected By"), source_title(report.source));
            add_info(about, _("Operating System"), report.os_name);
            add_info(about, _("Kernel"), report.kernel);
            body.append(about);

            var note = new Label(_("Nothing is sent automatically. Report Issue opens the page of the app's developers, where you can paste the copied report."));
            note.add_css_class("dim-label");
            note.add_css_class("caption");
            note.wrap = true;
            note.xalign = 0;
            body.append(note);

            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = body;
            content_box.append(scroll);

            var footer = new Box(Orientation.HORIZONTAL, 12);
            footer.margin_top = 12;
            footer.margin_bottom = 16;
            footer.margin_start = 16;
            footer.margin_end = 16;
            var close_button = add_cancel_button(_("Close"));
            close_button.add_css_class("pill");
            footer.append(close_button);
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            footer.append(spacer);
            if (report.bug_url != "") {
                var issue = new Button.with_label(_("Report Issue"));
                issue.add_css_class("pill");
                issue.tooltip_text = report.bug_url;
                issue.clicked.connect(open_bug_tracker);
                footer.append(issue);
            }
            copy_button = new Button.with_label(_("Copy Report"));
            copy_button.add_css_class("pill");
            copy_button.clicked.connect(copy_report);
            footer.append(copy_button);
            if (app != null) {
                var reopen = new Button.with_label(_("Reopen"));
                reopen.add_css_class("pill");
                reopen.add_css_class("suggested-action");
                reopen.clicked.connect(() => {
                    Reporter.get_default().reopen(report);
                    close_dialog();
                });
                footer.append(reopen);
            }
            content_box.append(footer);

            load_backtrace.begin();
        }

        private static string source_title(SourceKind kind) {
            switch (kind) {
                case SourceKind.HANDLER: return _("Singularity crash handler");
                case SourceKind.COREDUMPCTL: return _("systemd-coredump");
                default: return _("App launcher");
            }
        }

        private void add_info(PreferencesGroup group, string title, string value) {
            if (value == "") return;
            var row = new ActionRow(title, null);
            row.activatable = false;
            var label = new Label(value);
            label.selectable = true;
            label.wrap = true;
            label.wrap_mode = Pango.WrapMode.WORD_CHAR;
            label.xalign = 1;
            label.max_width_chars = 40;
            label.add_css_class("dim-label");
            row.add_suffix(label);
            group.add_row(row);
        }

        private async void load_backtrace() {
            if (report.backtrace == "") {
                spinner.spinning = true;
                backtrace_status.label = _("Reading the crash data...");
                yield Symbolizer.fill(report, config);
                spinner.spinning = false;
            }
            spinner.visible = false;
            if (report.backtrace != "") {
                backtrace_view.buffer.text = report.backtrace;
                backtrace_status.label = _("Made with %s.").printf(report.backtrace_tool);
                return;
            }
            trace_scroll.visible = false;
            if (report.source == SourceKind.LAUNCHER) {
                backtrace_status.label = _("No crash data was saved. Your distribution can turn on the Singularity crash handler or systemd-coredump to get backtraces.");
            } else if (Environment.find_program_in_path("gdb") == null && Environment.find_program_in_path("eu-stack") == null) {
                backtrace_status.label = _("Install gdb or elfutils to read the crash data.");
            } else {
                backtrace_status.label = _("The crash data could not be read.");
            }
        }

        private void copy_report() {
            get_clipboard().set_text(report.to_text());
            copy_button.label = _("Copied");
            Timeout.add(1500, () => {
                copy_button.label = _("Copy Report");
                return Source.REMOVE;
            });
        }

        private void open_bug_tracker() {
            var launcher = new UriLauncher(report.bug_url);
            launcher.launch.begin(this, null, (obj, res) => {
                try {
                    launcher.launch.end(res);
                } catch (Error e) {
                    warning("Crash reporter: cannot open %s: %s", report.bug_url, e.message);
                }
            });
        }
    }
}
