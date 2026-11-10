namespace Singularity.SintyKey {

    public class RescueHome : Object {
        public int uid;
        public string name;
        public bool open;
    }

    public class RescueStatus : Object {
        public int state;
        public int progress;
        public string message;

        public bool working {
            get {
                return state == 2;
            }
        }
    }

    public class RescueClient : Object {
        public const string OUT_DIR = "/run/sinty-rescue/work/out";

        public string socket { get; construct; }

        public RescueClient(string socket) {
            Object(socket: socket);
        }

        private Json.Object exchange(string method, string path, string? body) throws Error {
            var sock = new Socket(SocketFamily.UNIX, SocketType.STREAM, SocketProtocol.DEFAULT);
            sock.set_timeout(600);
            sock.connect(new UnixSocketAddress(socket), null);
            var conn = SocketConnection.factory_create_connection(sock);
            string payload = body ?? "";
            var req = "%s %s HTTP/1.0\r\nHost: rescue\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
                .printf(method, path, payload.length, payload);
            size_t written;
            conn.output_stream.write_all(req.data, out written, null);
            var raw = new MemoryOutputStream.resizable();
            raw.splice(conn.input_stream, OutputStreamSpliceFlags.CLOSE_SOURCE | OutputStreamSpliceFlags.CLOSE_TARGET, null);
            conn.close();
            uint8[] data = raw.steal_data();
            data.length = (int) raw.get_data_size();
            string text = (string) data;
            int at = text.index_of("\r\n\r\n");
            if (at < 0) throw new KeyError.FAILED(_("The rescue did not answer."));
            var parser = new Json.Parser();
            parser.load_from_data(text.substring(at + 4));
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.OBJECT) throw new KeyError.FAILED(_("The rescue did not answer."));
            return root.get_object();
        }

        private async Json.Object request(string method, string path, string? body = null) throws Error {
            Json.Object? result = null;
            Error? failure = null;
            SourceFunc resume = request.callback;
            new Thread<void>("rescue", () => {
                try {
                    result = exchange(method, path, body);
                } catch (Error e) {
                    failure = e;
                }
                Idle.add((owned) resume);
            });
            yield;
            if (failure != null) throw failure;
            return result;
        }

        private static string text(Json.Object o, string name) {
            return o.has_member(name) ? o.get_string_member(name) : "";
        }

        public static string friendly(string message) {
            return message.replace(OUT_DIR, Path.build_filename(Environment.get_home_dir(), "Rescued"));
        }

        public async Gee.ArrayList<RescueHome> homes(out string problem) throws Error {
            var o = yield request("GET", "/homes");
            problem = text(o, "message");
            var list = new Gee.ArrayList<RescueHome>();
            o.get_array_member("homes").foreach_element((a, i, node) => {
                var h = node.get_object();
                var home = new RescueHome();
                home.uid = (int) h.get_int_member("uid");
                home.name = h.get_string_member("name");
                home.open = h.get_boolean_member("open");
                list.add(home);
            });
            return list;
        }

        public async void unlock(int uid, string secret, bool recovery) throws Error {
            var b = new Json.Builder();
            b.begin_object();
            b.set_member_name("uid");
            b.add_int_value(uid);
            b.set_member_name("secret");
            b.add_string_value(secret);
            b.set_member_name("recovery");
            b.add_boolean_value(recovery);
            b.end_object();
            var gen = new Json.Generator();
            gen.set_root(b.get_root());
            var o = yield request("POST", "/unlock-home", gen.to_data(null));
            if (!o.get_boolean_member("ok")) throw new KeyError.FAILED(text(o, "message"));
        }

        public async bool start(string path, string body = "{}") throws Error {
            var o = yield request("POST", path, body);
            return o.has_member("started") && o.get_boolean_member("started");
        }

        public async string sealed_log(int uid) throws Error {
            var o = yield request("GET", "/sealed-log?uid=%d".printf(uid));
            if (!o.get_boolean_member("ok")) throw new KeyError.FAILED(text(o, "message"));
            return text(o, "log");
        }

        public async RescueStatus status() throws Error {
            var o = yield request("GET", "/status");
            var st = new RescueStatus();
            st.state = (int) o.get_int_member("state");
            st.progress = (int) o.get_int_member("progress");
            st.message = friendly(text(o, "message"));
            return st;
        }
    }
}
