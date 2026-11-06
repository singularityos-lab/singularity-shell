using GLib;

namespace Singularity {

    public class SettingsSearchProvider : GLib.Object, SearchProvider {
        public string id { get { return "settings"; } }
        public string name { get { return "Settings"; } }

        private bool warm_started = false;

        public SettingsSearchProvider() {
            Object();
        }

        public async List<SearchResult> search(string query, Cancellable? cancellable) throws Error {
            var results = new List<SearchResult>();
            string q = query.strip().down();
            if (q.length < 3) return results;
            var app = GLib.Application.get_default() as SingularityApp;
            if (app == null) return results;

            if (_("Settings").down().has_prefix(q) || "settings".has_prefix(q)) {
                var home = new SearchResult(this, _("Settings"), _("System settings"), "preferences-system-symbolic");
                home.score = q == "settings" || q == _("Settings").down() ? 100.0 : 90.0;
                home.activated.connect(() => app.open_settings_page("home"));
                results.append(home);
            }

            int count = 0;
            if (!warm_started) {
                warm_started = true;
                app.warm_settings_index.begin();
            }
            foreach (var entry in app.cached_settings_entries()) {
                double score = 0.0;
                string title = entry.title.down();
                if (title.has_prefix(q)) score = 70.0;
                else if (title.contains(q)) score = 50.0;
                else if ("%s %s %s".printf(entry.subtitle, entry.group, entry.page_title).down().contains(q)) score = 30.0;
                if (score == 0.0) continue;
                string path = entry.group != "" ? "%s / %s".printf(entry.page_title, entry.group) : entry.page_title;
                var res = new SearchResult(this, entry.title, path, entry.icon_name);
                res.score = score;
                var target = entry;
                res.activated.connect(() => app.reveal_setting(target, target.kind == SettingsEntryKind.LAUNCH));
                results.append(res);
                if (++count >= 8) break;
            }
            return results;
        }
    }
}
