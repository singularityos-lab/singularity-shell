namespace Singularity.Dictation {

    [CCode (cname = "SINGULARITY_SHELL_LIBEXECDIR")]
    extern const string LIBEXECDIR;
    [CCode (cname = "SINGULARITY_SHELL_DATADIR")]
    extern const string DATADIR;

    public class ModelInfo : Object {
        public string id { get; set; default = ""; }
        public string engine { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string language { get; set; default = ""; }
        public int64 size { get; set; default = 0; }
        public string url { get; set; default = ""; }
        public string sha256 { get; set; default = ""; }
        public string file { get; set; default = ""; }
        public bool archive { get; set; default = false; }

        public string install_path() {
            return Path.build_filename(ModelCatalog.user_models_dir(), file);
        }
    }

    public class InstalledModel : Object {
        public string engine { get; set; default = ""; }
        public string path { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public bool removable { get; set; default = false; }
    }

    public class ModelCatalog : Object {
        public static string user_models_dir() {
            return Path.build_filename(Environment.get_user_data_dir(), "singularity", "dictation", "models");
        }

        public static string[] model_dirs() {
            string[] dirs = { user_models_dir() };
            foreach (string dir in Environment.get_system_data_dirs()) {
                string candidate = Path.build_filename(dir, "singularity", "dictation", "models");
                if (!(candidate in dirs)) dirs += candidate;
            }
            string shipped = Path.build_filename(DATADIR, "singularity", "dictation", "models");
            if (!(shipped in dirs)) dirs += shipped;
            return dirs;
        }

        public static ModelInfo[] parse(string json) {
            ModelInfo[] result = {};
            var parser = new Json.Parser();
            try {
                parser.load_from_data(json);
            } catch (Error e) {
                return result;
            }
            var root = parser.get_root();
            if (root == null) return result;
            Json.Array? items = null;
            if (root.get_node_type() == Json.NodeType.ARRAY) {
                items = root.get_array();
            } else if (root.get_node_type() == Json.NodeType.OBJECT && root.get_object().has_member("models")) {
                items = root.get_object().get_array_member("models");
            }
            if (items == null) return result;
            foreach (var node in items.get_elements()) {
                if (node.get_node_type() != Json.NodeType.OBJECT) continue;
                var obj = node.get_object();
                var info = new ModelInfo();
                info.id = text(obj, "id");
                info.engine = text(obj, "engine");
                info.name = text(obj, "name");
                info.language = text(obj, "language");
                info.url = text(obj, "url");
                info.sha256 = text(obj, "sha256").down();
                info.file = text(obj, "file");
                info.size = obj.has_member("size") ? obj.get_int_member("size") : 0;
                info.archive = obj.has_member("archive") && obj.get_boolean_member("archive");
                if (info.id == "" || info.url == "" || info.file == "" || info.sha256.length != 64) continue;
                if (!info.url.has_prefix("https://") || info.file.contains("/") || info.file.has_prefix(".")) continue;
                result += info;
            }
            return result;
        }

        private static string text(Json.Object obj, string key) {
            if (!obj.has_member(key)) return "";
            var node = obj.get_member(key);
            if (node.get_node_type() != Json.NodeType.VALUE || node.get_value_type() != typeof(string)) return "";
            return node.get_string();
        }

        public static string? catalog_path() {
            string[] candidates = {};
            candidates += Path.build_filename(Environment.get_user_config_dir(), "singularity", "dictation-models.json");
            foreach (string dir in Environment.get_system_config_dirs()) {
                candidates += Path.build_filename(dir, "singularity", "dictation-models.json");
            }
            foreach (string dir in Environment.get_system_data_dirs()) {
                candidates += Path.build_filename(dir, "singularity", "dictation-models.json");
            }
            candidates += Path.build_filename(DATADIR, "singularity", "dictation-models.json");
            foreach (string path in candidates) {
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
            }
            return null;
        }

        public static ModelInfo[] load() {
            string? path = catalog_path();
            if (path == null) return {};
            try {
                string contents;
                FileUtils.get_contents(path, out contents);
                return parse(contents);
            } catch (FileError e) {
                warning("Dictation: cannot read %s: %s", path, e.message);
                return {};
            }
        }

        public static bool is_vosk_model(string dir) {
            return FileUtils.test(Path.build_filename(dir, "am", "final.mdl"), FileTest.EXISTS)
                || FileUtils.test(Path.build_filename(dir, "conf", "model.conf"), FileTest.EXISTS);
        }

        public static InstalledModel[] installed() {
            InstalledModel[] result = {};
            var seen = new GenericSet<string>(str_hash, str_equal);
            string user_dir = user_models_dir();
            foreach (string dir in model_dirs()) {
                try {
                    var directory = Dir.open(dir);
                    string? name;
                    while ((name = directory.read_name()) != null) {
                        if (seen.contains(name)) continue;
                        string path = Path.build_filename(dir, name);
                        var model = new InstalledModel();
                        model.path = path;
                        model.removable = dir == user_dir;
                        if (name.has_prefix("ggml-") && name.has_suffix(".bin")
                                && FileUtils.test(path, FileTest.IS_REGULAR)) {
                            model.engine = "whisper";
                            model.name = name.substring(5, name.length - 9);
                        } else if (FileUtils.test(path, FileTest.IS_DIR) && is_vosk_model(path)) {
                            model.engine = "vosk";
                            model.name = name.has_prefix("vosk-model-") ? name.substring(11) : name;
                        } else {
                            continue;
                        }
                        seen.add(name);
                        result += model;
                    }
                } catch (FileError e) {
                }
            }
            return result;
        }

        public static string sha256_of_file(string path) throws Error {
            var checksum = new Checksum(ChecksumType.SHA256);
            var stream = File.new_for_path(path).read();
            var buffer = new uint8[65536];
            ssize_t read;
            while ((read = stream.read(buffer)) > 0) checksum.update(buffer, read);
            stream.close();
            return checksum.get_string();
        }
    }

    public class EngineLocator : Object {
        public static string? whisper_binary() {
            foreach (string name in new string[] { "whisper-cli", "whisper-cpp", "whisper.cpp" }) {
                string? found = Environment.find_program_in_path(name);
                if (found != null) return found;
            }
            string bundled = Path.build_filename(LIBEXECDIR, "whisper-cli");
            if (FileUtils.test(bundled, FileTest.IS_EXECUTABLE)) return bundled;
            return null;
        }

        public static string? vosk_helper() {
            string helper = Path.build_filename(LIBEXECDIR, "singularity-dictation-vosk");
            if (FileUtils.test(helper, FileTest.IS_EXECUTABLE)) return helper;
            return Environment.find_program_in_path("singularity-dictation-vosk");
        }

        public static async bool vosk_ready() {
            string? helper = vosk_helper();
            if (helper == null) return false;
            try {
                var process = new Subprocess(SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE,
                    helper, "--check");
                yield process.wait_async();
                return process.get_successful();
            } catch (Error e) {
                return false;
            }
        }

        public static InstalledModel? pick_model(string engine, string preferred) {
            InstalledModel? first = null;
            foreach (var model in ModelCatalog.installed()) {
                if (engine != "" && model.engine != engine) continue;
                if (preferred != "" && (model.path == preferred || model.name == preferred)) return model;
                if (first == null) first = model;
            }
            return first;
        }

        public static DictationEngine? create(GLib.Settings settings, out string reason) {
            reason = "";
            string choice = settings.get_string("dictation-engine");
            string command = settings.get_string("dictation-command").strip();
            if (choice == "command" || (choice == "auto" && command != "")) {
                if (command == "") {
                    reason = _("No speech engine command is set");
                    return null;
                }
                string[] argv;
                try {
                    GLib.Shell.parse_argv(command, out argv);
                } catch (ShellError e) {
                    reason = _("The speech engine command is not valid");
                    return null;
                }
                return new StreamEngine("command", argv);
            }
            string preferred = settings.get_string("dictation-model");
            if (choice == "whisper" || choice == "auto") {
                string? binary = whisper_binary();
                var model = binary != null ? pick_model("whisper", preferred) : null;
                if (binary != null && model != null) {
                    var engine = new WhisperEngine(binary, model.path);
                    engine.threads = int.max(1, int.min(8, (int) get_num_processors() - 1));
                    return engine;
                }
                if (choice == "whisper") {
                    reason = binary == null ? _("whisper.cpp is not installed") : _("Download a speech model first");
                    return null;
                }
            }
            if (choice == "vosk" || choice == "auto") {
                string? helper = vosk_helper();
                var model = helper != null ? pick_model("vosk", preferred) : null;
                if (helper != null && model != null) {
                    return new StreamEngine("vosk", { helper, "--model", model.path, "--rate", SAMPLE_RATE.to_string() });
                }
                reason = helper == null ? _("No speech engine is installed") : _("Download a speech model first");
                return null;
            }
            reason = _("No speech engine is installed");
            return null;
        }
    }

    public class ModelDownloader : Object {
        public signal void progress(double fraction);

        private Cancellable cancellable = new Cancellable();

        public void cancel() {
            cancellable.cancel();
        }

        public async void download(ModelInfo info) throws Error {
            string dir = ModelCatalog.user_models_dir();
            DirUtils.create_with_parents(dir, 0755);
            string part = Path.build_filename(dir, "." + info.file + ".part");
            var session = new Soup.Session();
            session.user_agent = "Singularity-Desktop";
            var message = new Soup.Message("GET", info.url);
            var stream = yield session.send_async(message, Priority.DEFAULT, cancellable);
            if (message.status_code != 200) {
                throw new IOError.FAILED(_("The server answered %u").printf(message.status_code));
            }
            int64 total = message.response_headers.get_content_length();
            if (total <= 0) total = info.size;
            var file = File.new_for_path(part);
            var output = yield file.replace_async(null, false, FileCreateFlags.PRIVATE, Priority.DEFAULT, cancellable);
            var checksum = new Checksum(ChecksumType.SHA256);
            int64 received = 0;
            try {
                while (true) {
                    var chunk = yield stream.read_bytes_async(131072, Priority.DEFAULT, cancellable);
                    if (chunk.get_size() == 0) break;
                    checksum.update(chunk.get_data(), chunk.get_size());
                    size_t written;
                    yield output.write_all_async(chunk.get_data(), Priority.DEFAULT, cancellable, out written);
                    received += (int64) chunk.get_size();
                    if (total > 0) progress(double.min(1.0, (double) received / total));
                }
                yield output.close_async(Priority.DEFAULT, cancellable);
            } catch (Error e) {
                FileUtils.unlink(part);
                throw e;
            }
            if (checksum.get_string() != info.sha256) {
                FileUtils.unlink(part);
                throw new IOError.INVALID_DATA(_("The downloaded file did not match its checksum"));
            }
            if (info.archive) {
                yield extract(part, dir, info);
                FileUtils.unlink(part);
            } else {
                file.move(File.new_for_path(info.install_path()), FileCopyFlags.OVERWRITE, cancellable);
            }
        }

        private async void extract(string archive, string dir, ModelInfo info) throws Error {
            string? helper = EngineLocator.vosk_helper();
            if (helper == null) throw new IOError.NOT_SUPPORTED(_("No speech engine is installed"));
            var process = new Subprocess(SubprocessFlags.STDERR_SILENCE, helper, "--extract", archive, dir);
            yield process.wait_async(cancellable);
            if (!process.get_successful() || !ModelCatalog.is_vosk_model(info.install_path())) {
                throw new IOError.FAILED(_("The model archive could not be unpacked"));
            }
        }

        public static void remove(InstalledModel model) throws Error {
            if (!model.removable) return;
            var file = File.new_for_path(model.path);
            if (FileUtils.test(model.path, FileTest.IS_DIR)) delete_tree(file);
            else file.delete();
        }

        private static void delete_tree(File dir) throws Error {
            var children = dir.enumerate_children("standard::name,standard::type", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? child;
            while ((child = children.next_file()) != null) {
                var path = dir.get_child(child.get_name());
                if (child.get_file_type() == FileType.DIRECTORY) delete_tree(path);
                else path.delete();
            }
            dir.delete();
        }
    }
}
