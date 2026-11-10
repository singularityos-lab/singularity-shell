namespace Singularity {

    public struct ProcStat {
        public int pid;
        public string comm;
        public uint64 cpu_ticks;
        public uint64 start_ticks;
        public uint64 rss_pages;
    }

    namespace ProcStats {
        public bool parse(string stat, out ProcStat result) {
            result = ProcStat();
            int open = stat.index_of_char('(');
            int close = stat.last_index_of_char(')');
            if (open < 1 || close < open) return false;
            result.pid = int.parse(stat.substring(0, open).strip());
            result.comm = stat.substring(open + 1, close - open - 1);
            string[] f = stat.substring(close + 1).strip().split(" ");
            if (f.length < 22) return false;
            result.cpu_ticks = uint64.parse(f[11]) + uint64.parse(f[12]);
            result.start_ticks = uint64.parse(f[19]);
            result.rss_pages = uint64.parse(f[21]);
            return result.pid > 0;
        }

        public double cpu_percent(ProcStat s, double uptime_seconds, double hz) {
            double alive = uptime_seconds - s.start_ticks / hz;
            if (alive <= 0) return 0.0;
            return 100.0 * (s.cpu_ticks / hz) / alive;
        }

        public GenericArray<ProcStat?> snapshot(string root = "/proc") {
            var list = new GenericArray<ProcStat?>();
            try {
                var dir = Dir.open(root);
                string? name;
                while ((name = dir.read_name()) != null) {
                    if (!name[0].isdigit()) continue;
                    string text;
                    try {
                        FileUtils.get_contents(Path.build_filename(root, name, "stat"), out text);
                    } catch (FileError e) {
                        continue;
                    }
                    ProcStat s;
                    if (parse(text, out s)) list.add(s);
                }
            } catch (FileError e) {
            }
            return list;
        }

        public double uptime(string root = "/proc") {
            string text;
            try {
                FileUtils.get_contents(Path.build_filename(root, "uptime"), out text);
            } catch (FileError e) {
                return 0.0;
            }
            return double.parse(text.split(" ")[0]);
        }
    }
}
