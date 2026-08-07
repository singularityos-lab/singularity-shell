namespace Singularity {

    public class OsIdentity : Object {
        public string name { get; private set; }
        public string pretty_name { get; private set; }
        public string version_id { get; private set; }
        public string build_id { get; private set; }

        private OsIdentity(string name, string pretty_name, string version_id, string build_id) {
            this.name = name;
            this.pretty_name = pretty_name;
            this.version_id = version_id;
            this.build_id = build_id;
        }

        public static OsIdentity load() {
            return from_values(
                Environment.get_os_info("NAME"),
                Environment.get_os_info("PRETTY_NAME"),
                Environment.get_os_info("VERSION_ID"),
                Environment.get_os_info("BUILD_ID")
            );
        }

        internal static OsIdentity from_values(string? name_value, string? pretty_name_value,
                                                string? version_id_value, string? build_id_value) {
            string name = clean(name_value);
            string pretty_name = clean(pretty_name_value);
            string version_id = clean(version_id_value);
            string build_id = clean(build_id_value);

            if (name == "") name = pretty_name;
            if (name == "") name = "Linux";
            if (pretty_name == "") {
                pretty_name = name;
                if (version_id != "") pretty_name += " " + version_id;
            }

            return new OsIdentity(name, pretty_name, version_id, build_id);
        }

        public string menu_label() {
            if (build_id == "" || pretty_name.contains("Build " + build_id)) return pretty_name;
            return "%s (Build %s)".printf(pretty_name, build_id);
        }

        private static string clean(string? value) {
            return value != null ? value.strip() : "";
        }
    }
}
