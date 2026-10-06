using Singularity.Tablet;

void assert_close(double a, double b) {
    if ((a - b).abs() > 1e-6) error("expected %f, got %f", b, a);
}

void test_fit_aspect() {
    var wide = Geometry.fit_aspect(Area(0, 0, 200, 100), 16, 9);
    assert_close(wide.height, 100);
    assert_close(wide.width, 100.0 * 16 / 9);
    assert_close(wide.x, (200 - 100.0 * 16 / 9) / 2);
    assert_close(wide.y, 0);
    var tall = Geometry.fit_aspect(Area(10, 10, 160, 160), 16, 9);
    assert_close(tall.width, 160);
    assert_close(tall.height, 90);
    assert_close(tall.x, 10);
    assert_close(tall.y, 45);
    var same = Geometry.fit_aspect(Area(0, 0, 160, 90), 1920, 1080);
    assert_close(same.width, 160);
    assert_close(same.height, 90);
    var none = Geometry.fit_aspect(Area(0, 0, 160, 90), 0, 1080);
    assert_close(none.width, 160);
}

void test_active_area() {
    var whole = Geometry.active_area(224, 148, false, Area(0, 0, 0, 0), false, 1920, 1080);
    assert_close(whole.width, 224);
    assert_close(whole.height, 148);
    var kept = Geometry.active_area(224, 148, false, Area(0, 0, 0, 0), true, 1920, 1080);
    assert_close(kept.width, 224);
    assert_close(kept.height, 126);
    assert_close(kept.y, 11);
    var custom = Geometry.active_area(224, 148, true, Area(20, 10, 100, 60), false, 1920, 1080);
    assert_close(custom.x, 20);
    assert_close(custom.y, 10);
    assert_close(custom.width, 100);
    assert_close(custom.height, 60);
    var clamped = Geometry.active_area(224, 148, true, Area(200, 100, 100, 100), false, 1920, 1080);
    assert_close(clamped.width, 24);
    assert_close(clamped.height, 48);
    var empty = Geometry.active_area(224, 148, true, Area(0, 0, 0, 0), false, 1920, 1080);
    assert_close(empty.width, 224);
}

void test_curve() {
    double[] linear = PressureCurve.preset(PressureCurve.LINEAR);
    for (int i = 0; i <= 10; i++) assert_close(PressureCurve.apply(linear, i / 10.0), i / 10.0);
    double[] soft = PressureCurve.preset(0);
    double[] firm = PressureCurve.preset(4);
    double last = 0;
    for (int i = 1; i < 100; i++) {
        double p = i / 100.0;
        assert(PressureCurve.apply(soft, p) > p);
        assert(PressureCurve.apply(firm, p) < p);
        double v = PressureCurve.apply(soft, p);
        assert(v >= last);
        last = v;
    }
    assert_close(PressureCurve.apply(soft, 0), 0);
    assert_close(PressureCurve.apply(soft, 1), 1);
    assert(PressureCurve.preset_index(PressureCurve.preset(3)) == 3);
    assert(PressureCurve.preset_index({ 0.1, 0.2, 0.3, 0.4 }) == -1);
}

void test_state() {
    string data = "[Tablet 1]\nName=Wacom Intuos Pro M Pen\nVendorId=1386\nProductId=855\nWidthMm=224.00\nHeightMm=148.50\nPadButtons=8\nPadRings=1\nPadStrips=0\n\n[Tool 1]\nType=pen\nSerial=0\nPressure=true\nTilt=true\nButtons=Stylus;Stylus2;Stylus3;\n";
    var state = State.parse(data);
    assert(state.devices.size == 1);
    assert(state.primary.name == "Wacom Intuos Pro M Pen");
    assert(state.primary.vendor_id == 1386);
    assert_close(state.primary.height_mm, 148.5);
    assert(state.pad_buttons == 8);
    assert(state.tools.size == 1);
    assert(state.tools[0].pressure);
    assert(state.has_button("Stylus3"));
    assert(!state.has_button("Stylus4"));
    assert(State.parse("").devices.size == 0);
    assert(State.parse("garbage [").devices.size == 0);
}

void test_shortcut() {
    uint mods;
    string key;
    assert(Shortcut.parse("ctrl+shift+z", out mods, out key));
    assert(mods == (Shortcut.CTRL | Shortcut.SHIFT));
    assert(key == "z");
    assert(Shortcut.parse("Escape", out mods, out key));
    assert(mods == 0 && key == "Escape");
    assert(Shortcut.parse("ctrl+plus", out mods, out key) && key == "plus");
    assert(!Shortcut.parse("ctrl+", out mods, out key));
    assert(!Shortcut.parse("hyper+z", out mods, out key));
}

void test_rc() {
    var input = new RcInput();
    input.output = "HDMI-A-1";
    input.area = Area(10, 5.5, 120, 80);
    input.left_handed = true;
    input.curve = PressureCurve.preset(1);
    input.mouse_mode = true;
    input.stylus["Stylus"] = "middle";
    input.stylus["Stylus2"] = "default";
    input.pad["Pad"] = "none";
    input.pad["Pad2"] = "right";
    input.pad["Pad3"] = "action:toggle_workspace_overview";
    input.pad["Pad4"] = "key:ctrl+z";
    input.pad["Pad5"] = "default";
    input.command = "gdbus call --method X";
    string xml = Rc.build(input);
    assert(xml.contains("<tablet rotate=\"180\" mouseEmulation=\"no\">"));
    assert(xml.contains("<mapToOutput>HDMI-A-1</mapToOutput>"));
    assert(xml.contains("<area top=\"5.500\" left=\"10.000\" width=\"120.000\" height=\"80.000\" />"));
    assert(xml.contains("<map button=\"Stylus\" to=\"Middle\" />"));
    assert(!xml.contains("button=\"Stylus2\""));
    assert(xml.contains("<padbind button=\"Pad\" />"));
    assert(xml.contains("<padbind button=\"Pad2\" to=\"Right\" />"));
    assert(xml.contains("<command>gdbus call --method X toggle_workspace_overview</command>"));
    assert(xml.contains("<command>gdbus call --method X tablet-key:ctrl+z</command>"));
    assert(!xml.contains("Pad5"));
    assert(xml.contains("motion=\"relative\""));
    assert(xml.contains("pressureCurve=\"0.000,0.300,0.700,1.000\""));
    var plain = Rc.build(new RcInput());
    assert(plain.contains("<tablet rotate=\"0\""));
    assert(!plain.contains("mapToOutput"));
    assert(!plain.contains("<area"));
    assert(!plain.contains("pressureCurve"));
    assert(plain.contains("motion=\"absolute\""));
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/tablet/fit-aspect", test_fit_aspect);
    Test.add_func("/tablet/active-area", test_active_area);
    Test.add_func("/tablet/curve", test_curve);
    Test.add_func("/tablet/state", test_state);
    Test.add_func("/tablet/shortcut", test_shortcut);
    Test.add_func("/tablet/rc", test_rc);
    return Test.run();
}
