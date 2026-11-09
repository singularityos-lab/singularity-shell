using Singularity;

static HashTable<string, Variant> hints(string? message = null, bool spam = false) {
    var h = new HashTable<string, Variant>(str_hash, str_equal);
    if (message != null) h.insert("x-sinty-message-id", new Variant.string(message));
    if (spam) h.insert("x-sinty-spam", new Variant.boolean(true));
    return h;
}

static void test_sources() {
    assert(OneTimeCodeService.source_of("", "dev.sinty.messages") == "messages");
    assert(OneTimeCodeService.source_of("dev.sinty.Lettere", "") == "mail");
    assert(OneTimeCodeService.source_of("", "dev.sinty.nearby.phone.desktop") == "phone");
    assert(OneTimeCodeService.source_of("", "org.example.Random") == null);
}

static void test_offer_and_use() {
    var svc = OneTimeCodeService.get_default();
    svc.clear();
    assert(svc.offer(1, "", "org.example.Random", "Banca X", "Il tuo codice è 482913", hints()) == null);
    assert(svc.offer(2, "", "dev.sinty.messages", "Spam", "Il tuo codice è 111222", hints(null, true)) == null);
    var m = svc.offer(3, "", "dev.sinty.messages", "Banca X", "Il tuo codice di accesso è 482913.", hints("m-3"));
    assert(m != null && m.code == "482913");
    assert(svc.holds("482913"));
    assert(svc.holds(" 482 913 "));
    assert(svc.safe_text(3, "Il tuo codice di accesso è 482913.") == "Il tuo codice di accesso è ••••••.");
    assert(svc.safe_text(9, "482913") == "482913");

    bool found; uint id; string code, service, domain, app; int64 expires;
    svc.latest(out found, out id, out code, out service, out domain, out app, out expires);
    assert(found && code == "482913" && service == "Banca X" && app == "dev.sinty.messages");
    assert(expires > get_real_time() / 1000000 + 590);

    uint released_for = 0;
    ulong h = svc.released.connect((nid, match) => released_for = nid);
    svc.use(id);
    svc.disconnect(h);
    assert(released_for == 3);
    assert(!svc.holds("482913"));
    svc.latest(out found, out id, out code, out service, out domain, out app, out expires);
    assert(!found);
}

static void test_message_text() {
    var svc = OneTimeCodeService.get_default();
    svc.clear();
    var h = hints("42");
    h.insert("x-sinty-message-text", new Variant.string("Bank Y\nYour verification code is 615243"));
    var m = svc.offer(400, "", "dev.sinty.lettere", "Bank Y", "Sign-in attempt", h);
    assert(m != null && m.code == "615243");
    svc.clear();
}

static void test_limit() {
    var svc = OneTimeCodeService.get_default();
    svc.clear();
    for (int i = 0; i < 7; i++)
        svc.offer(100 + i, "", "dev.sinty.messages", "Shop", "Your code is %d".printf(500000 + i), hints());
    assert(svc.holds("500006"));
    assert(svc.holds("500002"));
    assert(!svc.holds("500001"));
    bool found; uint id; string code, service, domain, app; int64 expires;
    svc.latest(out found, out id, out code, out service, out domain, out app, out expires);
    assert(code == "500006");
    svc.clear();
}

static void test_disabled() {
    var settings = new GLib.Settings("dev.sinty.desktop.notifications");
    var svc = OneTimeCodeService.get_default();
    settings.set_strv("one-time-code-sources", { "mail" });
    assert(svc.offer(200, "", "dev.sinty.messages", "Banca X", "Il tuo codice è 482913", hints()) == null);
    settings.set_strv("one-time-code-sources", { "messages", "mail", "phone", "apps" });
    assert(svc.offer(201, "", "dev.sinty.messages", "Banca X", "Il tuo codice è 482913", hints()) != null);
    settings.set_boolean("one-time-codes", false);
    assert(!svc.holds("482913"));
    assert(svc.offer(202, "", "dev.sinty.messages", "Banca X", "Il tuo codice è 482913", hints()) == null);
    settings.reset("one-time-codes");
}

static void test_dbus() {
    try {
        Bus.get_sync(BusType.SESSION);
    } catch (Error e) {
        Test.skip("no session bus");
        return;
    }
    var svc = OneTimeCodeService.get_default();
    svc.clear();
    svc.offer(300, "", "dev.sinty.lettere", "Shop", "Your code is 739204\n\n@shop.example.com #739204", hints());
    svc.export();
    var loop = new MainLoop();
    Timeout.add(500, () => { loop.quit(); return Source.REMOVE; });
    loop.run();
    string? failure = null;
    new Thread<bool>("client", () => {
        try {
            var conn = new DBusConnection.for_address_sync(Environment.get_variable("DBUS_SESSION_BUS_ADDRESS"),
                DBusConnectionFlags.AUTHENTICATION_CLIENT | DBusConnectionFlags.MESSAGE_BUS_CONNECTION);
            var reply = conn.call_sync("dev.sinty.OneTimeCodes", "/dev/sinty/OneTimeCodes", "dev.sinty.OneTimeCodes1",
                "Latest", null, new VariantType("(bussssx)"), DBusCallFlags.NONE, 2000);
            bool found; uint id; string code, service, domain, app; int64 expires;
            reply.get("(bussssx)", out found, out id, out code, out service, out domain, out app, out expires);
            if (!(found && code == "739204" && domain == "shop.example.com")) failure = "latest: " + reply.print(false);
            conn.call_sync("dev.sinty.OneTimeCodes", "/dev/sinty/OneTimeCodes", "dev.sinty.OneTimeCodes1",
                "Use", new Variant("(u)", id), null, DBusCallFlags.NONE, 2000);
            reply = conn.call_sync("dev.sinty.OneTimeCodes", "/dev/sinty/OneTimeCodes", "dev.sinty.OneTimeCodes1",
                "Latest", null, new VariantType("(bussssx)"), DBusCallFlags.NONE, 2000);
            reply.get("(bussssx)", out found, out id, out code, out service, out domain, out app, out expires);
            if (found && failure == null) failure = "still held after use";
        } catch (Error e) {
            failure = e.message;
        }
        Idle.add(() => { loop.quit(); return Source.REMOVE; });
        return true;
    });
    int changes = 0;
    ulong h = svc.changed.connect(() => changes++);
    loop.run();
    svc.disconnect(h);
    if (failure != null) error("%s", failure);
    assert(changes >= 1);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/one-time-code-service/sources", test_sources);
    Test.add_func("/one-time-code-service/offer-and-use", test_offer_and_use);
    Test.add_func("/one-time-code-service/limit", test_limit);
    Test.add_func("/one-time-code-service/message-text", test_message_text);
    Test.add_func("/one-time-code-service/disabled", test_disabled);
    Test.add_func("/one-time-code-service/dbus", test_dbus);
    return Test.run();
}
