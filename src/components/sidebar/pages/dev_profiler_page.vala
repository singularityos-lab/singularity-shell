using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class DevProfilerPage : SettingsPage {
        private const uint INTERVAL_MS = 500;
        private const int TOP = 15;

        private class Sample : Object {
            public string name;
            public uint64 last_ticks;
            public double sum;
            public double peak;
            public int count;
            public uint64 rss_kb;
            public Gee.HashMap<int, Sample> threads = new Gee.HashMap<int, Sample> ();
        }

        private Button record_btn;
        private Label status;
        private SparkLine cpu_line;
        private SparkLine mem_line;
        private PreferencesGroup results;
        private Gee.ArrayList<Widget> result_rows = new Gee.ArrayList<Widget> ();
        private Gee.HashMap<int, Sample> procs = new Gee.HashMap<int, Sample> ();
        private uint64 last_total;
        private int64 started;
        private uint timer;
        private int ncpu;
        private long page_kb;
        private Label perf_output;
        private Button perf_btn;

        public DevProfilerPage (SettingsView view) {
            base (_("Profiler"));
            back_btn.visible = true;
            back_clicked.connect (() => {
                stop ();
                view.navigate_to ("developer");
            });
            ncpu = (int) get_num_processors ();
            page_kb = Posix.sysconf (Posix._SC_PAGESIZE) / 1024;

            var control = new PreferencesGroup (_("Recording"));
            control.description = _("Samples every process twice a second and ranks what used the processor while recording.");
            var row = new ActionRow (_("System Activity"), _("Not recording"));
            status = new Label ("");
            status.add_css_class ("dim-label");
            status.valign = Align.CENTER;
            row.add_suffix (status);
            record_btn = new Button.with_label (_("Record"));
            record_btn.add_css_class ("pill");
            record_btn.add_css_class ("suggested-action");
            record_btn.valign = Align.CENTER;
            record_btn.clicked.connect (() => {
                if (timer != 0) stop ();
                else start ();
            });
            row.add_suffix (record_btn);
            row.set_data<ActionRow> ("row", row);
            control.add_row (row);
            add_group (control);

            var charts = new PreferencesGroup (_("Timeline"));
            var cpu_row = new ActionRow (_("Processor"), _("Total use of all cores"));
            cpu_line = new SparkLine (120);
            cpu_line.set_size_request (220, 36);
            cpu_row.add_suffix (cpu_line);
            charts.add_row (cpu_row);
            var mem_row = new ActionRow (_("Memory"), _("Used memory"));
            mem_line = new SparkLine (120);
            mem_line.set_size_request (220, 36);
            mem_row.add_suffix (mem_line);
            charts.add_row (mem_row);
            add_group (charts);

            results = new PreferencesGroup (_("Busiest Processes"));
            results.description = _("Start a recording to see which processes and threads use the processor.");
            add_group (results);

            var perf_group = new PreferencesGroup (_("Call Stacks"));
            bool have_perf = Environment.find_program_in_path ("perf") != null;
            perf_group.description = have_perf
                ? _("Samples the call stacks of the whole system for ten seconds with perf and lists the hottest functions.")
                : _("Install perf to sample call stacks and find the hottest functions.");
            var perf_row = new ActionRow (_("Capture Call Stacks"), _("Ten seconds"));
            perf_btn = new Button.with_label (_("Capture"));
            perf_btn.add_css_class ("pill");
            perf_btn.valign = Align.CENTER;
            perf_btn.sensitive = have_perf;
            perf_btn.clicked.connect (() => capture_perf.begin ());
            perf_row.add_suffix (perf_btn);
            perf_group.add_row (perf_row);
            perf_output = new Label ("");
            perf_output.add_css_class ("monospace");
            perf_output.xalign = 0;
            perf_output.selectable = true;
            perf_output.wrap = true;
            perf_output.wrap_mode = Pango.WrapMode.CHAR;
            perf_output.visible = false;
            perf_output.margin_start = 12;
            perf_output.margin_end = 12;
            perf_output.margin_top = 8;
            add_group (perf_group);
            add_widget (perf_output);

            unmap.connect (stop);
        }

        private void start () {
            procs.clear ();
            last_total = read_total ();
            started = get_monotonic_time ();
            record_btn.label = _("Stop");
            record_btn.remove_css_class ("suggested-action");
            record_btn.add_css_class ("destructive-action");
            sample ();
            timer = Timeout.add (INTERVAL_MS, () => {
                sample ();
                return Source.CONTINUE;
            });
        }

        private void stop () {
            if (timer == 0) return;
            Source.remove (timer);
            timer = 0;
            record_btn.label = _("Record");
            record_btn.remove_css_class ("destructive-action");
            record_btn.add_css_class ("suggested-action");
            render ();
        }

        private static uint64 read_total () {
            try {
                string text;
                FileUtils.get_contents ("/proc/stat", out text);
                string line = text.split ("\n")[0];
                uint64 total = 0;
                string[] parts = line.split (" ");
                for (int i = 1; i < parts.length; i++) {
                    if (parts[i] == "") continue;
                    total += uint64.parse (parts[i]);
                }
                return total;
            } catch (Error e) {
                return 0;
            }
        }

        private static bool read_stat (string path, out string comm, out uint64 ticks, out uint64 rss_pages) {
            comm = "";
            ticks = 0;
            rss_pages = 0;
            string text;
            try {
                FileUtils.get_contents (path, out text);
            } catch (Error e) {
                return false;
            }
            int open = text.index_of_char ('(');
            int close = text.last_index_of_char (')');
            if (open < 0 || close < 0) return false;
            comm = text.substring (open + 1, close - open - 1);
            string[] f = text.substring (close + 2).split (" ");
            if (f.length < 22) return false;
            ticks = uint64.parse (f[11]) + uint64.parse (f[12]);
            rss_pages = uint64.parse (f[21]);
            return true;
        }

        private void sample () {
            uint64 total = read_total ();
            double delta_total = (double) (total - last_total);
            last_total = total;
            double busy_sum = 0;
            try {
                var dir = Dir.open ("/proc");
                string? n;
                while ((n = dir.read_name ()) != null) {
                    int pid = int.parse (n);
                    if (pid <= 0) continue;
                    string comm;
                    uint64 ticks, rss;
                    if (!read_stat ("/proc/%d/stat".printf (pid), out comm, out ticks, out rss)) continue;
                    Sample s;
                    if (!procs.has_key (pid)) {
                        s = new Sample ();
                        s.name = comm;
                        s.last_ticks = ticks;
                        procs[pid] = s;
                        continue;
                    }
                    s = procs[pid];
                    double pct = delta_total > 0 ? (ticks - s.last_ticks) / (delta_total / ncpu) * 100.0 : 0;
                    s.last_ticks = ticks;
                    s.sum += pct;
                    s.count++;
                    s.peak = double.max (s.peak, pct);
                    s.rss_kb = rss * page_kb;
                    busy_sum += pct;
                    if (s.count > 1 && s.sum / s.count > 1.0) sample_threads (pid, s, delta_total);
                }
            } catch (Error e) {
            }
            cpu_line.push (double.min (100, busy_sum / ncpu));
            mem_line.push (memory_used_percent ());
            int secs = (int) ((get_monotonic_time () - started) / 1000000);
            status.label = "%d:%02d".printf (secs / 60, secs % 60);
            if (secs % 2 == 0) render ();
        }

        private void sample_threads (int pid, Sample proc, double delta_total) {
            try {
                var dir = Dir.open ("/proc/%d/task".printf (pid));
                string? n;
                while ((n = dir.read_name ()) != null) {
                    int tid = int.parse (n);
                    string comm;
                    uint64 ticks, rss;
                    if (!read_stat ("/proc/%d/task/%d/stat".printf (pid, tid), out comm, out ticks, out rss)) continue;
                    if (!proc.threads.has_key (tid)) {
                        var t = new Sample ();
                        t.name = comm;
                        t.last_ticks = ticks;
                        proc.threads[tid] = t;
                        continue;
                    }
                    var t = proc.threads[tid];
                    double pct = delta_total > 0 ? (ticks - t.last_ticks) / (delta_total / ncpu) * 100.0 : 0;
                    t.last_ticks = ticks;
                    t.sum += pct;
                    t.count++;
                    t.peak = double.max (t.peak, pct);
                }
            } catch (Error e) {
            }
        }

        private static double memory_used_percent () {
            try {
                string text;
                FileUtils.get_contents ("/proc/meminfo", out text);
                double total = 0, available = 0;
                foreach (string line in text.split ("\n")) {
                    if (line.has_prefix ("MemTotal:")) total = double.parse (line.substring (9).strip ().split (" ")[0]);
                    else if (line.has_prefix ("MemAvailable:")) available = double.parse (line.substring (13).strip ().split (" ")[0]);
                }
                return total > 0 ? (total - available) / total * 100 : 0;
            } catch (Error e) {
                return 0;
            }
        }

        private void render () {
            foreach (var w in result_rows) results.remove_row (w);
            result_rows.clear ();
            var list = new Gee.ArrayList<Gee.Map.Entry<int, Sample>> ();
            foreach (var e in procs.entries) if (e.value.count > 0) list.add (e);
            list.sort ((a, b) => {
                double av = a.value.sum / a.value.count, bv = b.value.sum / b.value.count;
                return av < bv ? 1 : (av > bv ? -1 : 0);
            });
            results.description = list.size == 0
                ? _("Start a recording to see which processes and threads use the processor.")
                : _("Average and peak use of one core while recording.");
            for (int i = 0; i < int.min (TOP, list.size); i++) {
                var e = list[i];
                var s = e.value;
                var exp = new ExpanderRow ("%s  (%d)".printf (s.name, e.key),
                    _("%.1f%% average, %.0f%% peak, %s memory").printf (s.sum / s.count, s.peak, format_size (s.rss_kb * 1024)));
                var threads = new Gee.ArrayList<Sample> ();
                foreach (var t in s.threads.values) if (t.count > 0) threads.add (t);
                threads.sort ((a, b) => {
                    double av = a.sum / a.count, bv = b.sum / b.count;
                    return av < bv ? 1 : (av > bv ? -1 : 0);
                });
                for (int j = 0; j < int.min (8, threads.size); j++) {
                    var t = threads[j];
                    exp.add_row (new ActionRow (t.name, _("%.1f%% average, %.0f%% peak").printf (t.sum / t.count, t.peak)));
                }
                if (threads.size == 0) exp.add_row (new ActionRow (_("Threads"), _("Too little activity to rank its threads")));
                results.add_row (exp);
                result_rows.add (exp);
            }
        }

        private async void capture_perf () {
            perf_btn.sensitive = false;
            perf_output.visible = true;
            perf_output.label = _("Capturing for ten seconds...");
            string data = Path.build_filename (Environment.get_user_runtime_dir (), "singularity-perf-%d.data".printf ((int) Posix.getpid ()));
            try {
                var rec = new Subprocess.newv ({ "perf", "record", "-F", "99", "-g", "-a", "-o", data, "--", "sleep", "10" },
                    SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_PIPE);
                string err;
                yield rec.communicate_utf8_async (null, null, null, out err);
                if (!rec.get_successful ()) {
                    perf_output.label = _("perf could not record: %s").printf (err.strip ().split ("\n")[0]);
                    perf_btn.sensitive = true;
                    return;
                }
                var rep = new Subprocess.newv ({ "perf", "report", "-i", data, "--stdio", "--no-children", "--sort", "comm,symbol", "--percent-limit", "1" },
                    SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                string output;
                yield rep.communicate_utf8_async (null, null, out output, null);
                var lines = new StringBuilder ();
                int kept = 0;
                foreach (string line in output.split ("\n")) {
                    string l = line.strip ();
                    if (l == "" || l.has_prefix ("#") || !l.contains ("%")) continue;
                    lines.append (l);
                    lines.append_c ('\n');
                    if (++kept >= 40) break;
                }
                perf_output.label = kept > 0 ? lines.str : _("No samples were recorded.");
            } catch (Error e) {
                perf_output.label = e.message;
            }
            FileUtils.remove (data);
            FileUtils.remove (data + ".old");
            perf_btn.sensitive = true;
        }
    }
}
