using Gtk;
using Peas;
using Gee;

namespace Singularity {

    public class PluginManager : Object {
        private static PluginManager? _instance = null;
        private Peas.Engine? engine = null;
        private HashMap<string, Singularity.Plugin> loaded_extensions;
        private PluginContext context;
        private GLib.Settings settings;
        private bool engine_ready = false;

        public static PluginManager get_default() {
            if (_instance == null) {
                _instance = new PluginManager();
            }
            return _instance;
        }

        private PluginManager() {
            loaded_extensions = new HashMap<string, Singularity.Plugin>();
            context = new PluginContext();
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["enabled-plugins"].connect(() => {
                if (SafeMode.get_default().allows(SafeFeature.PLUGINS))
                    enable_configured_plugins();
            });
        }

        private void ensure_engine() {
            if (engine_ready) return;
            engine = Peas.Engine.get_default();

            string? env_plugin_path = Environment.get_variable("SINGULARITY_PLUGIN_PATH");
            if (env_plugin_path != null) {
                string[] paths = env_plugin_path.split(":");
                foreach (string path in paths) {
                    engine.add_search_path(path, path);
                }
            }

            // Search paths, after SINGULARITY_PLUGIN_PATH above: the install
            // prefix derived from our own binary (covers /opt without hardcoding
            // it), the user data dir, then every XDG system data dir (covers
            // /usr). All resolve to <dir>/singularity/plugins.
            string[] plugin_dirs = {};
            try {
                string exe = GLib.FileUtils.read_link("/proc/self/exe");
                string prefix = GLib.Path.get_dirname(GLib.Path.get_dirname(exe));
                plugin_dirs += GLib.Path.build_filename(prefix, "share", "singularity", "plugins");
                // meson installs the plugin modules under libdir, which varies by
                // distro (lib, lib64, lib/<triplet>); search the common ones so a
                // plain `meson install` is found regardless of layout.
                foreach (string libdir in new string[] {
                        "lib", "lib64",
                        "lib/x86_64-linux-gnu", "lib/aarch64-linux-gnu" }) {
                    plugin_dirs += GLib.Path.build_filename(prefix, libdir, "singularity", "plugins");
                }
            } catch (Error e) { }
            plugin_dirs += GLib.Path.build_filename(Environment.get_user_data_dir(), "singularity", "plugins");
            foreach (unowned string d in Environment.get_system_data_dirs())
                plugin_dirs += GLib.Path.build_filename(d, "singularity", "plugins");
            foreach (string p in plugin_dirs)
                engine.add_search_path(p, p);

            engine.load_plugin.connect_after((info) => {
                load_extension(info);
            });
            engine.unload_plugin.connect_after((info) => {
                unload_extension(info);
            });
            engine_ready = true;
        }

        /**
         * Scans and loads configured plugins. Call after signal connections are set up.
         */

        public void load_plugins() {
            if (!SafeMode.get_default().allows(SafeFeature.PLUGINS)) return;
            if (settings.get_strv("enabled-plugins").length == 0 &&
                Environment.get_variable("SINGULARITY_PLUGIN_PATH") == null) {
                return;
            }
            ensure_engine();
            engine.rescan_plugins();
            enable_configured_plugins();
        }

        private void load_extension(Peas.PluginInfo info) {
            string module_name = info.get_module_name();
            if (loaded_extensions.has_key(module_name)) return;

            if (is_plugin_enabled(module_name)) {
                try {
                    // Manual extension creation to avoid ExtensionSet crash
                    // Using empty properties
                    string[] names = {};
                    Value[] values = {};
                    var exten_obj = engine.create_extension_with_properties(info, typeof(Singularity.Plugin), names, values);

                    if (exten_obj != null && exten_obj is Singularity.Plugin) {
                        var plugin = (Singularity.Plugin)exten_obj;
                        plugin.activate(context);
                        loaded_extensions.set(module_name, plugin);
                    } else {
                        // Plugin might not implement the interface, which is fine
                    }
                } catch (Error e) {
                    warning("Failed to create extension for %s: %s", module_name, e.message);
                }
            }
        }

