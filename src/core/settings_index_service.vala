namespace Singularity.Shell {

    [DBus (name = "dev.sinty.Shell.SettingsIndex")]
    public class SettingsIndexService : Object {
        private unowned SingularityApp app;

        [DBus (visible = false)]
        public SettingsIndexService(SingularityApp app) {
            this.app = app;
        }

        public async string entries() throws Error {
            yield app.warm_settings_index();
            var b = new Json.Builder();
            b.begin_array();
            foreach (var e in app.settings_entries()) {
                b.begin_object();
                b.set_member_name("page");
                b.add_string_value(e.page_name ?? "");
                b.set_member_name("page_title");
                b.add_string_value(e.page_title ?? "");
                b.set_member_name("title");
                b.add_string_value(e.title ?? "");
                b.set_member_name("subtitle");
                b.add_string_value(e.subtitle ?? "");
                b.set_member_name("group");
                b.add_string_value(e.group ?? "");
                b.set_member_name("kind");
                b.add_string_value(e.kind.to_string().replace("SINGULARITY_SETTINGS_ENTRY_KIND_", "").down());
                b.end_object();
            }
            b.end_array();
            var g = new Json.Generator();
            g.root = b.get_root();
            return g.to_data(null);
        }

        public void open(string page, string row) throws Error {
            if (page == "" || page.index_of_char('#') >= 0) throw new IOError.INVALID_ARGUMENT("bad page");
            string target = row == "" ? page : page + "#" + row;
            Idle.add(() => {
                app.open_settings_page(target);
                return false;
            });
        }
    }
}
