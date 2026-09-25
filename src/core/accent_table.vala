namespace Singularity {

    public class AccentTable : Object {
        private static Gee.HashMap<string, Gee.ArrayList<string>>? table = null;

        private const string[] EXTRAS = {
            "a", "æ", "a", "ª", "o", "ø", "o", "œ", "o", "º", "s", "ß", "d", "đ", "d", "ð",
            "l", "ł", "t", "þ", "t", "ŧ", "h", "ħ", "g", "ǥ", "i", "ı", "n", "ŋ", "k", "ĸ",
            "z", "ƶ", "b", "ƀ", "e", "ə", "y", "ɏ", "j", "ɉ", "r", "ɍ", "c", "ȼ",
        };

        public static string[] variants(unichar c) {
            ensure_table();
            bool upper = c.isupper();
            string key = c.tolower().to_string();
            var list = table.get(key);
            if (list == null) return {};
            string[] result = {};
            foreach (string item in list) {
                string variant = upper ? item.up() : item;
                if (!(variant in result)) result += variant;
            }
            return result;
        }

        private static void add(string key, string value) {
            var list = table.get(key);
            if (list == null) {
                list = new Gee.ArrayList<string>();
                table.set(key, list);
            }
            if (!list.contains(value)) list.add(value);
        }

        private static void add_range(unichar first, unichar last) {
            for (unichar c = first; c <= last; c++) {
                if (!c.isdefined() || !c.isalpha() || c.isupper()) continue;
                unichar[] parts = new unichar[18];
                size_t n = c.fully_decompose(false, parts);
                if (n < 2) continue;
                unichar base_char = parts[0];
                if (base_char < 'a' || base_char > 'z') continue;
                add(base_char.to_string(), c.to_string());
            }
        }

        private static void ensure_table() {
            if (table != null) return;
            table = new Gee.HashMap<string, Gee.ArrayList<string>>();
            add_range(0x00E0, 0x00FF);
            for (int i = 0; i + 1 < EXTRAS.length; i += 2) add(EXTRAS[i], EXTRAS[i + 1]);
            add_range(0x0100, 0x024F);
            add_range(0x1E00, 0x1EFF);
        }
    }
}