        private void unload_extension(Peas.PluginInfo info) {
            string module_name = info.get_module_name();
            if (loaded_extensions.has_key(module_name)) {
                var plugin = loaded_extensions.get(module_name);
                plugin.deactivate();
                loaded_extensions.unset(module_name);
            }
        }

        public PluginContext get_context() {
            return context;
        }

        public GLib.List<PluginInfo> get_available_plugins() {
            ensure_engine();
            engine.rescan_plugins();
            var list = new GLib.List<PluginInfo>();
            var model = (GLib.ListModel)engine;
            uint n_items = model.get_n_items();
            for (uint i = 0; i < n_items; i++) {
                var info = (Peas.PluginInfo)model.get_item(i);
                list.append(info);
            }
            return list;
        }

        public bool is_plugin_enabled(string module_name) {
             string[] enabled = settings.get_strv("enabled-plugins");
             foreach (string s in enabled) {
                 if (s == module_name) return true;
             }
             return false;
        }

        public void set_plugin_enabled(string module_name, bool enabled) {
            string[] current = settings.get_strv("enabled-plugins");
            bool already_enabled = false;
            foreach (string s in current) {
                if (s == module_name) { already_enabled = true; break; }
            }

            if (enabled == already_enabled) {
                // State already correct; just ensure runtime state matches
                update_plugin_state(module_name, enabled);
                return;
            }

            // Build a plain Vala string[] (null-terminated) - DO NOT use GEE
            // to_array() here: gee_collection_to_array() returns a non-null-terminated
            // array while g_settings_set_strv expects null-terminated, SIGSEGV.
            // Also filter NULL/empty entries from GSettings strv to avoid g_utf8_validate crash.
            string[] new_list = {};
            if (enabled) {
                foreach (string s in current) {
                    if (s != null && s.length > 0) new_list += s;
                }
                new_list += module_name;
            } else {
                foreach (string s in current) {
                    if (s != null && s.length > 0 && s != module_name) new_list += s;
                }
            }

            settings.set_strv("enabled-plugins", new_list);
            update_plugin_state(module_name, enabled);
        }

        private void enable_configured_plugins() {
            if (!SafeMode.get_default().allows(SafeFeature.PLUGINS)) return;
            if (settings.get_strv("enabled-plugins").length == 0 && !engine_ready) return;
            ensure_engine();
            var model = (GLib.ListModel)engine;
            uint n_items = model.get_n_items();
            for (uint i = 0; i < n_items; i++) {
                 var info = (Peas.PluginInfo)model.get_item(i);
                 string module_name = info.get_module_name();
                 bool should_be_active = is_plugin_enabled(module_name);

                 bool is_loaded = info.is_loaded();

                 if (should_be_active && !is_loaded) {
                     try {
                        engine.load_plugin(info);
                     } catch (Error e) {
                         warning("Failed to load plugin %s: %s", module_name, e.message);
                     }
                 } else if (!should_be_active && is_loaded) {
                     unload_extension(info);
                 }
            }
        }

        private void update_plugin_state(string module_name, bool enabled) {
            if (!SafeMode.get_default().allows(SafeFeature.PLUGINS)) return;
            ensure_engine();
            var info = engine.get_plugin_info(module_name);
            if (info == null) return;

            if (enabled) {
                if (!info.is_loaded()) {
                    try {
                        engine.load_plugin(info);
                    } catch (Error e) { warning("Load failed: %s", e.message); }
                } else {
                    // Already loaded, ensure extension is created
                    load_extension(info);
                }
            } else {
                 unload_extension(info);
            }
        }

        public Gtk.Widget? get_plugin_settings_widget(string module_name) {
            if (loaded_extensions.has_key(module_name)) {
                return loaded_extensions.get(module_name).get_settings_widget();
            }
            return null;
        }
    }
}
