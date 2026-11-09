using GLib;
using Singularity.Profiles;

namespace Singularity.ProfilesService {

    struct SystemArea {
        public string id;
        public string bus_name;
    }

    int main(string[] args) {
        Intl.setlocale(LocaleCategory.ALL, "");
        Intl.bindtextdomain("singularity-desktop", Path.build_filename(Environment.get_variable("SINGULARITY_LOCALEDIR") ?? "/usr/share", "locale"));
        Intl.bind_textdomain_codeset("singularity-desktop", "UTF-8");
        Intl.textdomain("singularity-desktop");

        string config_dir = Path.build_filename(Environment.get_user_config_dir(), "singularity");
        string state_dir = Path.build_filename(Environment.get_user_state_dir(), "singularity");
        var engine = new Engine(config_dir, state_dir);
        var service = new Service(engine);
        var loop = new MainLoop();

        foreach (string app_id in DescribedAppArea.described_apps()) {
            var info = new DesktopAppInfo(app_id + ".desktop");
            var area = DescribedAppArea.load(app_id, info != null ? info.get_display_name() : app_id,
                info != null && info.get_icon() != null ? info.get_icon().to_string() : "application-x-executable");
            if (area != null) engine.add_area(new AreaHandle.local(area));
        }

        SystemArea[] system_areas = {
            SystemArea() { id = Areas.ENERGY, bus_name = "dev.sinty.Power1" },
            SystemArea() { id = Areas.VPN, bus_name = "org.freedesktop.NetworkManager" }
        };
        bool system_bus = true;
        try {
            Bus.get_sync(BusType.SYSTEM);
        } catch (IOError e) {
            system_bus = false;
            debug("profiles: no system bus, system areas stay with the shell: %s", e.message);
        }
        foreach (var sa in system_areas) {
            if (!system_bus) break;
            string id = sa.id;
            string name = sa.bus_name;
            Bus.watch_name(BusType.SYSTEM, name, BusNameWatcherFlags.NONE,
                (c, n, owner) => {
                    AreaHandle.connect_remote.begin(id, BusType.SYSTEM, name, AREA_PATH_PREFIX + Area.path_segment(id), owner, 2, (o, res) => {
                        var handle = AreaHandle.connect_remote.end(res);
                        if (handle != null) engine.add_area(handle);
                    });
                },
                (c, n) => {
                    foreach (var h in engine.areas) {
                        if (h.id == id && h.system_bus) {
                            engine.remove_owner(h.owner, true);
                            break;
                        }
                    }
                });
        }

        Bus.own_name(BusType.SESSION, SERVICE_NAME, BusNameOwnerFlags.NONE,
            (conn) => {
                try {
                    conn.register_object(SERVICE_PATH, service);
                    service.attach(conn);
                } catch (IOError e) {
                    critical("profiles: could not export the service: %s", e.message);
                    loop.quit();
                }
            },
            () => {},
            () => {
                warning("profiles: lost %s", SERVICE_NAME);
                loop.quit();
            });

        Unix.signal_add(ProcessSignal.TERM, () => {
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        return 0;
    }
}
