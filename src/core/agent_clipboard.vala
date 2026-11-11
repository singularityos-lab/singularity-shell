namespace Singularity.Shell {
    [DBus (name = "dev.sinty.AgentClipboard1")]
    public class AgentClipboardService : Object {
        private const string AGENT_NAME = "dev.sinty.Agent";
        private DBusConnection connection;

        public AgentClipboardService(DBusConnection connection) {
            this.connection = connection;
        }

        public void copy(string text, bool sensitive, uint clear_after, BusName sender) throws DBusError, IOError {
            string owner;
            try {
                var r = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "GetNameOwner", new Variant("(s)", AGENT_NAME), new VariantType("(s)"), DBusCallFlags.NONE, 2000);
                owner = r.get_child_value(0).get_string();
            } catch (Error e) {
                throw new DBusError.ACCESS_DENIED("only the system agent may copy");
            }
            if (owner != sender) throw new DBusError.ACCESS_DENIED("only the system agent may copy");
            SearchClipboard.copy(text, sensitive, clear_after.clamp(0, 300));
        }
    }
}
