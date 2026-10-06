namespace Singularity.InputMethods {

    public class InputSources : Object {
        private static InputSources? instance = null;

        public signal void changed();
        public signal void engine_ready(InputEngine? engine);

        public GLib.Settings settings { get; private set; }
        public string current { get; private set; default = ""; }
        public InputEngine? engine { get; private set; default = null; }
        public bool connecting { get; private set; default = false; }

        private Framework[] frameworks;
        private string engine_framework = "";
        private uint generation = 0;

        public static InputSources get_default() {
            if (instance == null) instance = new InputSources();
            return instance;
        }

        private InputSources() {
            settings = new GLib.Settings("dev.sinty.desktop");
            frameworks = { new FcitxFramework(), new IBusFramework() };
            settings.changed["input-method-engines"].connect(() => {
                if (current != "" && !(current in configured())) activate.begin("");
                changed();
            });
            settings.changed["input-method-framework"].connect(() => changed());
        }

        public Framework[] installed_frameworks() {
            Framework[] result = {};
            string wanted = settings.get_string("input-method-framework");
            foreach (var framework in frameworks) {
                if (wanted != "auto" && wanted != "" && framework.id != wanted) continue;
                if (framework.installed()) result += framework;
            }
            return result;
        }

        public Framework? framework_for(string id) {
            foreach (var framework in installed_frameworks()) {
                if (framework.id == id) return framework;
            }
            return null;
        }

        public EngineInfo[] available() {
            EngineInfo[] result = {};
            foreach (var framework in installed_frameworks()) {
                foreach (var info in framework.engines()) result += info;
            }
            return result;
        }

        public EngineInfo? info_for(string id) {
            foreach (var info in available()) {
                if (info.id == id) return info;
            }
            return null;
        }

        public string[] configured() {
            string[] result = {};
            foreach (string id in settings.get_strv("input-method-engines")) {
                if (!(id in result)) result += id;
            }
            return result;
        }

        public void add(string id) {
            string[] list = configured();
            if (id in list) return;
            list += id;
            settings.set_strv("input-method-engines", list);
        }

        public void remove(string id) {
            string[] list = {};
            foreach (string item in configured()) {
                if (item != id) list += item;
            }
            settings.set_strv("input-method-engines", list);
        }

        public string label_for(string id) {
            if (id == "") {
                string layout = settings.get_string("xkb-layout");
                if (layout == "") return "EN";
                return layout.substring(0, int.min(2, layout.length)).up();
            }
            var info = info_for(id);
            return info != null ? info.short_label() : "?";
        }

        public string name_for(string id) {
            if (id == "") return _("Keyboard Layout");
            var info = info_for(id);
            return info != null ? info.label : id;
        }

        public void cycle() {
            string[] order = { "" };
            foreach (string id in configured()) order += id;
            int index = 0;
            for (int i = 0; i < order.length; i++) {
                if (order[i] == current) index = i;
            }
            activate.begin(order[(index + 1) % order.length]);
        }

        public async void activate(string id) {
            uint my_generation = ++generation;
            if (id == "") {
                current = "";
                changed();
                engine_ready(null);
                return;
            }
            int colon = id.index_of(":");
            if (colon <= 0) return;
            string framework_id = id.substring(0, colon);
            string name = id.substring(colon + 1);
            var framework = framework_for(framework_id);
            if (framework == null) {
                warning("Input method: %s is not installed", framework_id);
                return;
            }
            connecting = true;
            try {
                if (engine == null || engine_framework != framework_id) {
                    var connected = yield framework.connect_engine();
                    if (my_generation != generation) return;
                    engine = connected;
                    engine_framework = framework_id;
                    connected.lost.connect(() => {
                        if (engine != connected) return;
                        engine = null;
                        engine_framework = "";
                        if (current != "") activate.begin(current);
                    });
                }
                yield engine.select_engine(name);
                if (my_generation != generation) return;
                current = id;
                changed();
                engine_ready(engine);
            } catch (Error e) {
                warning("Input method: cannot switch to %s: %s", id, e.message);
            } finally {
                connecting = false;
            }
        }

        public void shutdown() {
            foreach (var framework in frameworks) framework.shutdown();
        }
    }
}
