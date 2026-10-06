using GLib;
using Singularity;

private const string SOLAR_B64 = "YnBsaXN0MDDSAQIDCFJhcFJzadIEBQYHUWRRbBADEAKkCRAUF9MKCwwNDg9RYVFpUXojwD4AAAAAAAAQACNAJAAAAAAAANMKCwwREhMjwAAAAAAAAAAQASNAWQAAAAAAANMKCwwVBxYjQEQAAAAAAAAjQGaAAAAAAADTCgsMGAYZI0AUAAAAAAAAI0BwQAAAAAAACA0QExgaHB4gJSwuMDI7PUZNVlhhaHF6gYoAAAAAAAABAQAAAAAAAAAaAAAAAAAAAAAAAAAAAAAAkw==";
private const string H24_B64 = "YnBsaXN0MDDSAQIDCFJhcFJ0adIEBQYHUWRRbBAAEAGjCQ0P0goLBgxRaVF0IwAAAAAAAAAA0goLBw4jP9AAAAAAAADSCgsQERACIz/oAAAAAAAACA0QExgaHB4gJCkrLTY7RElLAAAAAAAAAQEAAAAAAAAAEgAAAAAAAAAAAAAAAAAAAFQ=";
private const string APR_B64 = "YnBsaXN0MDDSAQIDBFFkUWwQARAACA0PERMAAAAAAAABAQAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAFQ==";

private string fixture_dir;
private TimeZone rome;

private string write_file(string name, string contents) {
    string path = Path.build_filename(fixture_dir, name);
    try {
        DirUtils.create_with_parents(Path.get_dirname(path), 0700);
        FileUtils.set_contents(path, contents);
    } catch (Error e) { error("fixture: %s", e.message); }
    return path;
}

private DateTime at(int y, int mo, int d, int h, int mi) {
    return new DateTime(rome, y, mo, d, h, mi, 0);
}

private void test_clock_parse() {
    assert(DynamicWallpaper.parse_clock("06:30") == 6 * 3600 + 30 * 60);
    assert(DynamicWallpaper.parse_clock("23:59:59") == 86399);
    assert(DynamicWallpaper.parse_clock("24:00") == -1);
    assert(DynamicWallpaper.parse_clock("7") == -1);
    assert(DynamicWallpaper.parse_clock("aa:00") == -1);
    assert(DynamicWallpaper.format_clock(-60) == "23:59");
}

private void test_solar_math() {
    double lat = 45.46, lon = 9.19;
    var day = at(2026, 6, 21, 12, 0);
    var sunrise = DynamicWallpaperSun.time_for_elevation(day, lat, lon, -0.833, true);
    var sunset = DynamicWallpaperSun.time_for_elevation(day, lat, lon, -0.833, false);
    int rise_min = sunrise.get_hour() * 60 + sunrise.get_minute();
    int set_min = sunset.get_hour() * 60 + sunset.get_minute();
    assert((rise_min - (5 * 60 + 34)).abs() <= 4);
    assert((set_min - (21 * 60 + 15)).abs() <= 4);
    assert((DynamicWallpaperSun.elevation(sunrise, lat, lon) + 0.833).abs() < 0.3);
    var noon = DynamicWallpaperSun.time_for_elevation(day, lat, lon, 89.0, true);
    double peak = DynamicWallpaperSun.elevation(noon, lat, lon);
    assert((peak - (90.0 - lat + 23.44)).abs() < 0.6);
    assert(DynamicWallpaperSun.is_rising(at(2026, 6, 21, 9, 0), lat, lon));
    assert(!DynamicWallpaperSun.is_rising(at(2026, 6, 21, 18, 0), lat, lon));
    assert(DynamicWallpaperSun.elevation(at(2026, 12, 21, 23, 0), lat, lon) < -30.0);
    var polar = DynamicWallpaperSun.time_for_elevation(day, 78.2, 15.6, -2.0, true);
    assert(polar.get_day_of_month() == 21);
}

