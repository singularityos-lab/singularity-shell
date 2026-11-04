using Gtk;
using GLib;

namespace Singularity {

    [CCode (has_target = false)]
    private delegate Gtk.Widget? AgentCardFactory(string intent, string args, string result);

    private class AgentCardSource : Object {
        public string app;
        public string[] intents;
        public string module_path;
        public string symbol;
        public Module? module = null;
        public AgentCardFactory? factory = null;
        public bool failed = false;

        public bool serves(string intent) {
            foreach (var i in intents) {
                if (i == intent) return true;
            }
            return false;
        }

        public bool load() {
            if (factory != null) return true;
            if (failed) return false;
            module = Module.open(module_path, ModuleFlags.LAZY | ModuleFlags.LOCAL);
            void* sym = null;
            if (module == null || !module.symbol(symbol, out sym) || sym == null) {
                warning("Sinty AI card %s: %s", module_path, Module.error());
                failed = true;
                module = null;
                return false;
            }
            factory = (AgentCardFactory) sym;
            return true;
        }
    }

    public class AgentCards : Object {
        private static AgentCards? instance = null;
        private List<AgentCardSource> sources = new List<AgentCardSource>();
        private int64 scanned = 0;

        public static AgentCards get_default() {
            if (instance == null) instance = new AgentCards();
            return instance;
        }

        private static string[] data_dirs() {
            string[] dirs = { Path.build_filename(Environment.get_user_data_dir(), "singularity", "cards") };
            foreach (var d in Environment.get_system_data_dirs()) dirs += Path.build_filename(d, "singularity", "cards");
            dirs += "/opt/local/share/singularity/cards";
            return dirs;
        }

        private static string[] module_dirs() {
            string[] dirs = {};
            foreach (var root in new string[] { "/opt/local", "/usr/local", "/usr" }) {
                foreach (var lib in new string[] { "lib", "lib64", "lib/x86_64-linux-gnu", "lib/aarch64-linux-gnu" }) {
                    foreach (var kind in new string[] { "cards", "widgets" }) {
                        dirs += Path.build_filename(root, lib, "singularity", kind);
                    }
                }
            }
            return dirs;
        }

        private static string? locate(string manifest, string module) {
            if (Path.is_absolute(module)) return FileUtils.test(module, FileTest.EXISTS) ? module : null;
            var here = Path.get_dirname(manifest);
            foreach (var dir in new string[] { here, Path.build_filename(Path.get_dirname(here), "widgets") }) {
                var near = Path.build_filename(dir, module);
                if (FileUtils.test(near, FileTest.EXISTS)) return near;
            }
            foreach (var d in module_dirs()) {
                var p = Path.build_filename(d, module);
                if (FileUtils.test(p, FileTest.EXISTS)) return p;
            }
            return null;
        }

        private void rescan() {
            var now = get_monotonic_time();
            if (scanned != 0 && now - scanned < 10 * TimeSpan.SECOND) return;
            scanned = now;
            var seen = new GenericSet<string>(str_hash, str_equal);
            var fresh = new List<AgentCardSource>();
            foreach (var dir in data_dirs()) {
                Dir handle;
                try {
                    handle = Dir.open(dir);
                } catch (FileError e) {
                    continue;
                }
                string? name;
                while ((name = handle.read_name()) != null) {
                    if (!name.has_suffix(".card") || seen.contains(name)) continue;
                    seen.add(name);
                    var path = Path.build_filename(dir, name);
                    var kf = new KeyFile();
                    try {
                        kf.load_from_file(path, KeyFileFlags.NONE);
                        var module = locate(path, kf.get_string("Card", "Module"));
                        if (module == null) continue;
                        var source = reuse(module) ?? new AgentCardSource();
                        source.app = kf.get_string("Card", "App");
                        source.intents = kf.get_string_list("Card", "Intents");
                        source.module_path = module;
                        source.symbol = kf.get_string("Card", "Symbol");
                        fresh.append(source);
                    } catch (Error e) {
                        warning("Sinty AI card %s: %s", path, e.message);
                    }
                }
            }
            sources = (owned) fresh;
        }

        private AgentCardSource? reuse(string module) {
            foreach (var s in sources) {
                if (s.module_path == module) return s;
            }
            return null;
        }

        public Widget? build(string app, string intent, string args, string result) {
            rescan();
            foreach (var s in sources) {
                if (s.app != app || !s.serves(intent) || !s.load()) continue;
                var body = s.factory(intent, args, result);
                if (body == null) return null;
                return frame(app, body);
            }
            return null;
        }

        private static Widget frame(string app, Widget body) {
            var card = new Box(Orientation.VERTICAL, 8);
            card.add_css_class("agent-card");
            var head = new Box(Orientation.HORIZONTAL, 8);
            var info = new GLib.DesktopAppInfo(app + ".desktop");
            var icon = new Image.from_gicon(info != null && info.get_icon() != null
                ? info.get_icon() : new ThemedIcon("application-x-executable"));
            icon.pixel_size = 24;
            head.append(icon);
            var name = new Label(info != null ? info.get_display_name() : app);
            name.add_css_class("heading");
            name.xalign = 0;
            name.hexpand = true;
            name.ellipsize = Pango.EllipsizeMode.END;
            head.append(name);
            card.append(head);
            card.append(body);
            return card;
        }
    }
}
