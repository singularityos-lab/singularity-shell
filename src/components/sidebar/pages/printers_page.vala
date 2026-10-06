using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class PrinterListRow : PreferencesRow {
        public signal void activated();
        public Print.PrinterCard card { get; private set; }

        public PrinterListRow(Print.Printer printer) {
            Object();
            var box = new Box(Orientation.HORIZONTAL, 12);
            box.margin_top = 10;
            box.margin_bottom = 10;
            box.margin_start = 12;
            box.margin_end = 12;
            card = new Print.PrinterCard(printer, 48);
            card.hexpand = true;
            box.append(card);
            var chevron = new Image.from_icon_name("go-next-symbolic");
            chevron.pixel_size = 12;
            chevron.add_css_class("dim-label");
            chevron.valign = Align.CENTER;
            box.append(chevron);
            child = box;
            activatable = true;
            set_data<string>("settings-title", printer.display_name);
            set_data<string>("settings-subtitle", printer.status_text());
            var gesture = new GestureClick();
            gesture.released.connect(() => activated());
            add_controller(gesture);
        }

        public override void activate() {
            activated();
        }

        public void update(Print.Printer printer) {
            card.update(printer);
            set_data<string>("settings-title", printer.display_name);
            set_data<string>("settings-subtitle", printer.status_text());
        }
    }

    public class PrintersUi : Object {

        private static Gee.HashMap<string, Gee.ArrayList<Print.Marker>>? device_markers;
        private static Gee.HashMap<string, int64?>? device_checked;
        private static Gee.HashMap<string, int64?>? reach_checked;
        private static Gee.HashSet<string>? unreachable;
        private static Gee.HashSet<string>? probing;

        public static void mark_reachability(Print.Printer p) {
            string uri = p.device_uri;
            if (p.offline || !(uri.has_prefix("ipp://") || uri.has_prefix("ipps://"))) return;
            bool stuck = p.state == 4 && p.state_message != "";
            if (!stuck) return;
            if (reach_checked == null) {
                reach_checked = new Gee.HashMap<string, int64?>();
                unreachable = new Gee.HashSet<string>();
                probing = new Gee.HashSet<string>();
            }
            if (unreachable.contains(uri)) {
                string[] reasons = p.state_reasons;
                reasons += "offline-report";
                p.state_reasons = reasons;
            }
            int64 now = get_monotonic_time();
            if (probing.contains(uri) || (reach_checked.has_key(uri) && now - reach_checked[uri] < 20 * 1000000)) return;
            probing.add(uri);
            reach_checked[uri] = now;
            check_reachable.begin(uri);
        }

        private static async void check_reachable(string uri) {
            try {
                yield Print.PrinterBackend.get_default().probe(uri);
                unreachable.remove(uri);
            } catch (Error e) {
                if (e is Print.PrintError.UNREACHABLE) unreachable.add(uri);
                else unreachable.remove(uri);
            }
            probing.remove(uri);
        }

        public static string error_text(Error e) {
            if (e is Print.PrintError.NOT_AUTHORIZED) {
                string detail = e.message.strip();
                return detail != ""
                    ? _("Only administrators can change printers. %s").printf(detail)
                    : _("Only administrators can change printers.");
            }
            if (e is Print.PrintError.UNREACHABLE)
                return _("The print service does not answer. Check that it is running, then try again.");
            return e.message;
        }

        public static string error_title(Error e) {
            if (e is Print.PrintError.NOT_AUTHORIZED) return _("Not Allowed");
            if (e is Print.PrintError.UNREACHABLE) return _("Print Service Unavailable");
            return _("Something Went Wrong");
        }

        public static async void fill_markers(Print.Printer printer) {
            if (printer.markers.size > 0) return;
            if (device_markers == null) {
                device_markers = new Gee.HashMap<string, Gee.ArrayList<Print.Marker>>();
                device_checked = new Gee.HashMap<string, int64?>();
            }
            string key = printer.device_uri;
            if (key == "") return;
            int64 now = get_monotonic_time();
            if (device_checked.has_key(key) && now - device_checked[key] < 60 * 1000000) {
                if (device_markers.has_key(key)) printer.markers = device_markers[key];
                return;
            }
            device_checked[key] = now;
            yield Print.PrinterBackend.get_default().fill_markers(printer);
            if (printer.markers.size > 0) device_markers[key] = printer.markers;
            else device_markers.unset(key);
        }

        public static void open_queue(string printer_name) {
            Bus.get.begin(BusType.SESSION, null, (obj, res) => {
                try {
                    var conn = Bus.get.end(res);
                    var args = new VariantBuilder(new VariantType("av"));
                    args.add("v", new Variant.string(printer_name));
                    conn.call.begin(Print.JobWatcher.SERVICE_ID, Print.JobWatcher.SERVICE_PATH, "org.gtk.Actions",
                                    "Activate", new Variant("(s@av@a{sv})", "open-queue", args.end(),
                                                            new VariantBuilder(VariantType.VARDICT).end()),
                                    null, DBusCallFlags.NONE, 10000, null, (o, r) => {
                        try {
                            conn.call.end(r);
                        } catch (Error e) {
                            spawn_queue(printer_name);
                        }
                    });
                } catch (Error e) {
                    spawn_queue(printer_name);
                }
            });
        }

        private static void spawn_queue(string printer_name) {
            string? exe = Environment.find_program_in_path("singularity-printers");
            if (exe == null) {
                warning("printers: the Printers app is not installed");
                return;
            }
            try {
                Process.spawn_async(null, { exe, "--queue", printer_name }, null, SpawnFlags.SEARCH_PATH, null, null);
            } catch (SpawnError e) {
                warning("printers: %s", e.message);
            }
        }

        public static string job_time(int64 when) {
            if (when <= 0) return "";
            var t = new DateTime.from_unix_local(when);
            var now = new DateTime.now_local();
            if (t.get_year() == now.get_year() && t.get_day_of_year() == now.get_day_of_year())
                return t.format("%H:%M");
            return t.format("%x");
        }

        public static string job_summary(Print.JobInfo job, string? blocked = null) {
            string[] parts = {};
            if (blocked != null && !job.state.finished())
                parts += _("Waiting: %s").printf(blocked);
            else if (job.state == Print.JobState.PROCESSING && job.pages_total > 0)
                parts += _("Printing page %d of %d").printf(int.max(1, job.pages_done), job.pages_total);
            else
                parts += job.state.label();
            if (job.state == Print.JobState.ABORTED && job.state_message != "") parts += job.state_message;
            if (job.state.finished() && job.pages_done > 0 && job.state == Print.JobState.COMPLETED)
                parts += ngettext("%d page", "%d pages", job.pages_done).printf(job.pages_done);
            string when = job_time(job.state.finished() && job.completed > 0 ? job.completed : job.created);
            if (when != "") parts += when;
            if (job.user != "" && job.user != Environment.get_user_name()) parts += job.user;
            return string.joinv(", ", parts);
        }

        public static string job_icon(Print.JobInfo job) {
            switch (job.state) {
                case Print.JobState.COMPLETED: return "emblem-ok-symbolic";
                case Print.JobState.ABORTED: return "dialog-error-symbolic";
                case Print.JobState.CANCELED: return "action-unavailable-symbolic";
                case Print.JobState.HELD: return "media-playback-pause-symbolic";
                case Print.JobState.STOPPED: return "dialog-warning-symbolic";
                default: return "document-print-symbolic";
            }
        }

        public static Button round_button(string icon_name, string tooltip) {
            var btn = new Button.from_icon_name(icon_name);
            btn.add_css_class("flat");
            btn.add_css_class("circular");
            btn.valign = Align.CENTER;
            btn.tooltip_text = tooltip;
            btn.update_property(AccessibleProperty.LABEL, tooltip, -1);
            return btn;
        }
    }

    public class PrintersPage : SettingsPage {
        private SettingsView view;
        private Print.PrinterBackend backend;
        private Banner banner;
        private StatusPage unavailable;
        private WelcomePage welcome;
        private PreferencesGroup printers_group;
        private Button add_btn;
        private Gee.HashMap<string, PrinterListRow> rows = new Gee.HashMap<string, PrinterListRow>();
        private string[] order = {};
        private uint refresh_id;
        private bool loading;
        private ulong changed_handler;

        public PrintersPage(SettingsView view) {
            base(_("Printers"));
            this.view = view;
            backend = Print.PrinterBackend.get_default();
            back_clicked.connect(() => view.go_home());

            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            header.append(spacer);
            add_btn = new Button();
            var add_box = new Box(Orientation.HORIZONTAL, 6);
            add_box.append(new Image.from_icon_name("list-add-symbolic"));
            add_box.append(new Label(_("Add Printer…")));
            add_btn.child = add_box;
            add_btn.valign = Align.CENTER;
            add_btn.tooltip_text = _("Add a printer from your network or by its address");
            add_btn.visible = can_add();
            add_btn.clicked.connect(() => open_add(false));
            header.append(add_btn);

            banner = new Banner("", BannerStyle.ERROR);
            banner.icon_name = "dialog-warning-symbolic";
            banner.margin_top = 12;
            banner.visible = false;
            add_widget(banner);

            unavailable = new StatusPage();
            unavailable.icon_name = "printer";
            unavailable.title = _("Print Service Unavailable");
            unavailable.visible = false;
            var retry = new Button.with_label(_("Try Again"));
            retry.add_css_class("pill");
            retry.halign = Align.CENTER;
            retry.clicked.connect(() => refresh.begin());
            unavailable.child = retry;
            add_widget(unavailable);

            welcome = new WelcomePage();
            welcome.is_section = true;
            welcome.embedded = true;
            welcome.compact = true;
            welcome.app_icon_name = "dev.sinty.Printers";
            welcome.title = _("No Printers Yet");
            welcome.subtitle = _("Add a printer to print from every app. Modern printers work without installing drivers.");
            if (backend.can(Print.BackendFeature.ADD_DISCOVERED))
                welcome.add_action("printer-network", _("Add a Nearby Printer"),
                    _("Printers on your network or connected by cable"), () => open_add(false));
            if (backend.can(Print.BackendFeature.ADD_URI))
                welcome.add_action("printer", _("Add by Address"),
                    _("Enter the address or host name of a network printer"), () => open_add(true));
            welcome.visible = false;
            add_widget(welcome);

            printers_group = new PreferencesGroup(_("Your Printers"),
                _("Select a printer to see its supplies, waiting documents and options."));
            printers_group.visible = false;
            add_group(printers_group);

            if (can_add()) {
                add_search_action(_("Add Printer"), _("Printer, scanner, IPP, AirPrint, network printer"),
                    () => open_add(false));
            }
            add_search_action(_("Printer Supplies and Queues"), _("Ink, toner, paper, documents waiting, cancel printing"),
                () => {});

            changed_handler = backend.printers_changed.connect(() => refresh.begin());
            destroy.connect(() => {
                backend.disconnect(changed_handler);
                stop_refresh();
            });
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

        private bool can_add() {
            return backend.can(Print.BackendFeature.ADD_URI) || backend.can(Print.BackendFeature.ADD_DISCOVERED);
        }

        private void stop_refresh() {
            if (refresh_id != 0) {
                Source.remove(refresh_id);
                refresh_id = 0;
            }
        }

        public void show_error(Error e) {
            banner.title = PrintersUi.error_text(e);
            banner.visible = true;
        }

        private void open_add(bool address) {
            var page = new AddPrinterPage(view, address);
            view.open_subpage(page, "add-printer");
        }

        private void open_printer(string name) {
            var page = new PrinterDetailPage(view, name);
            view.open_subpage(page, "printer-detail");
        }

        public async void refresh() {
            if (loading) return;
            loading = true;
            Gee.List<Print.Printer> list;
            try {
                list = yield backend.list_printers();
            } catch (Error e) {
                loading = false;
                unavailable.description = PrintersUi.error_text(e);
                unavailable.visible = true;
                welcome.visible = false;
                printers_group.visible = false;
                add_btn.visible = false;
                return;
            }
            foreach (var p in list) {
                yield PrintersUi.fill_markers(p);
                PrintersUi.mark_reachability(p);
            }
            loading = false;
            unavailable.visible = false;
            welcome.visible = list.size == 0;
            printers_group.visible = list.size > 0;
            add_btn.visible = can_add() && list.size > 0;

            string[] names = {};
            foreach (var p in list) names += p.name;
            if (string.joinv("\n", names) != string.joinv("\n", order)) {
                printers_group.clear();
                rows.clear();
                foreach (var p in list) {
                    var row = new PrinterListRow(p);
                    string name = p.name;
                    row.activated.connect(() => open_printer(name));
                    printers_group.add_row(row);
                    rows[p.name] = row;
                }
                order = names;
            } else {
                foreach (var p in list) {
                    if (rows.has_key(p.name)) rows[p.name].update(p);
                }
            }
        }
    }
}
