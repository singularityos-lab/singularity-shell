namespace Singularity.InputMethods {

    public class SintyMethod : Object {
        public string name { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string language { get; set; default = ""; }
        public string kind { get; set; default = ""; }
        public string dictionary { get; set; default = ""; }
        public string[] dictionaries { get; set; default = {}; }
        public string conversion { get; set; default = ""; }
        public string[] conversions { get; set; default = {}; }
        public bool configurable { get; set; }
        public bool fullwidth { get; set; }
        public bool learn { get; set; }
        public uint learned { get; set; }
    }

    public class SintyDictionary : Object {
        public string name { get; set; default = ""; }
        public string kind { get; set; default = ""; }
        public string language { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public string license { get; set; default = ""; }
        public bool user { get; set; }
    }

    public class SintyPhrase : Object {
        public string code { get; set; default = ""; }
        public string text { get; set; default = ""; }
        public int weight { get; set; }
    }

    public class SintyInputSettings : Object {
        private const string BUS_NAME = "dev.sinty.Input1";
        private const string OBJECT_PATH = "/dev/sinty/Input1";

        private static async Variant? call(string method, Variant? args, string? reply) throws Error {
            var bus = yield Bus.get(BusType.SESSION);
            return yield bus.call(BUS_NAME, OBJECT_PATH, BUS_NAME, method, args,
                reply != null ? new VariantType(reply) : null, DBusCallFlags.NONE, 10000, null);
        }

        private static string text(HashTable<string, Variant> options, string key) {
            var v = options[key];
            return v != null && v.is_of_type(VariantType.STRING) ? v.get_string() : "";
        }

        private static string[] strings(HashTable<string, Variant> options, string key) {
            var v = options[key];
            return v != null && v.is_of_type(VariantType.STRING_ARRAY) ? v.get_strv() : new string[0];
        }

        private static bool flag(HashTable<string, Variant> options, string key) {
            var v = options[key];
            return v != null && v.is_of_type(VariantType.BOOLEAN) && v.get_boolean();
        }

        public static async SintyMethod? method(string name) throws Error {
            var reply = yield call("Methods", null, "(a(ssssa{sv}))");
            var list = reply.get_child_value(0);
            for (size_t i = 0; i < list.n_children(); i++) {
                var item = list.get_child_value(i);
                if (item.get_child_value(0).get_string() != name) continue;
                var options = (HashTable<string, Variant>) item.get_child_value(4);
                var m = new SintyMethod();
                m.name = name;
                m.label = item.get_child_value(1).get_string();
                m.language = item.get_child_value(3).get_string();
                m.kind = text(options, "kind");
                m.dictionary = text(options, "dictionary");
                m.dictionaries = strings(options, "dictionaries");
                m.conversion = text(options, "conversion");
                m.conversions = strings(options, "conversions");
                m.configurable = options.contains("learn");
                m.fullwidth = flag(options, "fullwidth");
                m.learn = flag(options, "learn");
                var learned = options["learned"];
                m.learned = learned != null && learned.is_of_type(VariantType.UINT32) ? learned.get_uint32() : 0;
                return m;
            }
            return null;
        }

        public static async void configure(string name, string key, Variant value) throws Error {
            var options = new VariantBuilder(new VariantType("a{sv}"));
            options.add("{sv}", key, value);
            yield call("Configure", new Variant("(sa{sv})", name, options), null);
        }

        public static async Gee.List<SintyDictionary> dictionaries() throws Error {
            var out = new Gee.ArrayList<SintyDictionary>();
            var reply = yield call("Dictionaries", null, "(a(sssssb))");
            var list = reply.get_child_value(0);
            for (size_t i = 0; i < list.n_children(); i++) {
                var item = list.get_child_value(i);
                out.add(new SintyDictionary() {
                    name = item.get_child_value(0).get_string(),
                    kind = item.get_child_value(1).get_string(),
                    language = item.get_child_value(2).get_string(),
                    title = item.get_child_value(3).get_string(),
                    license = item.get_child_value(4).get_string(),
                    user = item.get_child_value(5).get_boolean()
                });
            }
            return out;
        }

        public static async Gee.List<SintyPhrase> phrases(string name) throws Error {
            var out = new Gee.ArrayList<SintyPhrase>();
            var reply = yield call("UserEntries", new Variant("(s)", name), "(a(ssi))");
            var list = reply.get_child_value(0);
            for (size_t i = 0; i < list.n_children(); i++) {
                var item = list.get_child_value(i);
                out.add(new SintyPhrase() {
                    code = item.get_child_value(0).get_string(),
                    text = item.get_child_value(1).get_string(),
                    weight = item.get_child_value(2).get_int32()
                });
            }
            return out;
        }

        public static async void add_phrase(string name, string code, string text) throws Error {
            yield call("UserSet", new Variant("(sssi)", name, code, text, 1), null);
        }

        public static async void remove_phrase(string name, string code, string text) throws Error {
            yield call("UserRemove", new Variant("(sss)", name, code, text), null);
        }

        public static async void clear_phrases(string name) throws Error {
            yield call("UserClear", new Variant("(s)", name), null);
        }

        public static async void export_phrases(string name, string path) throws Error {
            yield call("UserExport", new Variant("(ss)", name, path), null);
        }

        public static async uint import_phrases(string name, string path) throws Error {
            var reply = yield call("UserImport", new Variant("(ss)", name, path), "(u)");
            return reply.get_child_value(0).get_uint32();
        }

        public static async string add_table(string path, string title, string language, string license) throws Error {
            var reply = yield call("AddDictionary", new Variant("(ssss)", path, title, language, license), "(s)");
            return reply.get_child_value(0).get_string();
        }

        public static async void remove_table(string name) throws Error {
            yield call("RemoveDictionary", new Variant("(s)", name), null);
        }

        public static string message(Error e) {
            DBusError.strip_remote_error(e);
            return e.message;
        }
    }
}
