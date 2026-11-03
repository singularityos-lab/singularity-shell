namespace Singularity {

    internal class AnswerMarkup : Object {

        public static string to_pango(string text) {
            var out_ = new StringBuilder();
            bool in_code = false;
            bool first = true;
            foreach (unowned string raw in text.split("\n")) {
                string line = raw.replace("\r", "");
                string trimmed = line.strip();
                if (trimmed.has_prefix("```")) {
                    in_code = !in_code;
                    continue;
                }
                if (!first) out_.append_c('\n');
                first = false;
                if (in_code) {
                    out_.append("<tt>%s</tt>".printf(Markup.escape_text(line)));
                    continue;
                }
                out_.append(block(line, trimmed));
            }
            return out_.str;
        }

        private static string block(string line, string trimmed) {
            int level = 0;
            while (level < trimmed.length && trimmed[level] == '#') level++;
            if (level > 0 && level <= 6 && level < trimmed.length && trimmed[level] == ' ') {
                string size = level == 1 ? "x-large" : level == 2 ? "large" : "medium";
                return "<span size=\"%s\" weight=\"bold\">%s</span>".printf(size, inline(trimmed.substring(level + 1)));
            }
            if (trimmed == "---" || trimmed == "***" || trimmed == "___") return "";
            if (trimmed.has_prefix("> ")) return "<i>%s</i>".printf(inline(trimmed.substring(2)));
            int indent = 0;
            while (indent < line.length && line[indent] == ' ') indent++;
            string pad = string.nfill(indent / 2 * 2, ' ');
            if (trimmed.has_prefix("- ") || trimmed.has_prefix("* ") || trimmed.has_prefix("+ ")) {
                string rest = trimmed.substring(2);
                return pad + "• " + inline(rest);
            }
            int digits = 0;
            while (digits < trimmed.length && trimmed[digits].isdigit()) digits++;
            if (digits > 0 && digits + 1 < trimmed.length && (trimmed[digits] == '.' || trimmed[digits] == ')') && trimmed[digits + 1] == ' ')
                return pad + Markup.escape_text(trimmed.substring(0, digits + 1)) + " " + inline(trimmed.substring(digits + 2));
            return inline(line);
        }

        private static string inline(string text) {
            var out_ = new StringBuilder();
            int i = 0;
            int n = text.length;
            while (i < n) {
                char ch = text[i];
                if (ch == '\\' && i + 1 < n && "\\`*_[]()#+-.!".index_of_char(text[i + 1]) >= 0) {
                    out_.append(Markup.escape_text(text.substring(i + 1, 1)));
                    i += 2;
                    continue;
                }
                if (ch == '`') {
                    int end = text.index_of_char('`', i + 1);
                    if (end > i) {
                        out_.append("<tt>%s</tt>".printf(Markup.escape_text(text.substring(i + 1, end - i - 1))));
                        i = end + 1;
                        continue;
                    }
                }
                if ((ch == '*' || ch == '_') && i + 1 < n && text[i + 1] == ch) {
                    string mark = text.substring(i, 2);
                    int end = text.index_of(mark, i + 2);
                    if (end > i + 2) {
                        out_.append("<b>%s</b>".printf(inline(text.substring(i + 2, end - i - 2))));
                        i = end + 2;
                        continue;
                    }
                }
                if ((ch == '*' || ch == '_') && i + 1 < n && text[i + 1] != ' ' && (ch == '*' || i == 0 || !text[i - 1].isalnum())) {
                    int end = text.index_of_char(ch, i + 1);
                    if (end > i + 1 && text[end - 1] != ' ' && (ch == '*' || end + 1 >= n || !text[end + 1].isalnum())) {
                        out_.append("<i>%s</i>".printf(inline(text.substring(i + 1, end - i - 1))));
                        i = end + 1;
                        continue;
                    }
                }
                if (ch == '~' && i + 1 < n && text[i + 1] == '~') {
                    int end = text.index_of("~~", i + 2);
                    if (end > i + 2) {
                        out_.append("<s>%s</s>".printf(inline(text.substring(i + 2, end - i - 2))));
                        i = end + 2;
                        continue;
                    }
                }
                if (ch == '[') {
                    int close = text.index_of("](", i + 1);
                    int paren = close > 0 ? text.index_of_char(')', close + 2) : -1;
                    if (close > i && paren > close) {
                        string label = text.substring(i + 1, close - i - 1);
                        string url = text.substring(close + 2, paren - close - 2);
                        out_.append("<a href=\"%s\">%s</a>".printf(Markup.escape_text(url), inline(label)));
                        i = paren + 1;
                        continue;
                    }
                }
                int next = i + 1;
                while (next < n && "\\`*_~[".index_of_char(text[next]) < 0) next++;
                out_.append(Markup.escape_text(text.substring(i, next - i)));
                i = next;
            }
            return out_.str;
        }
    }
}
