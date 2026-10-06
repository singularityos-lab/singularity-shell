using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AddPrinterPage : SettingsPage {
        private SettingsView view;
        private Print.PrinterBackend backend;
        private Stack inner_stack;
        private Banner banner;
        private PreferencesGroup nearby_group;
        private Button search_btn;
        private EntryRow address_row;
        private Button check_btn;
        private Label address_error;
        private Box confirm_box;
        private Cancellable? discovery;
        private SidebarWaitTicket? discovery_ticket;
        private Gee.List<Print.Printer> existing = new Gee.ArrayList<Print.Printer>();
        private bool focus_address;

        private Print.DiscoveredPrinter? target_device;
        private string target_uri = "";
        private string target_make = "";
        private bool target_driverless = true;
        private Print.PrinterCapabilities? target_caps;
        private Gee.ArrayList<Print.Marker> target_markers = new Gee.ArrayList<Print.Marker>();
        private EntryRow name_row;
        private EntryRow location_row;
        private ActionRow driver_row;
        private Button clear_driver_btn;
        private Print.LegacyDriver? chosen_driver;
        private Gee.List<Print.LegacyDriver>? drivers;
        private Button add_btn;
        private Label confirm_error;

        public AddPrinterPage(SettingsView view, bool focus_address = false) {
            base(_("Add Printer"));
            this.view = view;
            this.focus_address = focus_address;
            backend = Print.PrinterBackend.get_default();
            back_btn.visible = true;
            back_clicked.connect(() => {
                if (inner_stack.visible_child_name == "confirm") {
                    inner_stack.visible_child_name = "choose";
                } else {
                    view.navigate_to("printers");
                }
            });

            banner = new Banner("", BannerStyle.ERROR);
            banner.icon_name = "dialog-warning-symbolic";
            banner.margin_top = 12;
            banner.visible = false;
            add_widget(banner);

            inner_stack = new Stack();
            inner_stack.transition_type = StackTransitionType.CROSSFADE;
            inner_stack.vhomogeneous = false;
            inner_stack.add_named(build_choose(), "choose");
            confirm_box = new Box(Orientation.VERTICAL, 0);
            inner_stack.add_named(confirm_box, "confirm");
            add_widget(inner_stack);

            destroy.connect(() => {
                if (discovery != null) discovery.cancel();
                if (discovery_ticket != null) discovery_ticket.end_quietly();
            });
            map.connect(() => {
                if (this.focus_address && address_row != null) {
                    this.focus_address = false;
                    address_row.grab_focus();
                }
            });
            load_existing.begin(() => {
                if (backend.can(Print.BackendFeature.ADD_DISCOVERED)) search.begin();
            });
        }

        private Widget build_choose() {
            var box = new Box(Orientation.VERTICAL, 0);
            if (backend.can(Print.BackendFeature.ADD_DISCOVERED)) {
                nearby_group = new PreferencesGroup(_("Nearby Printers"),
                    _("Printers on your network or connected by cable. Printers that need no driver come first."));
                search_btn = new Button.with_label(_("Search Again"));
                search_btn.valign = Align.CENTER;
                search_btn.clicked.connect(() => search.begin());
                nearby_group.add_header_suffix(search_btn);
                nearby_group.margin_top = 12;
                box.append(nearby_group);
            }
            if (backend.can(Print.BackendFeature.ADD_URI)) {
                var group = new PreferencesGroup(_("Add by Address"), backend.can(Print.BackendFeature.LEGACY_DRIVER)
                    ? _("Enter an ipp://, ipps://, lpd:// or socket:// address, or just the host name of the printer.")
                    : _("Enter an ipp:// or ipps:// address, or just the host name of the printer."));
                address_row = new EntryRow(_("Printer Address or Host Name"), "network-server-symbolic");
                address_row.entry_activated.connect(() => check.begin());
                address_row.entry_changed.connect(() => {
                    check_btn.sensitive = address_row.text.strip() != "";
                    address_error.visible = false;
                });
                check_btn = new Button.with_label(_("Check"));
                check_btn.add_css_class("suggested-action");
                check_btn.valign = Align.CENTER;
                check_btn.sensitive = false;
                check_btn.clicked.connect(() => check.begin());
                address_row.add_suffix(check_btn);
                group.add_row(address_row);
                group.margin_top = 12;
                box.append(group);
                address_error = new Label("");
                address_error.add_css_class("error");
                address_error.wrap = true;
                address_error.xalign = 0;
                address_error.margin_start = 12;
                address_error.margin_end = 12;
                address_error.visible = false;
                box.append(address_error);
            }
            return box;
        }

        private async void load_existing() {
            try {
                existing = yield backend.list_printers();
            } catch (Error e) {
                existing = new Gee.ArrayList<Print.Printer>();
            }
        }

        private bool known_uri(string uri) {
            foreach (var p in existing) if (p.device_uri == uri) return true;
            return false;
        }

        private string? known_name_for(string uri) {
            foreach (var p in existing) if (p.device_uri == uri) return p.display_name;
            return null;
        }

        private void show_status_row(string title, string subtitle, string icon, bool spinning) {
            nearby_group.clear();
            var row = new ActionRow(title, subtitle, icon);
            row.activatable = false;
            if (spinning) {
                var spinner = new Spinner();
                spinner.spinning = true;
                spinner.valign = Align.CENTER;
                row.add_suffix(spinner);
            }
            nearby_group.add_row(row);
        }

        private async void search() {
            if (nearby_group == null) return;
            if (discovery != null) discovery.cancel();
            var cancellable = new Cancellable();
            discovery = cancellable;
            search_btn.sensitive = false;
            show_status_row(_("Looking for Printers…"), _("This takes a few seconds"), "printer-network-symbolic", true);
            if (discovery_ticket != null) discovery_ticket.end_quietly();
            discovery_ticket = SidebarWait.get_default().begin(this, _("Looking for printers"), "printer-symbolic",
                () => cancellable.cancel());
            Gee.List<Print.DiscoveredPrinter> found;
            string? failure = null;
            try {
                found = yield backend.discover(cancellable);
            } catch (Error e) {
                found = new Gee.ArrayList<Print.DiscoveredPrinter>();
                if (!(e is Print.PrintError.CANCELLED) && !(e is IOError.CANCELLED)) failure = PrintersUi.error_text(e);
            }
            if (discovery != cancellable) return;
            discovery = null;
            if (discovery_ticket != null) {
                discovery_ticket.end_quietly();
                discovery_ticket = null;
            }
            search_btn.sensitive = true;
            if (cancellable.is_cancelled()) {
                show_status_row(_("Search Stopped"), _("Search again to see printers nearby"), "printer-network-symbolic", false);
                return;
            }
            if (failure != null) {
                show_status_row(_("Cannot Look for Printers"), failure, "dialog-warning-symbolic", false);
                return;
            }
            nearby_group.clear();
            int shown = 0;
            bool legacy = backend.can(Print.BackendFeature.LEGACY_DRIVER);
            foreach (var d in found) {
                if (known_uri(d.uri)) continue;
                if (!d.driverless && !legacy) continue;
                string sub = d.make_model != "" ? d.make_model : d.uri;
                if (!d.driverless) sub = _("%s, needs a legacy driver").printf(sub);
                else if (d.source == "usb") sub = _("%s, connected by cable").printf(sub);
                var row = new ActionRow(d.name, sub, null);
                var icon = new Image.from_icon_name(d.icon_name);
                icon.pixel_size = 40;
                icon.margin_end = 12;
                row.add_prefix(icon);
                var add = new Button.with_label(_("Add…"));
                add.valign = Align.CENTER;
                var device = d;
                add.clicked.connect(() => confirm_discovered(device));
                row.activated.connect(() => confirm_discovered(device));
                row.add_suffix(add);
                nearby_group.add_row(row);
                shown++;
            }
            if (shown == 0) {
                show_status_row(_("No New Printers Found"),
                    _("Turn the printer on and connect it to the same network, or add it by its address below."),
                    "printer-network-symbolic", false);
            }
        }

        private static string normalize(string text) {
            string t = text.strip();
            if (t == "") return "";
            if (!t.contains("://")) {
                if (t.contains("/")) return "ipp://" + t;
                return "ipp://" + t + "/ipp/print";
            }
            if (t.has_prefix("ipp://") || t.has_prefix("ipps://")) {
                int start = t.index_of("://") + 3;
                if (t.index_of("/", start) < 0) return t + "/ipp/print";
            }
            return t;
        }

        private async void check() {
            if (address_row == null) return;
            string uri = normalize(address_row.text);
            if (uri == "") return;
            address_error.visible = false;
            bool ipp = uri.has_prefix("ipp://") || uri.has_prefix("ipps://") || uri.has_prefix("http://")
                || uri.has_prefix("https://");
            bool legacy_only = uri.has_prefix("lpd://") || uri.has_prefix("socket://");
            if (!ipp && !legacy_only) {
                show_address_error(_("Use an address that starts with ipp://, ipps://, lpd:// or socket://."));
                return;
            }
            if (legacy_only) {
                if (!backend.can(Print.BackendFeature.LEGACY_DRIVER)) {
                    show_address_error(_("This kind of address needs a legacy driver, which this print service does not use. Try the printer's ipp:// address."));
                    return;
                }
                target_device = null;
                target_uri = uri;
                target_make = "";
                target_driverless = false;
                target_caps = null;
                target_markers = new Gee.ArrayList<Print.Marker>();
                show_confirm(host_of(uri), "");
                return;
            }
            check_btn.sensitive = false;
            var cancellable = new Cancellable();
            var ticket = SidebarWait.get_default().begin(this, _("Checking the printer"), "printer-symbolic",
                () => cancellable.cancel());
            Print.IppGroup? g = null;
            string? failure = null;
            try {
                g = yield backend.probe(uri);
            } catch (Error e) {
                failure = (e is Print.PrintError.UNREACHABLE)
                    ? _("No printer answers at %s. Check the address and that the printer is on.").printf(uri)
                    : PrintersUi.error_text(e);
            }
            check_btn.sensitive = true;
            if (cancellable.is_cancelled()) {
                ticket.end_quietly();
                return;
            }
            ticket.end();
            if (failure != null || g == null) {
                show_address_error(failure ?? _("The device at this address is not a printer."));
                return;
            }
            target_device = null;
            target_uri = uri;
            target_make = g.str("printer-make-and-model") ?? "";
            target_driverless = true;
            target_caps = Print.PrinterBackend.capabilities_from(g);
            target_markers = Print.PrinterBackend.markers_from(g);
            string info = g.str("printer-info") ?? "";
            if (info == "") info = target_make != "" ? target_make : host_of(uri);
            show_confirm(info, g.str("printer-location") ?? "");
        }

        private void show_address_error(string text) {
            address_error.label = text;
            address_error.visible = true;
        }

        private static string host_of(string uri) {
            try {
                return Uri.parse(uri, UriFlags.NONE).get_host() ?? uri;
            } catch (Error e) {
                return uri;
            }
        }

        private void confirm_discovered(Print.DiscoveredPrinter d) {
            target_device = d;
            target_uri = d.uri;
            target_make = d.make_model;
            target_driverless = d.driverless;
            target_caps = null;
            target_markers = new Gee.ArrayList<Print.Marker>();
            show_confirm(d.name, d.location);
        }

        private string describe_caps() {
            if (target_caps == null) return "";
            string[] parts = {};
            parts += target_caps.supports_color ? _("Colour") : _("Black and white");
            if (target_caps.supports_duplex) parts += _("two-sided");
            int sizes = target_caps.media.size;
            if (sizes > 0) parts += ngettext("%d paper size", "%d paper sizes", sizes).printf(sizes);
            return string.joinv(", ", parts);
        }

        private string icon_for_target(string name) {
            if (target_device != null) return target_device.icon_name;
            var k = Print.PrinterKind.guess(target_make, name, target_uri);
            return k == Print.PrinterKind.GENERIC ? "printer-network" : k.icon_name();
        }

        private void show_confirm(string name, string location) {
            Widget? child;
            while ((child = confirm_box.get_first_child()) != null) confirm_box.remove(child);
            chosen_driver = null;
            banner.visible = false;

            var head = new Box(Orientation.HORIZONTAL, 16);
            head.margin_top = 12;
            head.margin_start = 12;
            head.margin_end = 12;
            var icon = new Image.from_icon_name(icon_for_target(name));
            icon.pixel_size = 72;
            icon.valign = Align.CENTER;
            head.append(icon);
            var text = new Box(Orientation.VERTICAL, 3);
            text.valign = Align.CENTER;
            text.hexpand = true;
            var title = new Label(name);
            title.add_css_class("title-3");
            title.xalign = 0;
            title.wrap = true;
            text.append(title);
            if (target_make != "" && target_make != name) {
                var make = new Label(target_make);
                make.add_css_class("dim-label");
                make.xalign = 0;
                make.wrap = true;
                text.append(make);
            }
            string caps = describe_caps();
            if (caps != "") {
                var c = new Label(caps);
                c.add_css_class("caption");
                c.xalign = 0;
                c.wrap = true;
                text.append(c);
            }
            var uri = new Label(target_uri);
            uri.add_css_class("caption");
            uri.add_css_class("dim-label");
            uri.xalign = 0;
            uri.ellipsize = Pango.EllipsizeMode.MIDDLE;
            uri.selectable = true;
            text.append(uri);
            if (target_markers.size > 0) {
                var inks = new Print.InkLevels(false);
                inks.halign = Align.START;
                inks.margin_top = 3;
                inks.set_markers(target_markers);
                text.append(inks);
            }
            head.append(text);
            confirm_box.append(head);

            string? already = known_name_for(target_uri);
            if (already != null) {
                var note = new Banner(_("This printer is already set up as “%s”. Adding it again creates a second queue.").printf(already),
                    BannerStyle.WARNING);
                note.icon_name = "dialog-information-symbolic";
                note.margin_top = 12;
                confirm_box.append(note);
            }

            var details = new PreferencesGroup(_("Name and Location"),
                _("How the printer appears in the print dialog of every app."));
            details.margin_top = 12;
            name_row = new EntryRow(_("Name"));
            name_row.text = name;
            name_row.entry_changed.connect(() => add_btn.sensitive = name_row.text.strip() != "");
            name_row.entry_activated.connect(() => add.begin());
            details.add_row(name_row);
            location_row = new EntryRow(_("Location"));
            location_row.text = location;
            location_row.entry_activated.connect(() => add.begin());
            location_row.visible = backend.can(Print.BackendFeature.EDIT_INFO);
            details.add_row(location_row);
            confirm_box.append(details);

            confirm_box.append(build_driver_group());

            confirm_error = new Label("");
            confirm_error.add_css_class("error");
            confirm_error.wrap = true;
            confirm_error.xalign = 0;
            confirm_error.margin_top = 12;
            confirm_error.margin_start = 12;
            confirm_error.margin_end = 12;
            confirm_error.visible = false;
            confirm_box.append(confirm_error);

            var buttons = new Box(Orientation.HORIZONTAL, 12);
            buttons.halign = Align.CENTER;
            buttons.margin_top = 24;
            buttons.margin_bottom = 12;
            var cancel = new Button.with_label(_("Cancel"));
            cancel.add_css_class("pill");
            cancel.clicked.connect(() => inner_stack.visible_child_name = "choose");
            buttons.append(cancel);
            add_btn = new Button.with_label(_("Add Printer"));
            add_btn.add_css_class("pill");
            add_btn.add_css_class("suggested-action");
            add_btn.clicked.connect(() => add.begin());
            buttons.append(add_btn);
            confirm_box.append(buttons);
            update_driver_state();
            inner_stack.visible_child_name = "confirm";
        }

        private Widget build_driver_group() {
            var group = new PreferencesGroup(_("Driver"));
            group.margin_top = 12;
            driver_row = new ActionRow("", null, "emblem-ok-symbolic");
            driver_row.activatable = false;
            clear_driver_btn = new Button.with_label(_("Use Driverless"));
            clear_driver_btn.valign = Align.CENTER;
            clear_driver_btn.clicked.connect(() => {
                chosen_driver = null;
                update_driver_state();
            });
            driver_row.add_suffix(clear_driver_btn);
            group.add_row(driver_row);
            if (backend.can(Print.BackendFeature.LEGACY_DRIVER)) {
                var legacy = new SearchableExpanderRow(_("Legacy Driver…"),
                    _("Only for old printers that do not work without a driver"), "application-x-executable-symbolic");
                legacy.expanded = !target_driverless;
                legacy.search_entry.placeholder_text = _("Search by make or model");
                legacy.notify["expanded"].connect(() => {
                    if (legacy.expanded) load_drivers.begin(legacy);
                });
                legacy.search_entry.search_changed.connect(() => fill_drivers(legacy));
                group.add_row(legacy);
                if (legacy.expanded) load_drivers.begin(legacy);
            }
            return group;
        }

        private void update_driver_state() {
            if (chosen_driver != null) {
                driver_row.title = chosen_driver.make_model;
                driver_row.subtitle = _("Legacy driver");
                driver_row.icon_name = "application-x-executable-symbolic";
                clear_driver_btn.visible = target_driverless;
            } else if (target_driverless) {
                driver_row.title = _("Driverless");
                driver_row.subtitle = _("IPP Everywhere, no driver to install");
                driver_row.icon_name = "emblem-ok-symbolic";
                clear_driver_btn.visible = false;
            } else {
                driver_row.title = _("Choose a Driver");
                driver_row.subtitle = _("This printer needs a legacy driver; pick its model below");
                driver_row.icon_name = "dialog-warning-symbolic";
                clear_driver_btn.visible = false;
            }
            if (add_btn != null)
                add_btn.sensitive = (target_driverless || chosen_driver != null) && name_row.text.strip() != "";
        }

        private async void load_drivers(SearchableExpanderRow row) {
            if (drivers != null) {
                fill_drivers(row);
                return;
            }
            clear_list(row.list_box);
            var wait = new ActionRow(_("Loading Drivers…"), null, "application-x-executable-symbolic");
            wait.activatable = false;
            var spinner = new Spinner();
            spinner.spinning = true;
            wait.add_suffix(spinner);
            row.list_box.append(wait);
            try {
                drivers = yield backend.legacy_drivers();
            } catch (Error e) {
                clear_list(row.list_box);
                var err = new ActionRow(_("No Drivers Available"), PrintersUi.error_text(e), "dialog-warning-symbolic");
                err.activatable = false;
                row.list_box.append(err);
                return;
            }
            fill_drivers(row);
        }

        private void clear_list(ListBox list) {
            Widget? child;
            while ((child = list.get_first_child()) != null) list.remove(child);
        }

        private void fill_drivers(SearchableExpanderRow row) {
            if (drivers == null) return;
            clear_list(row.list_box);
            string query = row.search_entry.text.strip().down();
            string guess = target_make.down();
            bool guess_matches = false;
            foreach (var d in drivers) {
                if (guess != "" && d.make != "" && guess.contains(d.make.down())) {
                    guess_matches = true;
                    break;
                }
            }
            if (!guess_matches) guess = "";
            int shown = 0;
            foreach (var d in drivers) {
                string hay = d.make_model.down();
                if (query != "") {
                    bool all = true;
                    foreach (var word in query.split(" ")) if (word != "" && !hay.contains(word)) all = false;
                    if (!all) continue;
                } else if (guess != "" && d.make != "" && !guess.contains(d.make.down())) {
                    continue;
                }
                var r = new ActionRow(d.make_model, d.id, null);
                var driver = d;
                r.activated.connect(() => {
                    chosen_driver = driver;
                    row.expanded = false;
                    update_driver_state();
                });
                row.list_box.append(r);
                if (++shown >= 80) break;
            }
            if (shown == 0) {
                var none = new ActionRow(_("No Matching Drivers"), _("Search for the printer's make and model"),
                    "edit-find-symbolic");
                none.activatable = false;
                row.list_box.append(none);
            }
        }

        private string unique_queue(string display) {
            string base_name = Print.PrinterBackend.sanitize_name(display);
            string candidate = base_name;
            int n = 2;
            bool taken = true;
            while (taken) {
                taken = false;
                foreach (var p in existing) {
                    if (p.name.down() == candidate.down()) {
                        taken = true;
                        break;
                    }
                }
                if (taken) candidate = "%s_%d".printf(base_name, n++);
            }
            return candidate;
        }

        private async void add() {
            if (!add_btn.sensitive) return;
            string display = name_row.text.strip();
            if (display == "") return;
            string location = location_row.text.strip();
            yield load_existing();
            string queue = unique_queue(display);
            string shown_name = queue == Print.PrinterBackend.sanitize_name(display) ? display : queue.replace("_", " ");
            add_btn.sensitive = false;
            confirm_error.visible = false;
            var ticket = SidebarWait.get_default().begin(this, _("Adding %s").printf(shown_name), "printer-symbolic");
            try {
                if (target_device != null && chosen_driver == null) {
                    target_device.location = location;
                    yield backend.add_discovered(target_device, queue);
                    if (backend.can(Print.BackendFeature.EDIT_INFO) && shown_name != queue)
                        yield backend.set_info(queue, shown_name, location);
                } else {
                    yield backend.add_printer(queue, target_uri, shown_name, location,
                                              chosen_driver != null ? chosen_driver.id : null);
                }
            } catch (Error e) {
                ticket.end();
                add_btn.sensitive = true;
                confirm_error.label = "%s. %s".printf(PrintersUi.error_title(e), PrintersUi.error_text(e));
                confirm_error.visible = true;
                return;
            }
            ticket.end_quietly();
            var page = new PrinterDetailPage(view, queue);
            view.open_subpage(page, "printer-detail");
        }
    }
}
