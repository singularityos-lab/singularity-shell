using GLib;
using Singularity.Dictation;

private string test_dir;

private uint8[] tone(int samples, int16 amplitude) {
    var pcm = new uint8[samples * 2];
    for (int i = 0; i < samples; i++) {
        int16 v = (int16) (amplitude * Math.sin(i * 2 * Math.PI * 440 / SAMPLE_RATE));
        pcm[i * 2] = (uint8) (v & 0xff);
        pcm[i * 2 + 1] = (uint8) ((v >> 8) & 0xff);
    }
    return pcm;
}

private void write_script(string name, string body) {
    string path = Path.build_filename(test_dir, name);
    try {
        FileUtils.set_contents(path, body);
    } catch (FileError e) {
        error("%s", e.message);
    }
    FileUtils.chmod(path, 0755);
}

private void test_wav_roundtrip() {
    var pcm = tone(1600, 8000);
    var wav = Wav.encode(pcm);
    assert(wav.length == pcm.length + 44);
    int rate, channels;
    var back = Wav.decode(wav, out rate, out channels);
    assert(back != null);
    assert(rate == SAMPLE_RATE);
    assert(channels == 1);
    assert(back.length == pcm.length);
    assert(Memory.cmp(back, pcm, pcm.length) == 0);
    uint8[] junk = { 1, 2, 3, 4 };
    assert(Wav.decode(junk, out rate, out channels) == null);
}

private void test_wav_convert() {
    uint8[] stereo = { 0x10, 0x00, 0x30, 0x00, 0x20, 0x00, 0x40, 0x00 };
    var mono = Wav.to_mono(stereo, 2);
    assert(mono.length == 4);
    assert(mono[0] == 0x20 && mono[2] == 0x30);
    var pcm = tone(48000, 1000);
    var down = Wav.resample(pcm, 48000);
    assert(down.length == 16000 * 2);
    assert(Wav.resample(pcm, SAMPLE_RATE).length == pcm.length);
}

private void test_silence_detector() {
    var detector = new SilenceDetector();
    for (int i = 0; i < 5; i++) detector.feed(new uint8[3200]);
    assert(!detector.heard_speech);
    assert(detector.silence_ms == 500);
    for (int i = 0; i < 3; i++) detector.feed(tone(1600, 9000));
    assert(detector.heard_speech);
    assert(detector.silence_ms == 0);
    assert(detector.level > 0.5);
    for (int i = 0; i < 12; i++) detector.feed(new uint8[3200]);
    assert(detector.silence_ms == 1200);
}

private void test_clean_whisper() {
    assert(EngineOutput.clean_whisper(" Hello world.\n") == "Hello world.");
    assert(EngineOutput.clean_whisper("[BLANK_AUDIO]\n") == "");
    assert(EngineOutput.clean_whisper(" (music) Hello\n [00:00:00.000 --> 00:00:02.000]  there\n") == "Hello there");
    assert(EngineOutput.clean_whisper("*coughs* Fine.") == "Fine.");
}

private void test_stream_lines() {
    bool final_line;
    assert(EngineOutput.parse_stream_line("{\"partial\": \"hel\"}", out final_line) == "hel");
    assert(!final_line);
    assert(EngineOutput.parse_stream_line("{\"text\": \"hello world\"}", out final_line) == "hello world");
    assert(final_line);
    assert(EngineOutput.parse_stream_line("not json", out final_line) == null);
    assert(EngineOutput.parse_stream_line("", out final_line) == null);
    assert(EngineOutput.parse_stream_line("{\"other\": 1}", out final_line) == null);
}

private void test_catalog() {
    string json = """{"models": [
        {"id": "a", "engine": "whisper", "name": "A", "language": "en", "size": 10,
         "url": "https://example.org/a.bin", "sha256": "%s", "file": "ggml-a.bin"},
        {"id": "b", "engine": "whisper", "name": "B", "language": "en", "size": 10,
         "url": "http://example.org/b.bin", "sha256": "%s", "file": "ggml-b.bin"},
        {"id": "c", "engine": "vosk", "name": "C", "language": "it", "size": 10,
         "url": "https://example.org/c.zip", "sha256": "%s", "file": "../c", "archive": true},
        {"id": "d", "engine": "vosk", "name": "D", "language": "it", "size": 10,
         "url": "https://example.org/d.zip", "sha256": "short", "file": "d"},
        {"id": "e", "engine": "vosk", "name": "E", "language": "it", "size": 20,
         "url": "https://example.org/e.zip", "sha256": "%s", "file": "vosk-model-e", "archive": true}
    ]}""".printf(string.nfill(64, 'a'), string.nfill(64, 'b'), string.nfill(64, 'c'), string.nfill(64, 'E'));
    var models = ModelCatalog.parse(json);
    assert(models.length == 2);
    assert(models[0].id == "a");
    assert(models[1].id == "e");
    assert(models[1].archive);
    assert(models[1].sha256 == string.nfill(64, 'e'));
    assert(ModelCatalog.parse("nonsense").length == 0);
}

