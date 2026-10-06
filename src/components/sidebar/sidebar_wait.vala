using Gtk;

namespace Singularity {

    public delegate void SidebarWaitCancel ();

    public class SidebarWaitTicket : Object {
        public string label { get; construct; }
        public string icon_name { get; construct; }
        public bool shows_own_status { get; construct; }
        public bool active { get; private set; default = true; }
        internal weak Widget? anchor;
        internal string main_page = "";
        internal string settings_page = "";
        internal double scroll = 0;
        internal SidebarWaitCancel? on_cancel;

        internal SidebarWaitTicket (string label, string icon_name, bool shows_own_status) {
            Object (label: label, icon_name: icon_name, shows_own_status: shows_own_status);
        }

        public void end (string? show_settings_page = null) {
            if (!active) return;
            active = false;
            if (show_settings_page != null) settings_page = show_settings_page;
            SidebarWait.get_default ().finish (this, true);
        }

        public void end_quietly () {
            if (!active) return;
            active = false;
            SidebarWait.get_default ().finish (this, false);
        }

        internal void run_cancel () {
            if (on_cancel != null) on_cancel ();
        }
    }

    public class SidebarWait : Object {
        private static SidebarWait? instance;
        private Gee.ArrayList<SidebarWaitTicket> tickets = new Gee.ArrayList<SidebarWaitTicket> ();

        public signal void changed ();

        public static SidebarWait get_default () {
            if (instance == null) instance = new SidebarWait ();
            return instance;
        }

        public SidebarWaitTicket? current {
            owned get { return tickets.size > 0 ? tickets[tickets.size - 1] : null; }
        }

        public SidebarWaitTicket begin (Widget anchor, string label, string icon_name, owned SidebarWaitCancel? cancel = null,
                                        bool shows_own_status = false) {
            var ticket = new SidebarWaitTicket (label, icon_name, shows_own_status);
            ticket.anchor = anchor;
            ticket.on_cancel = (owned) cancel;
            var sidebar = anchor.get_root () as Sidebar;
            if (sidebar != null) sidebar.capture_wait_state (ticket);
            tickets.add (ticket);
            changed ();
            return ticket;
        }

        internal void finish (SidebarWaitTicket ticket, bool reveal) {
            tickets.remove (ticket);
            changed ();
            if (reveal) show (ticket);
        }

        public static async File choose_file (Widget anchor, Gtk.FileDialog dialog, Gtk.Window? parent) throws Error {
            var cancellable = new Cancellable ();
            var ticket = get_default ().begin (anchor, _("Waiting for Files"), "folder-symbolic", () => cancellable.cancel ());
            try {
                var file = yield dialog.open (parent, cancellable);
                ticket.end ();
                return file;
            } catch (Error e) {
                ticket.end ();
                throw e;
            }
        }

        public void cancel (SidebarWaitTicket? ticket = null) {
            var t = ticket ?? current;
            if (t == null || !t.active) return;
            t.run_cancel ();
            t.end ();
        }

        public void reveal (SidebarWaitTicket? ticket = null) {
            var t = ticket ?? current;
            if (t != null) show (t);
        }

        private void show (SidebarWaitTicket ticket) {
            var anchor = ticket.anchor;
            if (anchor == null) return;
            var root = anchor.get_root ();
            var sidebar = root as Sidebar;
            if (sidebar != null) {
                sidebar.restore_wait_state (ticket);
                return;
            }
            var window = root as Gtk.Window;
            if (window != null) window.present ();
        }
    }

    public class SidebarWaitBar : Box {
        private Spinner spinner;
        private Label label;

        public SidebarWaitBar () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 10);
            add_css_class ("sidebar-wait-bar");
            margin_start = 16;
            margin_end = 16;
            margin_top = 12;
            spinner = new Spinner ();
            append (spinner);
            label = new Label ("");
            label.xalign = 0;
            label.hexpand = true;
            label.ellipsize = Pango.EllipsizeMode.END;
            append (label);
            var cancel = new Button.with_label (_("Cancel"));
            cancel.valign = Align.CENTER;
            cancel.clicked.connect (() => SidebarWait.get_default ().cancel ());
            append (cancel);
            var wait = SidebarWait.get_default ();
            wait.changed.connect (sync);
            sync ();
        }

        private void sync () {
            var t = SidebarWait.get_default ().current;
            visible = t != null && !t.shows_own_status;
            spinner.spinning = visible;
            if (t != null) label.label = t.label;
        }
    }

    public class SidebarWaitIndicator : Box {
        private Spinner spinner;
        private Label label;
        private Button reveal_btn;

        public SidebarWaitIndicator () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 2);
            valign = Align.CENTER;
            add_css_class ("sidebar-wait-indicator");
            reveal_btn = new Button ();
            reveal_btn.has_frame = false;
            reveal_btn.add_css_class ("system-pill-button");
            var box = new Box (Orientation.HORIZONTAL, 6);
            spinner = new Spinner ();
            box.append (spinner);
            label = new Label ("");
            box.append (label);
            reveal_btn.child = box;
            reveal_btn.clicked.connect (() => SidebarWait.get_default ().reveal ());
            append (reveal_btn);
            var cancel = new Button.from_icon_name ("window-close-symbolic");
            cancel.has_frame = false;
            cancel.add_css_class ("system-pill-button");
            cancel.tooltip_text = _("Cancel");
            cancel.update_property (Gtk.AccessibleProperty.LABEL, _("Cancel"), -1);
            cancel.clicked.connect (() => SidebarWait.get_default ().cancel ());
            append (cancel);
            SidebarWait.get_default ().changed.connect (sync);
            sync ();
        }

        private void sync () {
            var t = SidebarWait.get_default ().current;
            visible = t != null;
            spinner.spinning = visible;
            if (t == null) return;
            label.label = t.label;
            reveal_btn.tooltip_text = _("Show where this is waiting");
            reveal_btn.update_property (Gtk.AccessibleProperty.LABEL, t.label, -1);
        }
    }
}