private DynamicWallpaper time_manifest() throws Error {
    write_file("time/a.png", "a");
    string path = write_file("time/day.dynamic.json", """{
      "version": 1, "name": "Timed", "kind": "time", "transition": 3600,
      "frames": [
        { "image": "a.png", "time": "06:00" },
        { "image": "b.png", "time": "12:00" },
        { "image": "c.png", "time": "18:00" }
      ]
    }""");
    return DynamicWallpaper.load(path);
}

private void test_time_schedule() {
    try {
        var wp = time_manifest();
        string a = Path.build_filename(fixture_dir, "time", "a.png");
        string b = Path.build_filename(fixture_dir, "time", "b.png");
        string c = Path.build_filename(fixture_dir, "time", "c.png");
        assert(wp.kind == DynamicWallpaperKind.TIME);
        assert(wp.frames.length == 3);
        assert(wp.frames[0].image == a);
        var s = wp.evaluate(at(2026, 3, 1, 11, 30), false, false, 0, 0);
        assert(s.from == a && s.to == b);
        assert((s.progress - 0.5).abs() < 0.001);
        s = wp.evaluate(at(2026, 3, 1, 12, 10), false, false, 0, 0);
        assert(s.from == b && s.to == b && !s.is_blend);
        s = wp.evaluate(at(2026, 3, 1, 3, 0), false, false, 0, 0);
        assert(s.from == c && !s.is_blend);
        s = wp.evaluate(at(2026, 3, 1, 5, 30), false, false, 0, 0);
        assert(s.from == c && s.to == a && (s.progress - 0.5).abs() < 0.001);
        var q = s.quantized(12);
        assert(q.is_blend && (q.progress - 0.5).abs() < 0.001);
        var near = new DynamicWallpaperState(c, a, 0.02).quantized(12);
        assert(!near.is_blend && near.single_image == c);
        var late = new DynamicWallpaperState(c, a, 0.97).quantized(12);
        assert(!late.is_blend && late.single_image == a);
        assert(q.key() != near.key());
        var again = DynamicWallpaper.from_json(parse_obj(wp.to_json()), wp.path);
        assert(again.frames.length == 3);
        assert(again.frames[1].image == b && again.frames[1].time_seconds == 12 * 3600);
        assert(again.transition == 3600);
    } catch (Error e) {
        error("time schedule: %s", e.message);
    }
}

private Json.Object parse_obj(string json) {
    var parser = new Json.Parser();
    try { parser.load_from_data(json); } catch (Error e) { error("json: %s", e.message); }
    return parser.get_root().get_object();
}

private void test_solar_sample() {
    foreach (string frame in new string[] { "night.svg", "dawn.svg", "day.svg", "dusk.svg" })
        write_file("solar/" + frame, "<svg/>");
    string sample = write_file("solar/sample.dynamic.json", """{
  "version": 1,
  "name": "Sample Day",
  "kind": "solar",
  "transition": 2700,
  "preview": "day.svg",
  "frames": [
    { "image": "night.svg", "elevation": -18, "phase": "rising", "time": "04:30" },
    { "image": "dawn.svg", "elevation": -2, "phase": "rising", "time": "06:30" },
    { "image": "day.svg", "elevation": 20, "phase": "rising", "time": "09:00" },
    { "image": "dusk.svg", "elevation": 8, "phase": "setting", "time": "18:00" },
    { "image": "night.svg", "elevation": -6, "phase": "setting", "time": "20:30" }
  ]
}""");
    try {
        var wp = DynamicWallpaper.load(sample);
        assert(wp.kind == DynamicWallpaperKind.SOLAR);
        string night = wp.frames[0].image;
        assert(FileUtils.test(night, FileTest.EXISTS));
        foreach (var f in wp.frames.data) assert(FileUtils.test(f.image, FileTest.EXISTS));
        var noon = wp.evaluate(at(2026, 6, 21, 13, 30), false, true, 45.46, 9.19);
        assert(noon.single_image.has_suffix("/day.svg") && !noon.is_blend);
        var midnight = wp.evaluate(at(2026, 6, 21, 1, 0), false, true, 45.46, 9.19);
        assert(midnight.single_image == night);
        var dawn_time = DynamicWallpaperSun.time_for_elevation(at(2026, 6, 21, 12, 0), 45.46, 9.19, -2, true);
        var dawn = wp.evaluate(dawn_time.add_minutes(5), false, true, 45.46, 9.19);
        assert(dawn.from.has_suffix("/dawn.svg"));
        var winter = wp.evaluate(at(2026, 12, 21, 7, 0), false, true, 45.46, 9.19);
        var summer = wp.evaluate(at(2026, 6, 21, 7, 0), false, true, 45.46, 9.19);
        assert(winter.single_image != summer.single_image || winter.from != summer.from);
        var offline = wp.evaluate(at(2026, 6, 21, 10, 0), false, false, 0, 0);
        assert(offline.single_image.has_suffix("/day.svg"));
    } catch (Error e) {
        error("solar sample: %s", e.message);
    }
}