private void test_shipped_catalog() {
    string path = Path.build_filename(Environment.get_variable("DICTATION_SOURCE_DIR") ?? "", "data", "dictation", "dictation-models.json");
    if (!FileUtils.test(path, FileTest.EXISTS)) {
        Test.skip("catalog source not available");
        return;
    }
    string contents;
    try {
        FileUtils.get_contents(path, out contents);
    } catch (FileError e) {
        error("%s", e.message);
    }
    var models = ModelCatalog.parse(contents);
    assert(models.length >= 4);
    bool whisper = false;
    bool vosk = false;
    foreach (var m in models) {
        if (m.engine == "whisper") whisper = true;
        if (m.engine == "vosk") vosk = true;
        assert(m.size > 0);
    }
    assert(whisper && vosk);
}

private void test_installed_and_checksum() {
    string dir = ModelCatalog.user_models_dir();
    DirUtils.create_with_parents(Path.build_filename(dir, "vosk-model-small-it", "am"), 0755);
    try {
        FileUtils.set_contents(Path.build_filename(dir, "vosk-model-small-it", "am", "final.mdl"), "x");
        FileUtils.set_contents(Path.build_filename(dir, "ggml-tiny.bin"), "abc");
        FileUtils.set_contents(Path.build_filename(dir, "notes.txt"), "abc");
    } catch (FileError e) {
        error("%s", e.message);
    }
    var installed = ModelCatalog.installed();
    int whisper = 0;
    int vosk = 0;
    foreach (var m in installed) {
        if (m.engine == "whisper" && m.name == "tiny") whisper++;
        if (m.engine == "vosk" && m.name == "small-it") vosk++;
        assert(m.removable);
    }
    assert(whisper == 1 && vosk == 1);
    var picked = EngineLocator.pick_model("vosk", "");
    assert(picked != null && picked.engine == "vosk");
    try {
        assert(ModelCatalog.sha256_of_file(Path.build_filename(dir, "ggml-tiny.bin"))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        ModelDownloader.remove(picked);
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(!FileUtils.test(picked.path, FileTest.EXISTS));
}

private void test_whisper_engine_flow() {
    write_script("fake-whisper", "#!/bin/sh\nfile=\"\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"-f\" ]; then file=\"$2\"; fi\n  shift\ndone\nsize=$(stat -c %s \"$file\")\necho \" [BLANK_AUDIO]\"\necho \" heard $size bytes\"\n");
    var engine = new WhisperEngine(Path.build_filename(test_dir, "fake-whisper"), "/nonexistent/model.bin");
    string[] partials = {};
    string[] segments = {};
    bool done = false;
    var loop = new MainLoop();
    engine.partial.connect((t) => partials += t);
    engine.segment_ready.connect((t) => segments += t);
    engine.finished.connect(() => {
        done = true;
        loop.quit();
    });
    engine.failed.connect((m) => {
        printerr("failed: %s\n", m);
        loop.quit();
    });
    try {
        engine.start("en");
    } catch (Error e) {
        error("%s", e.message);
    }
    var args = engine.arguments("/x.wav");
    assert(args[0].has_suffix("fake-whisper"));
    assert("-l" in args && "en" in args && "-nt" in args);
    for (int i = 0; i < 20; i++) engine.feed(tone(1600, 5000));
    Timeout.add(300, () => {
        engine.finish();
        return Source.REMOVE;
    });
    Timeout.add_seconds(10, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    assert(done);
    assert(partials.length >= 1);
    assert(partials[0].has_prefix("heard "));
    assert(segments.length == 1);
    assert(segments[0] == "heard %d bytes".printf(20 * 3200 + 44));
}

private void test_stream_engine_flow() {
    write_script("fake-stream", "#!/bin/sh\necho '{\"partial\": \"hel\"}'\ncat > /dev/null\necho \"{\\\"text\\\": \\\"hello $1\\\"}\"\n");
    var engine = new StreamEngine("command", { Path.build_filename(test_dir, "fake-stream"), "%l" });
    string[] partials = {};
    string[] segments = {};
    bool done = false;
    var loop = new MainLoop();
    engine.partial.connect((t) => partials += t);
    engine.segment_ready.connect((t) => segments += t);
    engine.finished.connect(() => {
        done = true;
        loop.quit();
    });
    try {
        engine.start("it");
    } catch (Error e) {
        error("%s", e.message);
    }
    for (int i = 0; i < 5; i++) engine.feed(tone(1600, 5000));
    Timeout.add(200, () => {
        engine.finish();
        return Source.REMOVE;
    });
    Timeout.add_seconds(10, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    assert(done);
    assert(partials.length == 1 && partials[0] == "hel");
    assert(segments.length == 1 && segments[0] == "hello it");
}

private void test_stream_engine_crash() {
    write_script("fake-crash", "#!/bin/sh\nexit 3\n");
    var engine = new StreamEngine("command", { Path.build_filename(test_dir, "fake-crash") });
    bool failed = false;
    var loop = new MainLoop();
    engine.failed.connect(() => {
        failed = true;
        loop.quit();
    });
    try {
        engine.start("en");
    } catch (Error e) {
        error("%s", e.message);
    }
    Timeout.add_seconds(5, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    assert(failed);
}

private void test_file_transcriber() {
    write_script("fake-whisper-file", "#!/bin/sh\nfile=\"\"\nwhile [ $# -gt 0 ]; do\n  if [ \"$1\" = \"-f\" ]; then file=\"$2\"; fi\n  shift\ndone\necho \" whole $(stat -c %s \"$file\") bytes\"\n");
    string wav = Path.build_filename(test_dir, "stereo.wav");
    var stereo = new uint8[48000 * 4 * 2];
    uint8[] header_pcm = stereo;
    var encoded = Wav.encode(header_pcm, 48000);
    encoded[22] = 2;
    encoded[28] = (uint8) ((48000 * 4) & 0xff);
    encoded[29] = (uint8) (((48000 * 4) >> 8) & 0xff);
    encoded[30] = (uint8) (((48000 * 4) >> 16) & 0xff);
    encoded[32] = 4;
    try {
        FileUtils.set_data(wav, encoded);
    } catch (FileError e) {
        error("%s", e.message);
    }
    uint8[] pcm;
    try {
        pcm = FileTranscriber.load_pcm(wav);
    } catch (Error e) {
        error("%s", e.message);
    }
    assert(pcm.length == 2 * SAMPLE_RATE * 2);
    var loop = new MainLoop();
    string? result = null;
    var transcriber = new FileTranscriber();
    var engine = new WhisperEngine(Path.build_filename(test_dir, "fake-whisper-file"), "/nonexistent/model.bin");
    int partials = 0;
    transcriber.partial.connect(() => partials++);
    transcriber.transcribe.begin(engine, pcm, "it", (obj, res) => {
        try {
            result = transcriber.transcribe.end(res);
        } catch (Error e) {
            error("%s", e.message);
        }
        loop.quit();
    });
    Timeout.add_seconds(10, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    assert(result == "whole %d bytes".printf(pcm.length + 44));
    assert(partials == 0);
    try {
        FileTranscriber.load_pcm(test_dir);
        assert_not_reached();
    } catch (Error e) {
    }
    string bad = Path.build_filename(test_dir, "bad.wav");
    try {
        FileUtils.set_contents(bad, "not audio");
        FileTranscriber.load_pcm(bad);
        assert_not_reached();
    } catch (Error e) {
        assert(e is IOError.INVALID_DATA);
    }
}

private void test_file_transcriber_failure() {
    write_script("fake-crash2", "#!/bin/sh\ncat > /dev/null\nexit 1\n");
    var engine = new StreamEngine("command", { Path.build_filename(test_dir, "fake-crash2") });
    var transcriber = new FileTranscriber();
    var loop = new MainLoop();
    bool failed = false;
    transcriber.transcribe.begin(engine, new uint8[32000], "en", (obj, res) => {
        try {
            transcriber.transcribe.end(res);
        } catch (Error e) {
            failed = true;
        }
        loop.quit();
    });
    Timeout.add_seconds(10, () => {
        loop.quit();
        return Source.REMOVE;
    });
    loop.run();
    assert(failed);
}

int main(string[] args) {
    string base_dir = Environment.get_variable("DICTATION_TEST_DIR") ?? Path.build_filename(Environment.get_current_dir(), "dictation-test");
    test_dir = Path.build_filename(base_dir, "run-%d".printf((int) Posix.getpid()));
    DirUtils.create_with_parents(test_dir, 0755);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(test_dir, "data"), true);
    Environment.set_variable("XDG_RUNTIME_DIR", Path.build_filename(test_dir, "runtime"), true);
    Environment.set_variable("XDG_DATA_DIRS", Path.build_filename(test_dir, "none"), true);
    Test.init(ref args);
    Test.add_func("/dictation/engine/wav-roundtrip", test_wav_roundtrip);
    Test.add_func("/dictation/engine/wav-convert", test_wav_convert);
    Test.add_func("/dictation/engine/silence", test_silence_detector);
    Test.add_func("/dictation/engine/clean-whisper", test_clean_whisper);
    Test.add_func("/dictation/engine/stream-lines", test_stream_lines);
    Test.add_func("/dictation/engine/catalog", test_catalog);
    Test.add_func("/dictation/engine/shipped-catalog", test_shipped_catalog);
    Test.add_func("/dictation/engine/installed", test_installed_and_checksum);
    Test.add_func("/dictation/engine/whisper-flow", test_whisper_engine_flow);
    Test.add_func("/dictation/engine/stream-flow", test_stream_engine_flow);
    Test.add_func("/dictation/engine/stream-crash", test_stream_engine_crash);
    Test.add_func("/dictation/engine/file", test_file_transcriber);
    Test.add_func("/dictation/engine/file-failure", test_file_transcriber_failure);
    return Test.run();
}
