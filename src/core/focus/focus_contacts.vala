using GLib;

namespace Singularity {

    public class FocusContacts : Object {
        public static string local_dir() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "contacts");
        }

        private static void add_card(Gee.ArrayList<FocusPerson> out_list, Gee.HashSet<string> seen,
                                     Singularity.Accounts.Component card) {
            if (card.name != "VCARD") return;
            string name = card.get_text("FN").strip();
            string[] handles = {};
            foreach (var l in card.get_lines("EMAIL")) {
                string v = l.text.strip();
                if (v != "") handles += v;
            }
            foreach (var l in card.get_lines("TEL")) {
                string v = l.text.strip();
                if (v != "") handles += v;
            }
            if (name == "" && handles.length > 0) name = handles[0];
            if (name == "") return;
            string key = name.down();
            if (seen.contains(key)) return;
            seen.add(key);
            out_list.add(new FocusPerson(name, handles));
        }

        public static Gee.ArrayList<FocusPerson> parse_vcards(string text) {
            var list = new Gee.ArrayList<FocusPerson>();
            var seen = new Gee.HashSet<string>();
            foreach (var c in Singularity.Accounts.Component.parse_all(text)) add_card(list, seen, c);
            return list;
        }

        public static async Gee.ArrayList<FocusPerson> load() {
            var list = new Gee.ArrayList<FocusPerson>();
            var seen = new Gee.HashSet<string>();
            try {
                var dir = Dir.open(local_dir());
                string? n;
                while ((n = dir.read_name()) != null) {
                    if (!n.has_suffix(".vcf")) continue;
                    string text;
                    try {
                        FileUtils.get_contents(Path.build_filename(local_dir(), n), out text);
                    } catch (FileError e) {
                        continue;
                    }
                    foreach (var c in Singularity.Accounts.Component.parse_all(text)) add_card(list, seen, c);
                }
            } catch (FileError e) {
            }
            var tracker = Singularity.Accounts.CollectionTracker.get_shared(Singularity.Accounts.ContentKind.CONTACTS);
            if (!tracker.ready) {
                uint waited = 0;
                while (!tracker.ready && waited < 20) {
                    Timeout.add(100, load.callback);
                    yield;
                    waited++;
                }
            }
            foreach (var set in tracker.get_sets()) {
                foreach (var collection in set.collections) {
                    foreach (var item in collection.items()) {
                        foreach (var c in Singularity.Accounts.Component.parse_all(item.data)) add_card(list, seen, c);
                    }
                }
            }
            list.sort((a, b) => a.name.collate(b.name));
            return list;
        }
    }
}
