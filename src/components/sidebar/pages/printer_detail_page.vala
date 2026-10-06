using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PrinterDetailPage : SettingsPage {
        private SettingsView view;
        private Print.PrinterBackend backend;
        private string printer_name;
        private Print.Printer? printer;
        private Print.PrinterCapabilities? caps;
        private uint refresh_id;
        private bool loading;
        private bool options_built;
        private bool syncing;

        private Banner error_banner;
        private Banner state_banner;
        private Box body;
        private Box groups_box;
        private Spinner loading_spinner;
        private Image hero_icon;
        private Label hero_name;
        private Box hero_dot;
        private Label hero_status;
        private Image hero_star;
        private Label hero_make;
        private Label hero_uri;
        private Label hero_location;

        private PreferencesGroup supplies_group;
        private Print.InkLevels inks;
        private ActionRow no_levels_row;
        private ActionRow low_row;
        private PreferencesGroup queue_group;
        private string queue_signature = "";
        private PreferencesGroup? history_group;
        private string history_signature = "";
        private ActionRow? default_row;
        private Button? default_btn;
        private Box? default_badge;
        private ActionRow? pause_row;
        private Button? pause_btn;
        private Button? test_btn;
        private EntryRow? name_row;
        private EntryRow? location_row;
        private Button? save_btn;
        private SwitchRow? share_row;
        private PreferencesGroup? options_group;

        public PrinterDetailPage(SettingsView view, string printer_name) {
            base(printer_name.replace("_", " "));
            this.view = view;
            this.printer_name = printer_name;
            backend = Print.PrinterBackend.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => view.navigate_to("printers"));

            error_banner = new Banner("", BannerStyle.ERROR);
            error_banner.icon_name = "dialog-warning-symbolic";
            error_banner.secondary_label = _("Dismiss");
            error_banner.secondary_clicked.connect(() => error_banner.visible = false);
            error_banner.margin_top = 12;
            error_banner.visible = false;
            add_widget(error_banner);

            body = new Box(Orientation.VERTICAL, 0);
            add_widget(body);
            body.append(build_hero());

            state_banner = new Banner("", BannerStyle.WARNING);
            state_banner.margin_top = 12;
            state_banner.visible = false;
            state_banner.button_clicked.connect(() => {
                if (printer != null && printer.status == Print.PrinterStatus.PAUSED) set_paused.begin(false);
                else refresh.begin();
            });
            body.append(state_banner);
            loading_spinner = new Spinner();
            loading_spinner.spinning = true;
            loading_spinner.halign = Align.CENTER;
            loading_spinner.margin_top = 48;
            loading_spinner.set_size_request(32, 32);
            body.append(loading_spinner);
            groups_box = new Box(Orientation.VERTICAL, 0);
            groups_box.visible = false;
            body.append(groups_box);

            build_actions();
            build_supplies();
            build_queue();
            if (backend.can(Print.BackendFeature.COMPLETED_JOBS)) build_history();
            if (backend.can(Print.BackendFeature.EDIT_INFO)) build_info();
            if (backend.can(Print.BackendFeature.DEFAULT_OPTIONS)) {
                options_group = new PreferencesGroup(_("Default Options"),
                    _("Used when an app does not choose its own settings."));
                options_group.visible = false;
                add_body(options_group);
            }
            if (backend.can(Print.BackendFeature.SHARE)) build_share();
            if (backend.can(Print.BackendFeature.REMOVE)) build_remove();

            destroy.connect(() => stop_refresh());
            map.connect(() => {
                refresh.begin();
                if (refresh_id == 0) {
                    refresh_id = Timeout.add_seconds(3, () => {
                        refresh.begin();
                        return Source.CONTINUE;
                    });
                }
            });
            unmap.connect(() => stop_refresh());
        }

        private void stop_refresh() {
            if (refresh_id != 0) {
                Source.remove(refresh_id);
                refresh_id = 0;
            }
        }

        private void add_body(Widget w) {
            w.margin_top = 12;
            groups_box.append(w);
        }

        private void show_error(Error e) {
            error_banner.title = "%s. %s".printf(PrintersUi.error_title(e), PrintersUi.error_text(e));
            error_banner.visible = true;
        }

        private void set_page_title(string text) {
            for (Widget? c = header.get_first_child(); c != null; c = c.get_next_sibling()) {
                var l = c as Label;
                if (l != null && l.has_css_class("page-title")) l.label = text;
            }
        }

        private Widget build_hero() {
            var box = new Box(Orientation.HORIZONTAL, 16);
            box.margin_top = 12;
            box.margin_start = 12;
            box.margin_end = 12;
            hero_icon = new Image.from_icon_name("printer");
            hero_icon.pixel_size = 80;
            hero_icon.valign = Align.CENTER;
            box.append(hero_icon);
            var text = new Box(Orientation.VERTICAL, 3);
            text.valign = Align.CENTER;
            text.hexpand = true;
            var name_line = new Box(Orientation.HORIZONTAL, 8);
            hero_name = new Label(printer_name.replace("_", " "));
            hero_name.add_css_class("title-3");
            hero_name.xalign = 0;
            hero_name.ellipsize = Pango.EllipsizeMode.END;
            name_line.append(hero_name);
            hero_star = new Image.from_icon_name("starred-symbolic");
            hero_star.add_css_class("print-default-star");
            hero_star.tooltip_text = _("Default Printer");
            hero_star.visible = false;
            name_line.append(hero_star);
            text.append(name_line);
            var status_line = new Box(Orientation.HORIZONTAL, 6);
            hero_dot = new Box(Orientation.HORIZONTAL, 0);
            hero_dot.add_css_class("print-status-dot");
            hero_dot.valign = Align.CENTER;
            hero_dot.set_size_request(8, 8);
            status_line.append(hero_dot);
            hero_status = new Label("");
            hero_status.xalign = 0;
            hero_status.ellipsize = Pango.EllipsizeMode.END;
            status_line.append(hero_status);
            text.append(status_line);
            hero_make = new Label("");
            hero_make.add_css_class("dim-label");
            hero_make.xalign = 0;
            hero_make.ellipsize = Pango.EllipsizeMode.END;
            text.append(hero_make);
            hero_location = new Label("");
            hero_location.add_css_class("caption");
            hero_location.add_css_class("dim-label");
            hero_location.xalign = 0;
            hero_location.ellipsize = Pango.EllipsizeMode.END;
            text.append(hero_location);
            hero_uri = new Label("");
            hero_uri.add_css_class("caption");
            hero_uri.add_css_class("dim-label");
            hero_uri.xalign = 0;
            hero_uri.selectable = true;
            hero_uri.ellipsize = Pango.EllipsizeMode.MIDDLE;
            text.append(hero_uri);
            box.append(text);
            return box;
        }

        private void build_supplies() {
            supplies_group = new PreferencesGroup(_("Supplies"));
            var holder = new Box(Orientation.VERTICAL, 0);
            holder.margin_top = 12;
            holder.margin_bottom = 12;
            holder.margin_start = 14;
            holder.margin_end = 14;
            inks = new Print.InkLevels(true);
            holder.append(inks);
            var row = new ListBoxRow();
            row.activatable = false;
            row.child = holder;
            supplies_group.add_row(row);
            no_levels_row = new ActionRow(_("Levels Appear After the First Job"),
                _("The printer reports its ink or toner once it has printed something."), "printer-symbolic");
            no_levels_row.activatable = false;
            no_levels_row.visible = false;
            supplies_group.add_row(no_levels_row);
            low_row = new ActionRow("", _("Replace it soon to keep printing."), "dialog-warning-symbolic");
            low_row.activatable = false;
            low_row.visible = false;
            supplies_group.add_row(low_row);
            add_body(supplies_group);
        }

        private void build_queue() {
            queue_group = new PreferencesGroup(_("Waiting to Print"));
            var open = new Button.with_label(_("Open Queue"));
            open.valign = Align.CENTER;
            open.tooltip_text = _("Show this printer's queue in its own window");
            open.clicked.connect(() => PrintersUi.open_queue(printer_name));
            queue_group.add_header_suffix(open);
            add_body(queue_group);
        }

        private void build_history() {
            history_group = new PreferencesGroup(_("Recently Printed"));
            add_body(history_group);
        }

        private void build_actions() {
            var group = new PreferencesGroup(_("Printing"));
            if (backend.can(Print.BackendFeature.SET_DEFAULT)) {
                default_row = new ActionRow(_("Default Printer"), "", "starred-symbolic");
                default_row.activatable = false;
                default_btn = new Button.with_label(_("Make Default"));
                default_btn.valign = Align.CENTER;
                default_btn.clicked.connect(() => make_default.begin());
                default_row.add_suffix(default_btn);
                default_badge = new Box(Orientation.HORIZONTAL, 6);
                default_badge.valign = Align.CENTER;
                var star = new Image.from_icon_name("starred-symbolic");
                star.add_css_class("print-default-star");
                default_badge.append(star);
                var lbl = new Label(_("Default"));
                lbl.add_css_class("dim-label");
                default_badge.append(lbl);
                default_badge.visible = false;
                default_row.add_suffix(default_badge);
                group.add_row(default_row);
            }
            if (backend.can(Print.BackendFeature.PAUSE)) {
                pause_row = new ActionRow(_("Pause Printing"), "", "media-playback-pause-symbolic");
                pause_row.activatable = false;
                pause_btn = new Button.with_label(_("Pause"));
                pause_btn.valign = Align.CENTER;
                pause_btn.clicked.connect(() => {
                    if (printer != null) set_paused.begin(printer.status != Print.PrinterStatus.PAUSED);
                });
                pause_row.add_suffix(pause_btn);
                group.add_row(pause_row);
            }
            var test_row = new ActionRow(_("Print a Test Page"),
                _("Checks colours, alignment and the connection"), "document-print-symbolic");
            test_row.activatable = false;
            test_btn = new Button.with_label(_("Print"));
            test_btn.valign = Align.CENTER;
            test_btn.clicked.connect(() => print_test_page.begin());
            test_row.add_suffix(test_btn);
            group.add_row(test_row);
            add_body(group);
        }

        private void build_info() {
            var group = new PreferencesGroup(_("Name and Location"),
                _("How the printer appears in the print dialog of every app."));
            save_btn = new Button.with_label(_("Save"));
            save_btn.add_css_class("suggested-action");
            save_btn.valign = Align.CENTER;
            save_btn.sensitive = false;
            save_btn.clicked.connect(() => save_info.begin());
            group.add_header_suffix(save_btn);
            name_row = new EntryRow(_("Name"));
            name_row.entry_changed.connect(() => info_changed());
            name_row.entry_activated.connect(() => save_info.begin());
            group.add_row(name_row);
            location_row = new EntryRow(_("Location"));
            location_row.entry_changed.connect(() => info_changed());
            location_row.entry_activated.connect(() => save_info.begin());
            group.add_row(location_row);
            add_body(group);
        }

        private void info_changed() {
            if (printer == null || save_btn == null) return;
            save_btn.sensitive = name_row.text.strip() != ""
                && (name_row.text.strip() != printer.display_name || location_row.text.strip() != printer.location);
        }

        private void build_share() {
            var group = new PreferencesGroup(_("Sharing"));
            share_row = new SwitchRow(_("Share on the Network"),
                _("Other computers on your network can print to this printer"), false);
            share_row.icon_name = "network-workgroup-symbolic";
            share_row.switch_btn.notify["active"].connect(() => {
                if (syncing || printer == null || share_row.active == printer.shared) return;
                set_shared.begin(share_row.active);
            });
            group.add_row(share_row);
            add_body(group);
        }

        private void build_remove() {
            var group = new PreferencesGroup(_("Remove Printer"),
                _("Removes the printer from this computer. Documents waiting for it are cancelled. You can add it again at any time."));
            var row = new ActionRow(_("Remove from This Computer"), _("Apps no longer offer it for printing"), "user-trash-symbolic");
            row.activatable = false;
            var remove = new Button.with_label(_("Remove…"));
            remove.add_css_class("destructive-action");
            remove.valign = Align.CENTER;
            remove.clicked.connect(() => confirm_remove());
            row.add_suffix(remove);
            group.add_row(row);
            add_body(group);
        }

        private void confirm_remove() {
            var app = GLib.Application.get_default() as Gtk.Application;
            if (app == null) return;
            string shown = printer != null ? printer.display_name : printer_name;
            var dlg = new ConfirmDialog(app, _("Remove “%s”?").printf(shown),
                printer != null ? printer.icon_name : "printer",
                _("Documents waiting for this printer are cancelled. You can add the printer again later."),
                _("Remove"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) remove_printer.begin();
            });
            dlg.present();
        }

        private async void remove_printer() {
            var ticket = SidebarWait.get_default().begin(this, _("Removing the printer"), "printer-symbolic");
            try {
                yield backend.remove_printer(printer_name);
            } catch (Error e) {
                ticket.end();
                show_error(e);
                return;
            }
            ticket.end_quietly();
            stop_refresh();
            view.navigate_to("printers");
        }

        private async void make_default() {
            default_btn.sensitive = false;
            try {
                yield backend.set_default(printer_name);
            } catch (Error e) {
                show_error(e);
            }
            default_btn.sensitive = true;
            yield refresh();
        }

        private async void set_paused(bool paused) {
            if (pause_btn != null) pause_btn.sensitive = false;
            try {
                yield backend.set_paused(printer_name, paused);
            } catch (Error e) {
                show_error(e);
            }
            if (pause_btn != null) pause_btn.sensitive = true;
            yield refresh();
        }

        private async void set_shared(bool shared) {
            try {
                yield backend.set_shared(printer_name, shared);
            } catch (Error e) {
                show_error(e);
                syncing = true;
                share_row.active = !shared;
                syncing = false;
            }
            yield refresh();
        }

        private async void save_info() {
            if (printer == null || save_btn == null || !save_btn.sensitive) return;
            save_btn.sensitive = false;
            try {
                yield backend.set_info(printer_name, name_row.text.strip(), location_row.text.strip());
            } catch (Error e) {
                show_error(e);
                save_btn.sensitive = true;
                return;
            }
            printer = null;
            yield refresh();
        }

        private async void print_test_page() {
            if (printer == null) return;
            test_btn.sensitive = false;
            var ticket = SidebarWait.get_default().begin(this, _("Sending a test page"), "document-print-symbolic");
            string path = Path.build_filename(Environment.get_tmp_dir(),
                "singularity-test-page-%s.pdf".printf(Uuid.string_random()));
            try {
                Print.TestPage.write(printer, path);
                int id = yield backend.submit(printer_name, path, _("Test Page"), new Print.JobOptions(), null);
                Print.JobWatcher.get_default().watch(printer, id, _("Test Page"));
                ticket.end_quietly();
            } catch (Error e) {
                ticket.end();
                show_error(e);
            }
            FileUtils.unlink(path);
            test_btn.sensitive = true;
            yield refresh();
        }

        public async void refresh() {
            if (loading) return;
            loading = true;
            Print.Printer? p = null;
            try {
                p = yield backend.get_printer(printer_name);
            } catch (Error e) {
                loading = false;
                if (e is Print.PrintError.NOT_FOUND || e.message.contains("not-found") || e.message.contains("does not exist")) {
                    stop_refresh();
                    view.navigate_to("printers");
                    return;
                }
                state_banner.style = BannerStyle.ERROR;
                state_banner.icon_name = "dialog-warning-symbolic";
                state_banner.title = PrintersUi.error_text(e);
                state_banner.button_label = _("Try Again");
                state_banner.visible = true;
                return;
            }
            if (p == null) {
                loading = false;
                stop_refresh();
                view.navigate_to("printers");
                return;
            }
            yield PrintersUi.fill_markers(p);
            PrintersUi.mark_reachability(p);
            bool first = printer == null;
            printer = p;
            update_printer(first);
            yield update_jobs();
            if (!options_built && options_group != null) yield build_options();
            loading_spinner.spinning = false;
            loading_spinner.visible = false;
            groups_box.visible = true;
            loading = false;
        }

        private void update_printer(bool first) {
            var p = printer;
            set_page_title(p.display_name);
            hero_icon.icon_name = p.icon_name;
            hero_name.label = p.display_name;
            hero_star.visible = p.is_default;
            hero_status.label = p.status_text();
            foreach (var c in new string[] {"ready", "printing", "paused", "offline", "attention", "low"})
                hero_dot.remove_css_class(c);
            hero_dot.add_css_class(p.status == Print.PrinterStatus.READY && p.low_supplies ? "low" : p.status.css_class());
            hero_make.label = p.make_model;
            hero_make.visible = p.make_model != "";
            hero_location.label = p.location;
            hero_location.visible = p.location != "";
            hero_uri.label = p.device_uri;
            hero_uri.visible = p.device_uri != "";
            update_state_banner();

            bool known = false;
            foreach (var m in p.markers) if (m.known) known = true;
            inks.set_markers(p.markers);
            inks.visible = p.markers.size > 0;
            for (Widget? c = inks.get_parent(); c != null; c = c.get_parent()) {
                if (c is ListBoxRow) {
                    c.visible = p.markers.size > 0;
                    break;
                }
            }
            no_levels_row.visible = !known;
            string low = p.low_supplies ? Print.PrintMonitor.low_supply_text(p) : "";
            low_row.title = low;
            low_row.visible = low != "";

            if (default_row != null) {
                default_row.subtitle = p.is_default ? _("Apps choose this printer first") : _("Make apps choose this printer first");
                default_btn.visible = !p.is_default;
                default_badge.visible = p.is_default;
            }
            if (pause_row != null) {
                bool paused = p.status == Print.PrinterStatus.PAUSED;
                pause_row.title = paused ? _("Printing Is Paused") : _("Pause Printing");
                pause_row.subtitle = paused ? _("Documents wait in the queue until you resume")
                                            : _("Stop sending documents to the printer for now");
                pause_row.icon_name = paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
                pause_btn.label = paused ? _("Resume") : _("Pause");
                if (paused) pause_btn.add_css_class("suggested-action");
                else pause_btn.remove_css_class("suggested-action");
            }
            if (share_row != null) {
                syncing = true;
                share_row.active = p.shared;
                syncing = false;
            }
            if (name_row != null && (first || save_btn.sensitive == false)) {
                if (!name_row.has_focus && name_row.text != p.display_name) name_row.text = p.display_name;
                if (!location_row.has_focus && location_row.text != p.location) location_row.text = p.location;
                save_btn.sensitive = false;
            }
        }

        private void update_state_banner() {
            var p = printer;
            state_banner.button_label = null;
            if (p.offline) {
                state_banner.style = BannerStyle.WARNING;
                state_banner.icon_name = "network-offline-symbolic";
                state_banner.title = _("Printer offline. Nothing answers at %s. Check that it is turned on and connected; waiting documents print when it is back.").printf(p.device_uri);
                state_banner.button_label = _("Check Again");
                state_banner.visible = true;
            } else if (p.status == Print.PrinterStatus.PAUSED) {
                state_banner.style = BannerStyle.INFO;
                state_banner.icon_name = "media-playback-pause-symbolic";
                state_banner.title = _("Printing is paused. Documents wait in the queue until you resume.");
                if (backend.can(Print.BackendFeature.PAUSE)) state_banner.button_label = _("Resume");
                state_banner.visible = true;
            } else if (p.attention_reason() != null) {
                state_banner.style = BannerStyle.ERROR;
                state_banner.icon_name = "dialog-warning-symbolic";
                state_banner.title = _("%s. Fix it on the printer and printing continues by itself.").printf(p.attention_reason());
                state_banner.visible = true;
            } else if (p.status == Print.PrinterStatus.REJECTING) {
                state_banner.style = BannerStyle.WARNING;
                state_banner.icon_name = "dialog-warning-symbolic";
                state_banner.title = _("The printer does not accept new documents right now.");
                state_banner.visible = true;
            } else {
                state_banner.visible = false;
            }
        }

        private async void update_jobs() {
            Gee.List<Print.JobInfo> active;
            try {
                active = yield backend.list_jobs(printer_name, false);
            } catch (Error e) {
                active = new Gee.ArrayList<Print.JobInfo>();
            }
            var unfinished = new Gee.ArrayList<Print.JobInfo>();
            foreach (var j in active) if (!j.state.finished()) unfinished.add(j);
            active = unfinished;
            string sig = "n%d;%s;".printf(active.size, blocked_reason() ?? "");
            foreach (var j in active) sig += "%d:%d:%d:%d;".printf(j.id, (int) j.state, j.pages_done, j.pages_total);
            if (sig != queue_signature || queue_group.get_rows().size == 0) {
                queue_signature = sig;
                queue_group.clear();
                if (active.size == 0) {
                    var empty = new ActionRow(_("Nothing Waiting"),
                        _("Documents you print appear here until they are done"), "document-print-symbolic");
                    empty.activatable = false;
                    queue_group.add_row(empty);
                }
                foreach (var j in active) queue_group.add_row(job_row(j, true));
            }

            if (history_group == null) return;
            Gee.List<Print.JobInfo> done;
            try {
                done = yield backend.list_jobs(printer_name, true);
            } catch (Error e) {
                done = new Gee.ArrayList<Print.JobInfo>();
            }
            string hsig = "n%d;".printf(done.size);
            int n = 0;
            foreach (var j in done) {
                if (n++ >= 5) break;
                hsig += "%d:%d;".printf(j.id, (int) j.state);
            }
            if (hsig == history_signature && history_group.get_rows().size > 0) return;
            history_signature = hsig;
            history_group.clear();
            if (done.size == 0) {
                var empty = new ActionRow(_("Nothing Printed Yet"),
                    _("Finished and cancelled documents are listed here"), "document-open-recent-symbolic");
                empty.activatable = false;
                history_group.add_row(empty);
                return;
            }
            n = 0;
            foreach (var j in done) {
                if (n++ >= 5) break;
                history_group.add_row(job_row(j, false));
            }
        }

        private string? blocked_reason() {
            if (printer == null) return null;
            if (printer.offline) return _("Printer offline");
            return printer.attention_reason();
        }

        private Widget job_row(Print.JobInfo job, bool active) {
            var row = new ActionRow(job.title, PrintersUi.job_summary(job, active ? blocked_reason() : null),
                                    PrintersUi.job_icon(job));
            row.activatable = false;
            if (!active) return row;
            int id = job.id;
            if (backend.can(Print.BackendFeature.HOLD_JOBS)) {
                bool held = job.state == Print.JobState.HELD;
                var hold = PrintersUi.round_button(held ? "media-playback-start-symbolic" : "media-playback-pause-symbolic",
                                                   held ? _("Resume Document") : _("Hold Document"));
                hold.clicked.connect(() => job_action.begin(id, held ? 2 : 1));
                row.add_suffix(hold);
            }
            var cancel = PrintersUi.round_button("process-stop-symbolic", _("Cancel Printing"));
            cancel.clicked.connect(() => job_action.begin(id, 0));
            row.add_suffix(cancel);
            return row;
        }

        private async void job_action(int id, int kind) {
            try {
                if (kind == 0) yield backend.cancel_job(id);
                else if (kind == 1) yield backend.hold_job(id);
                else yield backend.release_job(id);
            } catch (Error e) {
                show_error(e);
            }
            queue_signature = "";
            history_signature = "";
            yield refresh();
        }

        private async void build_options() {
            options_built = true;
            try {
                caps = yield backend.capabilities(printer_name);
            } catch (Error e) {
                options_built = false;
                return;
            }
            options_group.clear();
            var media = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            foreach (var m in caps.media) media.add(option(m.keyword, m.label()));
            var paper = new SelectionRow.with_options(_("Paper Size"), media, caps.media_default);
            paper.icon_name = "x-office-document-symbolic";
            paper.selected.connect(() => apply_options.begin());
            paper.set_data<string>("key", "media");
            options_group.add_row(paper);
            if (caps.supports_duplex) {
                var sides = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                sides.add(option("one-sided", _("Off")));
                sides.add(option("two-sided-long-edge", _("Long Edge (Book)")));
                if ("two-sided-short-edge" in caps.sides) sides.add(option("two-sided-short-edge", _("Short Edge (Notepad)")));
                var row = new SelectionRow.with_options(_("Two-Sided"), sides, caps.sides_default);
                row.icon_name = "view-dual-symbolic";
                row.set_data<string>("key", "sides");
                row.selected.connect(() => apply_options.begin());
                options_group.add_row(row);
            }
            if (caps.supports_color) {
                var colors = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                colors.add(option("color", _("Colour")));
                colors.add(option("monochrome", _("Black and White")));
                string current = caps.color_default == "monochrome" ? "monochrome" : "color";
                var row = new SelectionRow.with_options(_("Colour"), colors, current);
                row.icon_name = "applications-graphics-symbolic";
                row.set_data<string>("key", "color");
                row.selected.connect(() => apply_options.begin());
                options_group.add_row(row);
            }
            if (caps.qualities.length > 1) {
                var qualities = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
                foreach (int q in caps.qualities) qualities.add(option(q.to_string(), Print.Options.quality_label(q)));
                var row = new SelectionRow.with_options(_("Quality"), qualities, caps.quality_default.to_string());
                row.icon_name = "image-x-generic-symbolic";
                row.set_data<string>("key", "quality");
                row.selected.connect(() => apply_options.begin());
                options_group.add_row(row);
            }
            options_group.visible = true;
        }

        private static Singularity.Core.AppSettingOption option(string id, string label) {
            var o = new Singularity.Core.AppSettingOption();
            o.id = id;
            o.label = label;
            return o;
        }

        private async void apply_options() {
            if (caps == null) return;
            var opts = new Print.JobOptions();
            opts.media = caps.media_default;
            opts.duplex = Print.Duplex.from_keyword(caps.sides_default);
            opts.grayscale = caps.color_default == "monochrome" || !caps.supports_color;
            opts.quality = caps.quality_default;
            foreach (var w in options_group.get_rows()) {
                var row = w as SelectionRow;
                if (row == null) continue;
                string v = row.current_value;
                switch (row.get_data<string>("key")) {
                    case "media": opts.media = v; break;
                    case "sides": opts.duplex = Print.Duplex.from_keyword(v); break;
                    case "color": opts.grayscale = v == "monochrome"; break;
                    case "quality": opts.quality = int.parse(v); break;
                }
            }
            try {
                yield backend.set_default_options(printer_name, opts);
                caps.media_default = opts.media;
                caps.sides_default = opts.duplex.keyword();
                caps.color_default = opts.grayscale ? "monochrome" : "color";
                caps.quality_default = opts.quality;
            } catch (Error e) {
                show_error(e);
            }
        }
    }
}
