using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class GraphicsDriverGroup : PreferencesGroup {
        private const string BUNDLE = "nvidia";
        private const uint FIRST_GSP_DEVICE = 0x1e00;

        private class Card {
            public string address;
            public uint device;
            public string driver;
        }

        private Gee.ArrayList<Card> cards = new Gee.ArrayList<Card>();
        private ActionRow driver_row;
        private Spinner spinner;
        private Button action_btn;
        private bool chosen = false;

        public static bool available() {
            return Singularity.Runtime.is_sinty_os() && BootChainGroup.available() && read_cards().size > 0;
        }

        public GraphicsDriverGroup() {
            base(_("NVIDIA Graphics"),
                _("The open driver works from the first start. The NVIDIA driver is installed only when you ask for it here."));
            cards = read_cards();
            bool any_modern = false;
            foreach (var card in cards) {
                add_row(card_row(card));
                if (card.device >= FIRST_GSP_DEVICE) any_modern = true;
            }
            if (!any_modern) return;

            driver_row = new ActionRow(_("NVIDIA Driver"), _("Checking what this system offers"));
            spinner = new Spinner();
            spinner.valign = Align.CENTER;
            spinner.visible = true;
            spinner.spinning = true;
            driver_row.add_suffix(spinner);
            action_btn = new Button.with_label(_("Install"));
            action_btn.valign = Align.CENTER;
            action_btn.visible = false;
            action_btn.clicked.connect(() => confirm());
            driver_row.add_suffix(action_btn);
            add_row(driver_row);

            add_row(new ActionRow(_("Speed"),
                _("In games the open driver reaches between about 40% and 70% of the NVIDIA driver. CUDA and some professional apps need the NVIDIA driver.")));
            refresh.begin();
        }

        private static string read_line(string path) {
            string contents;
            try {
                FileUtils.get_contents(path, out contents);
            } catch (Error e) {
                return "";
            }
            return contents.strip();
        }

        private static Gee.ArrayList<Card> read_cards() {
            var list = new Gee.ArrayList<Card>();
            const string ROOT = "/sys/bus/pci/devices";
            try {
                var dir = Dir.open(ROOT);
                string? name;
                while ((name = dir.read_name()) != null) {
                    string path = Path.build_filename(ROOT, name);
                    if (read_line(Path.build_filename(path, "vendor")) != "0x10de") continue;
                    if (!read_line(Path.build_filename(path, "class")).has_prefix("0x03")) continue;
                    var card = new Card();
                    card.address = name;
                    card.device = (uint) uint64.parse(read_line(Path.build_filename(path, "device")));
                    try {
                        card.driver = Path.get_basename(FileUtils.read_link(Path.build_filename(path, "driver")));
                    } catch (FileError e) {
                        card.driver = "";
                    }
                    list.add(card);
                }
            } catch (FileError e) {
                debug("Graphics cards: %s", e.message);
            }
            return list;
        }

        private Widget card_row(Card card) {
            string driver;
            switch (card.driver) {
                case "nouveau": driver = _("Open driver"); break;
                case "nvidia": driver = _("NVIDIA driver"); break;
                case "nova_core": driver = _("Nova, experimental"); break;
                case "": driver = _("Not started"); break;
                default: driver = card.driver; break;
            }
            string subtitle = card.device >= FIRST_GSP_DEVICE
                ? _("Device %04x at %s").printf(card.device, card.address)
                : _("This card predates the GeForce 16 and RTX series. It keeps the open driver at its current speed, and the NVIDIA driver is not offered for it.");
            var row = new ActionRow(_("Graphics Card"), subtitle, "video-display-symbolic");
            var label = new Label(driver);
            label.add_css_class("dim-label");
            row.add_suffix(label);
            if (card.driver == "") row.subtitle = _("It did not start. Details are in Logs.");
            return row;
        }

        private Json.Object? find_bundle(Json.Object status) {
            if (!status.has_member("bundles")) return null;
            foreach (var node in status.get_array_member("bundles").get_elements()) {
                var bundle = node.get_object();
                if (bundle.get_string_member_with_default("name", "") == BUNDLE) return bundle;
            }
            return null;
        }

        private void apply(Json.Object status) {
            spinner.spinning = false;
            spinner.visible = false;
            action_btn.sensitive = true;
            var bundle = find_bundle(status);
            string error = status.get_string_member_with_default("error", "");
            if (bundle == null) {
                action_btn.visible = false;
                driver_row.subtitle = error != ""
                    ? _("Cannot reach the update service: %s").printf(error)
                    : _("Not offered for this version of Sinty OS yet.");
                return;
            }
            chosen = bundle.get_boolean_member_with_default("chosen", false);
            bool fits = bundle.get_boolean_member_with_default("fits_kernel", false);
            bool pending = bundle.get_boolean_member_with_default("pending", false);
            int installed = (int) bundle.get_int_member_with_default("installed_version", 0);
            int version = (int) bundle.get_int_member_with_default("version", 0);
            bool active = cards.any_match((c) => c.driver == "nvidia");

            action_btn.visible = true;
            action_btn.remove_css_class("suggested-action");
            action_btn.remove_css_class("destructive-action");
            if (chosen) {
                action_btn.label = _("Remove");
                action_btn.add_css_class("destructive-action");
                if (pending) {
                    driver_row.subtitle = _("Installed. Restart to start using it.");
                } else if (active) {
                    driver_row.subtitle = _("In use, version %d.").printf(installed);
                } else {
                    driver_row.subtitle = _("Installed, but it did not start, so the open driver is in use. Details are in Logs.");
                }
            } else if (!fits) {
                action_btn.visible = false;
                driver_row.subtitle = _("Update Sinty OS first: the NVIDIA driver on offer is built for a newer system.");
            } else {
                action_btn.label = _("Install");
                action_btn.add_css_class("suggested-action");
                driver_row.subtitle = _("Version %d is available.").printf(version);
            }
            if (error != "") driver_row.subtitle = error;
        }

        private async void refresh() {
            try {
                apply(yield BootChainGroup.request("GET", "/firmware/optional", 60));
            } catch (Error e) {
                var status = new Json.Object();
                status.set_string_member("error", e.message);
                apply(status);
            }
        }

        private void confirm() {
            var app = GLib.Application.get_default() as Gtk.Application;
            ConfirmDialog dialog;
            if (chosen) {
                dialog = new ConfirmDialog(app, _("Remove the NVIDIA Driver?"), "user-trash",
                    _("After a restart the open driver takes over. Games run slower and CUDA stops working."),
                    _("Remove"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            } else {
                dialog = new ConfirmDialog(app, _("Install the NVIDIA Driver?"), "dialog-warning",
                    _("The NVIDIA driver is proprietary software from NVIDIA. Its source code is not available, and only NVIDIA can fix it."),
                    _("Install"), ConfirmDialog.ActionStyle.SUGGESTED);
                string[] details = {
                    _("It comes from the Sinty OS update service, signed and checked before it is used."),
                    _("It is built for the system version you are running, and is updated together with it."),
                    _("If it does not start, the open driver takes over on its own."),
                };
                foreach (string text in details) {
                    var label = new Label(text);
                    label.wrap = true;
                    label.max_width_chars = 42;
                    label.xalign = 0;
                    label.add_css_class("dim-label");
                    dialog.custom_area.append(label);
                }
            }
            dialog.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) run.begin();
            });
            dialog.present();
        }

        private async void run() {
            string path = "/firmware/optional/%s?name=%s".printf(chosen ? "disable" : "enable", BUNDLE);
            driver_row.subtitle = chosen ? _("Removing the driver") : _("Downloading the driver");
            action_btn.sensitive = false;
            spinner.visible = true;
            spinner.spinning = true;
            string message = "";
            try {
                var reply = yield BootChainGroup.request("POST", path, 1800);
                message = reply.get_string_member_with_default("error", "");
            } catch (Error e) {
                message = e.message;
            }
            yield refresh();
            if (message != "") driver_row.subtitle = message;
        }
    }
}
