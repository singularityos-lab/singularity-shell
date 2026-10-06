using GLib;

namespace Singularity {

    public class ClipboardEntry : Object {
        public uint id { get; construct; }
        public string mime { get; construct; }
        public Bytes data { get; construct; }
        public string digest { get; construct; }
        public bool pinned { get; set; default = false; }
        public int64 timestamp { get; set; default = 0; }

        public ClipboardEntry(uint id, string mime, Bytes data, int64 timestamp) {
            Object(id: id, mime: mime, data: data,
                digest: Checksum.compute_for_bytes(ChecksumType.SHA256, data), timestamp: timestamp);
        }

        public bool is_image { get { return mime.has_prefix("image/"); } }

        public string text {
            owned get {
                if (is_image) return "";
                size_t len = data.get_size();
                var buf = new uint8[len + 1];
                Memory.copy(buf, data.get_data(), len);
                buf[len] = 0;
                string t = ((string) buf).dup();
                return t.validate() ? t : t.make_valid();
            }
        }

        public string preview(int max_chars) {
            string t = text.strip().replace("\r", "").replace("\t", " ");
            string[] lines = t.split("\n");
            string first = "";
            int shown = 0;
            foreach (string l in lines) {
                if (l.strip() == "") continue;
                first = first == "" ? l.strip() : first + " " + l.strip();
                if (++shown >= 3) break;
            }
            if (first.char_count() > max_chars) {
                first = first.substring(0, first.index_of_nth_char(max_chars)) + "…";
            }
            return first;
        }

        public bool matches(string query) {
            string q = query.strip().down();
            if (q == "") return true;
            if (is_image) return "image".contains(q) || mime.contains(q);
            return text.down().contains(q);
        }
    }

    public class ClipboardModel : Object {
        public const int DEFAULT_LIMIT = 50;

        public Gee.ArrayList<ClipboardEntry> entries { get; private set; default = new Gee.ArrayList<ClipboardEntry>(); }
        public int limit { get; set; default = DEFAULT_LIMIT; }
        private uint _next_id = 1;

        public signal void changed();

        public static bool is_text_mime(string mime) {
            return mime.has_prefix("text/") || mime == "UTF8_STRING" || mime == "STRING" || mime == "TEXT";
        }

        public ClipboardEntry? add(string mime, Bytes data, int64 timestamp) {
            if (data.get_size() == 0) return null;
            bool text = is_text_mime(mime);
            if (!text && !mime.has_prefix("image/")) return null;
            string m = text ? "text/plain;charset=utf-8" : mime;
            var entry = new ClipboardEntry(_next_id++, m, data, timestamp);
            if (text && entry.text.strip() == "") return null;
            foreach (var e in entries) {
                if (e.digest == entry.digest) {
                    entries.remove(e);
                    e.timestamp = timestamp;
                    entries.insert(0, e);
                    changed();
                    return e;
                }
            }
            entries.insert(0, entry);
            trim();
            changed();
            return entry;
        }

        private void trim() {
            int unpinned = 0;
            var drop = new Gee.ArrayList<ClipboardEntry>();
            foreach (var e in entries) {
                if (e.pinned) continue;
                unpinned++;
                if (unpinned > limit) drop.add(e);
            }
            foreach (var e in drop) entries.remove(e);
        }

        public ClipboardEntry? find(uint id) {
            foreach (var e in entries) {
                if (e.id == id) return e;
            }
            return null;
        }

        public void set_pinned(uint id, bool pinned) {
            var e = find(id);
            if (e == null || e.pinned == pinned) return;
            e.pinned = pinned;
            trim();
            changed();
        }

        public void remove(uint id) {
            var e = find(id);
            if (e == null) return;
            entries.remove(e);
            changed();
        }

        public void clear(bool keep_pinned = true) {
            var kept = new Gee.ArrayList<ClipboardEntry>();
            if (keep_pinned) {
                foreach (var e in entries) {
                    if (e.pinned) kept.add(e);
                }
            }
            entries = kept;
            changed();
        }

        public Gee.ArrayList<ClipboardEntry> ordered(string query) {
            var pinned = new Gee.ArrayList<ClipboardEntry>();
            var rest = new Gee.ArrayList<ClipboardEntry>();
            foreach (var e in entries) {
                if (!e.matches(query)) continue;
                if (e.pinned) pinned.add(e);
                else rest.add(e);
            }
            pinned.add_all(rest);
            return pinned;
        }

        public string pinned_to_json(string image_dir) {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("version"); b.add_int_value(1);
            b.set_member_name("pinned");
            b.begin_array();
            foreach (var e in entries) {
                if (!e.pinned) continue;
                b.begin_object();
                b.set_member_name("mime"); b.add_string_value(e.mime);
                b.set_member_name("timestamp"); b.add_int_value(e.timestamp);
                if (e.is_image) {
                    string path = Path.build_filename(image_dir, e.digest + ".img");
                    try {
                        FileUtils.set_data(path, e.data.get_data());
                    } catch (FileError err) {
                        warning("clipboard: could not keep pinned image: %s", err.message);
                    }
                    b.set_member_name("file"); b.add_string_value(e.digest + ".img");
                } else {
                    b.set_member_name("text"); b.add_string_value(e.text);
                }
                b.end_object();
            }
            b.end_array();
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            return gen.to_data(null);
        }

        public void load_pinned(string json, string image_dir) {
            try {
                var parser = new Json.Parser();
                parser.load_from_data(json);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
                var o = root.get_object();
                if (!o.has_member("pinned")) return;
                var items = new Gee.ArrayList<ClipboardEntry>();
                o.get_array_member("pinned").foreach_element((a, i, n) => {
                    if (n.get_node_type() != Json.NodeType.OBJECT) return;
                    var p = n.get_object();
                    string mime = p.has_member("mime") ? p.get_string_member("mime") : "text/plain;charset=utf-8";
                    int64 ts = p.has_member("timestamp") ? p.get_int_member("timestamp") : 0;
                    Bytes? data = null;
                    if (p.has_member("text")) {
                        data = new Bytes(p.get_string_member("text").data);
                    } else if (p.has_member("file")) {
                        string name = Path.get_basename(p.get_string_member("file"));
                        uint8[] raw;
                        try {
                            if (FileUtils.get_data(Path.build_filename(image_dir, name), out raw)) data = new Bytes(raw);
                        } catch (FileError err) {
                        }
                    }
                    if (data == null || data.get_size() == 0) return;
                    var e = new ClipboardEntry(_next_id++, mime, data, ts);
                    e.pinned = true;
                    items.add(e);
                });
                foreach (var e in items) {
                    bool dup = false;
                    foreach (var x in entries) {
                        if (x.digest == e.digest) {
                            x.pinned = true;
                            dup = true;
                        }
                    }
                    if (!dup) entries.add(e);
                }
                changed();
            } catch (Error e) {
                warning("clipboard: unreadable pinned items: %s", e.message);
            }
        }
    }
}