private void test_appearance() {
    try {
        string path = write_file("app/pair.dynamic.json", """{"name": "Pair", "light": "l.png", "dark": "d.png"}""");
        var wp = DynamicWallpaper.load(path);
        assert(wp.kind == DynamicWallpaperKind.APPEARANCE);
        var now = new DateTime.now_local();
        assert(wp.evaluate(now, true, false, 0, 0).single_image.has_suffix("d.png"));
        assert(wp.evaluate(now, false, false, 0, 0).single_image.has_suffix("l.png"));
        assert(wp.display_name() == "Pair");
        bool failed = false;
        try {
            DynamicWallpaper.load(write_file("app/bad.dynamic.json", """{"kind": "time", "frames": []}"""));
        } catch (Error e) { failed = true; }
        assert(failed);
    } catch (Error e) {
        error("appearance: %s", e.message);
    }
}

private void test_timed_xml() {
    string xml = """<background>
  <starttime><year>2011</year><month>11</month><day>24</day><hour>7</hour><minute>00</minute><second>00</second></starttime>
  <static><duration>43200.0</duration><file><size width="1024" height="768">/w/small-day.jpg</size><size width="3840" height="2160">/w/day.jpg</size></file></static>
  <transition type="overlay"><duration>3600.0</duration><from>/w/day.jpg</from><to>/w/night.jpg</to></transition>
  <static><duration>36000.0</duration><file>night.jpg</file></static>
  <transition type="overlay"><duration>3600.0</duration><from>/w/night.jpg</from><to>/w/day.jpg</to></transition>
</background>""";
    string path = write_file("timed/slideshow.xml", xml);
    assert(DynamicWallpaper.is_dynamic_path(path));
    assert(!DynamicWallpaper.is_dynamic_path(write_file("timed/other.xml", "<svg/>")));
    try {
        var wp = DynamicWallpaper.load(path);
        assert(wp.kind == DynamicWallpaperKind.CYCLE);
        assert(wp.cycle.length == 4);
        assert(wp.cycle[0].from == "/w/day.jpg");
        assert(wp.cycle[2].from == Path.build_filename(fixture_dir, "timed", "night.jpg"));
        var s = wp.evaluate(new DateTime.local(2026, 5, 3, 12, 0, 0), false, false, 0, 0);
        assert(s.single_image == "/w/day.jpg" && !s.is_blend);
        s = wp.evaluate(new DateTime.local(2026, 5, 3, 19, 30, 0), false, false, 0, 0);
        assert(s.from == "/w/day.jpg" && s.to == "/w/night.jpg" && (s.progress - 0.5).abs() < 0.001);
        s = wp.evaluate(new DateTime.local(2026, 5, 4, 2, 0, 0), false, false, 0, 0);
        assert(s.single_image.has_suffix("night.jpg"));
        s = wp.evaluate(new DateTime.local(2026, 5, 4, 6, 15, 0), false, false, 0, 0);
        assert(s.to == "/w/day.jpg" && (s.progress - 0.25).abs() < 0.001);
    } catch (Error e) {
        error("timed xml: %s", e.message);
    }
    string props = write_file("timed/props.xml", """<?xml version="1.0"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper deleted="false"><name>Plain</name><filename>/w/plain.jpg</filename></wallpaper>
  <wallpaper deleted="false"><name>Blobs</name><filename>/w/blobs-l.svg</filename><filename-dark>/w/blobs-d.svg</filename-dark><options>zoom</options></wallpaper>
</wallpapers>""");
    try {
        var wp = DynamicWallpaper.load(props);
        assert(wp.kind == DynamicWallpaperKind.APPEARANCE);
        assert(wp.name == "Blobs" && wp.light == "/w/blobs-l.svg" && wp.dark == "/w/blobs-d.svg");
    } catch (Error e) {
        error("wallpaper list: %s", e.message);
    }
}

