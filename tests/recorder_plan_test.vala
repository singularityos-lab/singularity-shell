using GLib;
using Singularity.Recorder;

private string[] available_names;

private bool fake_available(string name) {
    foreach (var n in available_names) {
        if (n == name) return true;
    }
    return false;
}

private string[] host_elements(string plugin_dir) {
    string[] plugins = {};
    try {
        var dir = Dir.open(plugin_dir);
        string? name;
        while ((name = dir.read_name()) != null) plugins += name;
    } catch (Error e) {
        return {};
    }
    var map = new HashTable<string, string>(str_hash, str_equal);
    map["libgstpipewire.so"] = "pipewiresrc";
    map["libgstcoreelements.so"] = "queue capsfilter filesink";
    map["libgstvideoconvertscale.so"] = "videoconvert videoscale";
    map["libgstvideocrop.so"] = "videocrop";
    map["libgstvideorate.so"] = "videorate";
    map["libgstisomp4.so"] = "mp4mux";
    map["libgstvideoparsersbad.so"] = "h264parse";
    map["libgstx264.so"] = "x264enc";
    map["libgstopenh264.so"] = "openh264enc";
    map["libgstvpx.so"] = "vp8enc";
    map["libgstmatroska.so"] = "webmmux";
    map["libgstopus.so"] = "opusenc";
    map["libgstaudioconvert.so"] = "audioconvert";
    map["libgstaudioresample.so"] = "audioresample";
    string[] names = {};
    foreach (var plugin in plugins) {
        string? elements = map[plugin];
        if (elements == null) continue;
        foreach (var e in elements.split(" ")) names += e;
    }
    return names;
}

private void test_prefers_hardware_then_x264() {
    available_names = {
        "vah264lpenc", "x264enc", "openh264enc", "vp8enc", "h264parse", "mp4mux", "webmmux"
    };
    var plans = EncoderPlanner.usable(fake_available);
    assert(plans.length == 4);
    assert(plans[0].encoder == "vah264lpenc");
    assert(plans[0].hardware);
    assert(plans[1].encoder == "x264enc");
    assert(plans[2].encoder == "openh264enc");
    assert(plans[3].encoder == "vp8enc");
    assert(plans[3].extension == "webm");
}

private void test_falls_back_to_vp8_without_h264() {
    available_names = { "vp8enc", "webmmux", "mp4mux" };
    var plans = EncoderPlanner.usable(fake_available);
    assert(plans.length == 1);
    assert(plans[0].encoder == "vp8enc");
    assert(plans[0].muxer == "webmmux");
}

private void test_h264_needs_parser_and_muxer() {
    available_names = { "x264enc", "mp4mux" };
    assert(EncoderPlanner.usable(fake_available).length == 0);
    available_names = { "x264enc", "h264parse" };
    assert(EncoderPlanner.usable(fake_available).length == 0);
}

private void test_forced_encoder() {
    available_names = { "vah264lpenc", "x264enc", "h264parse", "mp4mux" };
    var plans = EncoderPlanner.usable(fake_available, "x264enc");
    assert(plans.length == 1);
    assert(plans[0].encoder == "x264enc");
}

private void test_required_elements_skip_caps() {
    var plan = EncoderPlanner.candidates()[3];
    string[] names = plan.required_elements();
    assert(names.length == 3);
    assert(names[0] == "x264enc");
    assert(names[1] == "h264parse");
    assert(names[2] == "mp4mux");
}

private void test_host_plugin_set() {
    string dir = Environment.get_variable("RECORDER_HOST_PLUGIN_DIR")
        ?? "/run/host/usr/lib/x86_64-linux-gnu/gstreamer-1.0";
    if (!FileUtils.test(dir, FileTest.IS_DIR)) {
        Test.skip("host plugin directory not available");
        return;
    }
    available_names = host_elements(dir);
    assert(EncoderPlanner.missing(fake_available, EncoderPlanner.base_elements()).length == 0);
    assert(EncoderPlanner.missing(fake_available, EncoderPlanner.audio_elements()).length == 0);
    var plans = EncoderPlanner.usable(fake_available);
    assert(plans.length >= 1);
    assert(plans[0].encoder == "x264enc");
    assert(plans[0].extension == "mp4");
}

private void test_full_output_is_even() {
    var box = CropMath.compute(1921, 1081, 0, 0, 0, 0, 0, 0);
    assert(box.left == 0 && box.top == 0);
    assert(box.width(1921) == 1920);
    assert(box.height(1081) == 1080);
}

private void test_region_scales_to_buffer() {
    var box = CropMath.compute(2880, 1800, 1440, 900, 100, 50, 301, 200);
    assert(box.left == 200);
    assert(box.top == 100);
    assert(box.width(2880) == 602);
    assert(box.height(1800) == 400);
}

private void test_region_is_clamped() {
    var box = CropMath.compute(1920, 1080, 1920, 1080, 1800, 1000, 500, 500);
    assert(box.left == 1800);
    assert(box.top == 1000);
    assert(box.width(1920) == 120);
    assert(box.height(1080) == 80);
    assert(box.right == 0 && box.bottom == 0);
}

private void test_odd_region_is_rounded() {
    var box = CropMath.compute(1920, 1080, 1920, 1080, 10, 10, 101, 51);
    assert(box.width(1920) % 2 == 0);
    assert(box.height(1080) % 2 == 0);
    assert(box.width(1920) == 100);
    assert(box.height(1080) == 50);
}

void main(string[] args) {
    Test.init(ref args);
    Test.add_func("/recorder/plan/preference", test_prefers_hardware_then_x264);
    Test.add_func("/recorder/plan/vp8-fallback", test_falls_back_to_vp8_without_h264);
    Test.add_func("/recorder/plan/needs-parser-and-muxer", test_h264_needs_parser_and_muxer);
    Test.add_func("/recorder/plan/forced-encoder", test_forced_encoder);
    Test.add_func("/recorder/plan/required-elements", test_required_elements_skip_caps);
    Test.add_func("/recorder/plan/host-plugin-set", test_host_plugin_set);
    Test.add_func("/recorder/crop/full-output-even", test_full_output_is_even);
    Test.add_func("/recorder/crop/region-scaled", test_region_scales_to_buffer);
    Test.add_func("/recorder/crop/region-clamped", test_region_is_clamped);
    Test.add_func("/recorder/crop/odd-region", test_odd_region_is_rounded);
    Test.run();
}
