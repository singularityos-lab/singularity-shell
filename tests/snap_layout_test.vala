using GLib;
using Singularity;

private bool has_layout(SnapLayout[] layouts, string id) {
    foreach (var l in layouts) {
        if (l.id == id) return true;
    }
    return false;
}

private void test_aspect() {
    assert(SnapAspect.for_size(1920, 1080) == SnapAspect.STANDARD);
    assert(SnapAspect.for_size(1280, 1024) == SnapAspect.STANDARD);
    assert(SnapAspect.for_size(3440, 1440) == SnapAspect.ULTRAWIDE);
    assert(SnapAspect.for_size(5120, 1440) == SnapAspect.ULTRAWIDE);
    assert(SnapAspect.for_size(1080, 1920) == SnapAspect.PORTRAIT);
    assert(SnapAspect.for_size(0, 0) == SnapAspect.STANDARD);
}

private void test_layout_sets() {
    var standard = SnapLayoutModel.layouts_for(1920, 1040);
    foreach (var id in new string[] { "halves", "two-thirds", "thirds", "quarters", "half-quarters" }) {
        assert(has_layout(standard, id));
    }
    assert(!has_layout(standard, "wide-center"));
    var wide = SnapLayoutModel.layouts_for(3440, 1400);
    assert(has_layout(wide, "wide-center"));
    assert(has_layout(wide, "columns"));
    var tall = SnapLayoutModel.layouts_for(1080, 1880);
    assert(has_layout(tall, "rows"));
    assert(!has_layout(tall, "halves"));
}

private void test_zones_tile_the_area() {
    int[] widths = { 1920, 3440, 1080 };
    int[] heights = { 1040, 1400, 1880 };
    for (int s = 0; s < widths.length; s++) {
        var area = SnapRect(100, 36, widths[s], heights[s]);
        foreach (var layout in SnapLayoutModel.layouts_for(widths[s], heights[s])) {
            int64 covered = 0;
            for (int i = 0; i < layout.zones.length; i++) {
                var zone = layout.zones[i];
                assert(zone.x >= 0 && zone.y >= 0);
                assert(zone.x + zone.width <= 1000 && zone.y + zone.height <= 1000);
                var r = zone.rect_in(area);
                assert(!r.is_empty());
                covered += (int64) r.width * r.height;
                for (int j = i + 1; j < layout.zones.length; j++) {
                    assert(!SnapLayoutModel.overlaps(zone, layout.zones[j]));
                }
            }
            assert(covered == (int64) area.width * area.height);
        }
    }
}

private void test_rect_math() {
    var area = SnapRect(0, 32, 1920, 1048);
    var left = new SnapZone(0, 0, 500, 1000).rect_in(area);
    assert(left.x == 0 && left.y == 32 && left.width == 960 && left.height == 1048);
    var right = new SnapZone(500, 0, 500, 1000).rect_in(area);
    assert(right.x == 960 && right.width == 960);
    var third = new SnapZone(SnapLayoutModel.THIRD, 0, SnapLayoutModel.TWO_THIRDS - SnapLayoutModel.THIRD, 1000).rect_in(area);
    assert(third.x == 639 && third.x + third.width == 1280);
    var quarter = new SnapZone(500, 500, 500, 500).rect_in(area);
    assert(quarter.x == 960 && quarter.y == 32 + 524 && quarter.height == 524);
}

private void test_hit_and_remaining() {
    var layouts = SnapLayoutModel.layouts_for(1920, 1080);
    SnapLayout? quarters = null;
    foreach (var l in layouts) if (l.id == "quarters") quarters = l;
    assert(quarters != null);
    var cell = SnapRect(0, 0, 92, 52);
    var zone = SnapLayoutModel.zone_at(quarters, cell, 80, 40);
    assert(zone != null && zone.x == 500 && zone.y == 500);
    assert(SnapLayoutModel.zone_at(quarters, cell, 92, 10) == null);
    assert(SnapLayoutModel.zone_at(quarters, cell, -1, 10) == null);
    var rest = quarters.remaining(zone);
    assert(rest.length == 3);
    foreach (var r in rest) assert(!r.same_as(zone));
    assert(SnapLayoutModel.find(layouts, zone) != null);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/snap/aspect", test_aspect);
    Test.add_func("/snap/layout-sets", test_layout_sets);
    Test.add_func("/snap/zones-tile-area", test_zones_tile_the_area);
    Test.add_func("/snap/rect-math", test_rect_math);
    Test.add_func("/snap/hit-and-remaining", test_hit_and_remaining);
    return Test.run();
}
