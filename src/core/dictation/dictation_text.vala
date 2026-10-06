namespace Singularity.Dictation {

    public class DictationText : Object {
        private const string SENTENCE_END = ".?!";
        private const string ATTACHED = ".,?!:;";

        private struct Command {
            public string phrase;
            public string output;
        }

        private static Command[] english() {
            return {
                { "new paragraph", "\n\n" },
                { "new line", "\n" },
                { "newline", "\n" },
                { "question mark", "?" },
                { "exclamation mark", "!" },
                { "exclamation point", "!" },
                { "full stop", "." },
                { "period", "." },
                { "semicolon", ";" },
                { "colon", ":" },
                { "comma", "," }
            };
        }

        private static Command[] italian() {
            return {
                { "nuovo paragrafo", "\n\n" },
                { "nuova riga", "\n" },
                { "a capo", "\n" },
                { "punto interrogativo", "?" },
                { "punto di domanda", "?" },
                { "punto esclamativo", "!" },
                { "punto e virgola", ";" },
                { "due punti", ":" },
                { "virgola", "," },
                { "punto", "." }
            };
        }

        public static string[] command_languages() {
            return { "en", "it" };
        }

        private static Command[] commands_for(string language) {
            string code = language.down();
            if (code.has_prefix("it")) return italian();
            if (code.has_prefix("en")) return english();
            Command[] all = {};
            foreach (var c in italian()) all += c;
            foreach (var c in english()) all += c;
            return all;
        }

        public static string normalize_word(string word) {
            string result = word.down();
            while (result.length > 0 && is_punctuation(result.get_char(0))) {
                result = result.substring(result.index_of_nth_char(1));
            }
            while (result.length > 0) {
                int last = result.index_of_nth_char(result.char_count() - 1);
                if (!is_punctuation(result.get_char(last))) break;
                result = result.substring(0, last);
            }
            return result;
        }

        private static bool is_punctuation(unichar c) {
            return c == '.' || c == ',' || c == '?' || c == '!' || c == ':' || c == ';'
                || c == '"' || c == '¿' || c == '¡' || c == '…';
        }

        private static string strip_engine_punctuation(string word) {
            string result = word;
            while (result.length > 0) {
                int last = result.index_of_nth_char(result.char_count() - 1);
                unichar c = result.get_char(last);
                if (c != '.' && c != ',' && c != '?' && c != '!' && c != ':' && c != ';' && c != '…') break;
                result = result.substring(0, last);
            }
            return result;
        }

        private static int match_command(string[] words, int start, Command[] commands, out string output) {
            output = "";
            int best = 0;
            foreach (var command in commands) {
                string[] parts = command.phrase.split(" ");
                if (parts.length <= best || start + parts.length > words.length) continue;
                bool matched = true;
                for (int i = 0; i < parts.length; i++) {
                    if (normalize_word(words[start + i]) != parts[i]) {
                        matched = false;
                        break;
                    }
                }
                if (matched) {
                    best = parts.length;
                    output = command.output;
                }
            }
            return best;
        }

        private static bool ends_sentence(string text) {
            string trimmed = text.chomp();
            if (trimmed.length < text.length && text.has_suffix("\n")) return true;
            if (trimmed == "") return true;
            unichar last = trimmed.get_char(trimmed.index_of_nth_char(trimmed.char_count() - 1));
            return SENTENCE_END.index_of_char(last) >= 0;
        }

        private static string capitalize(string word) {
            if (word == "") return word;
            unichar first = word.get_char(0);
            if (!first.islower()) return word;
            return first.toupper().to_string() + word.substring(first.to_string().length);
        }

        private static string trim_end(string text) {
            int end = text.length;
            while (end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t')) end--;
            return text.substring(0, end);
        }

        private static string trim_attached(string text) {
            string result = trim_end(text);
            while (result.length > 0 && ATTACHED.index_of_char(result[result.length - 1]) >= 0) {
                result = result.substring(0, result.length - 1);
            }
            return result;
        }

        public static string format(string raw, string language, bool auto_punctuation, string before) {
            string[] words = {};
            foreach (string w in raw.strip().split_set(" \t\n\r")) {
                if (w != "") words += w;
            }
            var commands = commands_for(language);
            var result = new StringBuilder();
            bool capital = ends_sentence(before);
            int i = 0;
            while (i < words.length) {
                string output;
                int used = match_command(words, i, commands, out output);
                if (used > 0) {
                    if (output.has_prefix("\n")) {
                        string kept = trim_end(result.str);
                        result.truncate(0);
                        result.append(kept);
                        result.append(output);
                    } else {
                        string kept = trim_attached(result.str);
                        result.truncate(0);
                        result.append(kept);
                        result.append(output);
                    }
                    capital = SENTENCE_END.index_of(output) >= 0 || output.has_prefix("\n");
                    i += used;
                    continue;
                }
                string word = auto_punctuation ? words[i] : strip_engine_punctuation(words[i]);
                if (word == "") {
                    i++;
                    continue;
                }
                if (capital) word = capitalize(word);
                if (result.len > 0 && !result.str.has_suffix("\n") && !result.str.has_suffix(" ")) {
                    result.append_c(' ');
                }
                result.append(word);
                capital = auto_punctuation && ends_sentence(word);
                i++;
            }
            string text = result.str;
            if (text == "") return "";
            unichar head = text.get_char(0);
            bool attaches = ATTACHED.index_of_char(head) >= 0 || head == '\n';
            if (!attaches && before != "" && !before.has_suffix(" ") && !before.has_suffix("\n")
                    && !before.has_suffix("\t")) {
                text = " " + text;
            }
            return text;
        }
    }
}