private void test_bplist_and_heic_metadata() {
    try {
        var root = HeicDynamicMetadata.decode(SOLAR_B64);
        assert(root.kind == PlistValue.Kind.DICT);
        var si = root.get("si");
        assert(si != null && si.items.length == 4);
        assert((si.items[0].get("a").number() + 30.0).abs() < 1e-9);
        assert(si.items[3].get("i").integer == 3);
        assert(root.get("ap").get("d").integer == 3);
    } catch (Error e) {
        error("bplist: %s", e.message);
    }
    bool bad = false;
    try { BinaryPlist.parse("bplist00xx".data); } catch (Error e) { bad = true; }
    assert(bad);

    string blob = "ftypheic....<x:xmpmeta><rdf:Description apple_desktop:solar=\"" + SOLAR_B64.substring(0, 40) + "\n"
        + SOLAR_B64.substring(40) + "\"/></x:xmpmeta>";
    var meta = HeicDynamicMetadata.scan(blob.data);
    assert(meta.found && meta.solar == SOLAR_B64 && meta.h24 == "");
    string[] frames = { "/f/0.png", "/f/1.png", "/f/2.png", "/f/3.png" };
    try {
        var wp = meta.to_wallpaper(frames);
        assert(wp.kind == DynamicWallpaperKind.SOLAR);
        assert(wp.frames.length == 4);
        assert(wp.frames[1].rising && !wp.frames[3].rising);
        assert(wp.light == "/f/2.png" && wp.dark == "/f/3.png");
    } catch (Error e) {
        error("solar meta: %s", e.message);
    }
    var elem = HeicDynamicMetadata.scan(("<apple_desktop:h24>" + H24_B64 + "</apple_desktop:h24>").data);
    try {
        var wp = elem.to_wallpaper(frames);
        assert(wp.kind == DynamicWallpaperKind.TIME);
        assert(wp.frames[1].time_seconds == 6 * 3600 && wp.frames[2].time_seconds == 18 * 3600);
    } catch (Error e) {
        error("h24 meta: %s", e.message);
    }
    var apr = HeicDynamicMetadata.scan(("apple_desktop:apr='" + APR_B64 + "'").data);
    try {
        var wp = apr.to_wallpaper(frames);
        assert(wp.kind == DynamicWallpaperKind.APPEARANCE && wp.dark == "/f/1.png" && wp.light == "/f/0.png");
    } catch (Error e) {
        error("apr meta: %s", e.message);
    }
    assert(!HeicDynamicMetadata.scan("plain image".data).found);
}

