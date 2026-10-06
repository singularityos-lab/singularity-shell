using GLib;
using Gtk;

namespace Singularity {

    [DBus (name = "dev.sinty.shell.Preview")]
    public class PreviewManager : Object {
        private PreviewDialog? dialog = null;
        private Gtk.Application app;

        public PreviewManager(Gtk.Application app) {
            this.app = app;
            try {
                var connection = Bus.get_sync(BusType.SESSION);
                connection.register_object("/dev/sinty/shell/Preview", this);
            } catch (Error e) {
                warning("Failed to register PreviewManager on DBus: %s", e.message);
            }
        }

        public void show_preview(string uri) throws Error {
            show_previews({ uri }, 0, "");
        }

        public void show_previews(string[] uris, int index, string origin) throws Error {
            if (uris.length == 0) throw new IOError.INVALID_ARGUMENT("No file to preview");
            string[] list = uris;
            int position = index.clamp(0, uris.length - 1);
            string source = origin;
            Idle.add(() => {
                if (dialog == null) dialog = new PreviewDialog(app);
                if (dialog.visible && dialog.current_uri == list[position]) {
                    dialog.close_dialog();
                } else {
                    dialog.show_files(list, position, source);
                }
                return Source.REMOVE;
            });
        }

        public void close_preview() throws Error {
            Idle.add(() => {
                if (dialog != null) dialog.close_dialog();
                return Source.REMOVE;
            });
        }
    }
}
