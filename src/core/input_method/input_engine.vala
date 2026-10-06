namespace Singularity.InputMethods {

    public const uint STATE_SHIFT = 1 << 0;
    public const uint STATE_LOCK = 1 << 1;
    public const uint STATE_CONTROL = 1 << 2;
    public const uint STATE_ALT = 1 << 3;
    public const uint STATE_SUPER = 1 << 6;
    public const uint IBUS_RELEASE = 1 << 30;

    public class EngineInfo : Object {
        public string framework { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string symbol { get; set; default = ""; }
        public string language { get; set; default = ""; }

        public string id {
            owned get { return framework + ":" + name; }
        }

        public string short_label() {
            if (symbol != "") return symbol;
            if (language.length >= 2) return language.substring(0, 2).up();
            return label.length > 0 ? label.substring(0, label.index_of_nth_char(int.min(2, label.char_count()))) : "?";
        }
    }

    public class Candidates : Object {
        public string[] items = {};
        public string[] labels = {};
        public int selected { get; set; default = -1; }
        public bool has_previous { get; set; default = false; }
        public bool has_next { get; set; default = false; }
        public string auxiliary { get; set; default = ""; }
        public bool vertical { get; set; default = false; }

        public bool empty {
            get { return items.length == 0; }
        }
    }

    public class Serial : Object {
        public static string ibus_text(Variant value) {
            Variant v = value;
            while (v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (v.is_of_type(VariantType.STRING)) return v.get_string();
            if (!v.is_container() || v.n_children() < 3) return "";
            var name = v.get_child_value(0);
            if (!name.is_of_type(VariantType.STRING) || name.get_string() != "IBusText") return "";
            var text = v.get_child_value(2);
            return text.is_of_type(VariantType.STRING) ? text.get_string() : "";
        }

        public static Variant ibus_text_variant(string text) {
            var attributes = new VariantBuilder(new VariantType("a{sv}"));
            var attr_list = new Variant("(sa{sv}av)", "IBusAttrList", new VariantBuilder(new VariantType("a{sv}")), new VariantBuilder(new VariantType("av")));
            return new Variant.variant(new Variant("(sa{sv}sv)", "IBusText", attributes, text, attr_list));
        }

        public static Candidates? ibus_table(Variant value) {
            Variant v = value;
            while (v.is_of_type(VariantType.VARIANT)) v = v.get_variant();
            if (!v.is_container() || v.n_children() < 9) return null;
            var name = v.get_child_value(0);
            if (!name.is_of_type(VariantType.STRING) || name.get_string() != "IBusLookupTable") return null;
            uint page_size = v.get_child_value(2).get_uint32();
            uint cursor = v.get_child_value(3).get_uint32();
            bool cursor_visible = v.get_child_value(4).get_boolean();
            int orientation = v.get_child_value(6).get_int32();
            var all = v.get_child_value(7);
            var label_values = v.get_child_value(8);
            if (page_size == 0) page_size = 5;
            uint total = (uint) all.n_children();
            uint start = total > page_size ? (cursor / page_size) * page_size : 0;
            uint end = uint.min(start + page_size, total);
            var result = new Candidates();
            string[] items = {};
            string[] labels = {};
            for (uint i = start; i < end; i++) {
                items += ibus_text(all.get_child_value(i));
                uint label_index = i - start;
                string label = label_index < label_values.n_children()
                    ? ibus_text(label_values.get_child_value(label_index)) : "";
                labels += label != "" ? label : "%u".printf((label_index + 1) % 10);
            }
            result.items = items;
            result.labels = labels;
            result.selected = cursor_visible && cursor >= start && cursor < end ? (int) (cursor - start) : -1;
            result.has_previous = start > 0;
            result.has_next = end < total;
            result.vertical = orientation == 1;
            return result;
        }

        public static string fcitx_formatted(Variant value) {
            var text = new StringBuilder();
            for (size_t i = 0; i < value.n_children(); i++) {
                var item = value.get_child_value(i);
                text.append(item.get_child_value(0).get_string());
            }
            return text.str;
        }

        public static Candidates fcitx_candidates(Variant list, int index, bool has_previous, bool has_next,
                                                  int layout, string auxiliary) {
            var result = new Candidates();
            string[] items = {};
            string[] labels = {};
            for (size_t i = 0; i < list.n_children(); i++) {
                var pair = list.get_child_value(i);
                string label = pair.get_child_value(0).get_string().strip();
                if (label.has_suffix(".")) label = label.substring(0, label.length - 1);
                labels += label != "" ? label : "%d".printf((int) ((i + 1) % 10));
                items += pair.get_child_value(1).get_string();
            }
            result.items = items;
            result.labels = labels;
            result.selected = index;
            result.has_previous = has_previous;
            result.has_next = has_next;
            result.vertical = layout == 1;
            result.auxiliary = auxiliary;
            return result;
        }

        public static EngineInfo[] parse_ibus_component(string xml) {
            EngineInfo[] result = {};
            int pos = 0;
            while (true) {
                int start = xml.index_of("<engine>", pos);
                if (start < 0) break;
                int end = xml.index_of("</engine>", start);
                if (end < 0) break;
                string block = xml.substring(start, end - start);
                var info = new EngineInfo();
                info.framework = "ibus";
                info.name = tag(block, "name");
                info.label = tag(block, "longname");
                info.symbol = tag(block, "symbol");
                info.language = tag(block, "language");
                if (info.label == "") info.label = info.name;
                if (info.name != "" && !info.name.has_prefix("xkb:")) result += info;
                pos = end + 9;
            }
            return result;
        }

        private static string tag(string block, string name) {
            string open = "<" + name + ">";
            int start = block.index_of(open);
            if (start < 0) return "";
            start += open.length;
            int end = block.index_of("</" + name + ">", start);
            if (end < 0) return "";
            return unescape(block.substring(start, end - start).strip());
        }

        private static string unescape(string text) {
            var result = new StringBuilder();
            int i = 0;
            while (i < text.length) {
                if (text[i] == '&' && i + 2 < text.length && text[i + 1] == '#') {
                    int end = text.index_of_char(';', i);
                    if (end > i) {
                        string number = text.substring(i + 2, end - i - 2);
                        int64 code = 0;
                        unowned string rest;
                        bool hex = number.has_prefix("x") || number.has_prefix("X");
                        bool ok = int64.try_parse(hex ? number.substring(1) : number, out code, out rest, hex ? 16 : 10);
                        if (ok && code > 0) {
                            result.append_unichar((unichar) code);
                            i = end + 1;
                            continue;
                        }
                    }
                }
                result.append_c(text[i]);
                i++;
            }
            return result.str.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
                .replace("&apos;", "'").replace("&amp;", "&");
        }

        public static EngineInfo? parse_fcitx_conf(string name, string contents) {
            var file = new KeyFile();
            try {
                file.load_from_data(contents, -1, KeyFileFlags.NONE);
                if (!file.has_group("InputMethod")) return null;
                var info = new EngineInfo();
                info.framework = "fcitx5";
                info.name = name;
                info.label = file.has_key("InputMethod", "Name") ? file.get_string("InputMethod", "Name") : name;
                info.symbol = file.has_key("InputMethod", "Label") ? file.get_string("InputMethod", "Label") : "";
                info.language = file.has_key("InputMethod", "LangCode") ? file.get_string("InputMethod", "LangCode") : "";
                return info;
            } catch (Error e) {
                return null;
            }
        }
    }

    public abstract class InputEngine : Object {
        public signal void commit(string text);
        public signal void preedit(string text, int cursor);
        public signal void candidates(Candidates? list);
        public signal void forward_key(uint keysym, uint keycode, uint state);
        public signal void delete_surrounding(int offset, uint count);
        public signal void lost();

        public abstract string framework { get; }
        public abstract async bool process_key(uint keysym, uint keycode, uint state, bool release);
        public abstract async void select_engine(string name) throws Error;
        public abstract void focus_in();
        public abstract void focus_out();
        public abstract void reset();
        public abstract void set_surrounding(string text, uint cursor);
        public abstract void select_candidate(int index);
        public abstract void change_page(bool next);
    }

    public abstract class Framework : Object {
        public abstract string id { get; }
        public abstract string display_name { get; }
        public abstract bool installed();
        public abstract EngineInfo[] engines();
        public abstract async InputEngine? connect_engine() throws Error;
        public abstract void shutdown();

        protected static string[] data_dirs() {
            string[] dirs = { Environment.get_user_data_dir() };
            foreach (string dir in Environment.get_system_data_dirs()) {
                if (!(dir in dirs)) dirs += dir;
            }
            return dirs;
        }

        protected static async void wait_ms(uint ms) {
            Timeout.add(ms, wait_ms.callback);
            yield;
        }
    }
}