private void test_heic_import_with_decoder_seam() {
    string src_dir = Path.build_filename(fixture_dir, "decoder");
    for (int i = 0; i < 4; i++) write_file("decoder/src-%d.png".printf(i), "frame%d".printf(i));
    string heic = write_file("import/Mojave Test.heic", "ftypheic<rdf apple_desktop:solar=\"" + SOLAR_B64 + "\"/>");
    string[] decoder = { "sh", "-c", "cp \"$0\" \"$1\"", Path.build_filename(src_dir, "src-%n.png"), "%o" };
    try {
        string manifest = DynamicWallpaperImporter.import_file(heic, decoder);
        assert(manifest.has_prefix(DynamicWallpaperImporter.import_root()));
        assert(FileUtils.test(DynamicWallpaperImporter.collection_file(), FileTest.EXISTS));
        var wp = DynamicWallpaper.load(manifest);
        assert(wp.kind == DynamicWallpaperKind.SOLAR && wp.frames.length == 4);
        string contents;
        FileUtils.get_contents(wp.frames[2].image, out contents);
        assert(contents == "frame2");
        assert(wp.name == "Mojave Test");
    } catch (Error e) {
        error("heic import: %s", e.message);
    }
    bool refused = false;
    try {
        DynamicWallpaperImporter.import_file(write_file("import/plain.heic", "ftypheic"), decoder);
    } catch (Error e) { refused = true; }
    assert(refused);
    try {
        string xml = DynamicWallpaperImporter.import_file(Path.build_filename(fixture_dir, "timed", "slideshow.xml"));
        assert(DynamicWallpaper.load(xml).kind == DynamicWallpaperKind.CYCLE);
    } catch (Error e) {
        error("xml import: %s", e.message);
    }
}

private void test_heic_real_decoder() {
    string fixture = Environment.get_variable("DYNAMIC_HEIC_FIXTURE") ?? "";
    if (fixture == "" || !DynamicWallpaperImporter.heic_supported()) {
        Test.skip("no HEIC fixture or decoder");
        return;
    }
    try {
        string manifest = DynamicWallpaperImporter.import_file(fixture);
        var wp = DynamicWallpaper.load(manifest);
        assert(wp.kind == DynamicWallpaperKind.SOLAR && wp.frames.length == 4);
        foreach (var f in wp.frames.data) {
            int w, h;
            var format = Gdk.Pixbuf.get_file_info(f.image, out w, out h);
            assert(format != null && w > 0 && h > 0);
        }
        assert(wp.dark == wp.frames[3].image && wp.light == wp.frames[1].image);
        print("# imported %s\n", manifest);
    } catch (Error e) {
        error("real decoder: %s", e.message);
    }
}

int main(string[] args) {
    try {
        fixture_dir = DirUtils.make_tmp("dynamic-wallpaper-test-XXXXXX");
    } catch (Error e) { error("tmp: %s", e.message); }
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(fixture_dir, "data"), true);
    Environment.set_variable("XDG_CONFIG_HOME", Path.build_filename(fixture_dir, "config"), true);
    rome = new TimeZone.identifier("Europe/Rome") ?? new TimeZone.local();
    Test.init(ref args);
    Test.add_func("/dynamic-wallpaper/clock", test_clock_parse);
    Test.add_func("/dynamic-wallpaper/solar-math", test_solar_math);
    Test.add_func("/dynamic-wallpaper/time-schedule", test_time_schedule);
    Test.add_func("/dynamic-wallpaper/solar-sample", test_solar_sample);
    Test.add_func("/dynamic-wallpaper/appearance", test_appearance);
    Test.add_func("/dynamic-wallpaper/timed-xml", test_timed_xml);
    Test.add_func("/dynamic-wallpaper/heic-metadata", test_bplist_and_heic_metadata);
    Test.add_func("/dynamic-wallpaper/heic-import", test_heic_import_with_decoder_seam);
    Test.add_func("/dynamic-wallpaper/heic-real-decoder", test_heic_real_decoder);
    return Test.run();
}
