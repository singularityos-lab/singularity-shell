using GLib;
using Gdk;
using Singularity;

private Pixbuf solid(int width, int height, uint8 r, uint8 g, uint8 b) {
    var pb = new Pixbuf(Colorspace.RGB, true, 8, width, height);
    unowned uint8[] p = pb.get_pixels_with_length(); int s = pb.get_rowstride(), c = pb.get_n_channels();
    for (int y=0; y<height; y++) for (int x=0; x<width; x++) {
        int i=y*s+x*c; p[i]=r; p[i+1]=g; p[i+2]=b; p[i+3]=255;
    }
    return pb;
}

private WallpaperEffects fixture(out string root) {
    try { root = DirUtils.make_tmp("wallpaper-effects-XXXXXX"); }
    catch (Error e) { error("fixture: %s", e.message); }
    return new WallpaperEffects(root);
}

private void test_settings_roundtrip() {
    var schema = SettingsSchemaSource.get_default().lookup("dev.sinty.desktop", true);
    assert(schema != null);
    var settings = new GLib.Settings.full(schema,
        SettingsBackend.memory_settings_backend_new(), null);
    assert(settings.set_string("wallpaper-effect", "quote"));
    assert(settings.set_int("wallpaper-effect-blur-radius", 16));
    assert(settings.set_string("wallpaper-effect-quote-text", "Hello world"));
    assert(settings.get_string("wallpaper-effect") == "quote");
    assert(settings.get_int("wallpaper-effect-blur-radius") == 16);
    assert(settings.get_string("wallpaper-effect-quote-text") == "Hello world");
}

private void test_grayscale() {
    string root; var fx=fixture(out root); var result=fx.apply_grayscale(solid(2,2,230,40,90), "color");
    uint8[] p=result.get_pixels_with_length(); assert(p[0]==p[1] && p[1]==p[2]); assert(p[0] != 230);
}

private void test_blur() {
    string root; var fx=fixture(out root); var pb=solid(9,3,0,0,0);
    unowned uint8[] p=pb.get_pixels_with_length(); int s=pb.get_rowstride(), c=pb.get_n_channels();
    for (int y=0;y<3;y++) for(int x=5;x<9;x++) { int i=y*s+x*c; p[i]=p[i+1]=p[i+2]=255; }
    var result=fx.apply_blur(pb,"edge",1); uint8[] q=result.get_pixels_with_length();
    int right=1*s+5*c; assert(q[right]>0 && q[right]<255);
}

private void test_cache_hit() {
    string root; var fx=fixture(out root); var pb=solid(2,2,255,0,0);
    var first=fx.apply_grayscale(pb,"stable"); uint8 expected=first.get_pixels_with_length()[0];
    unowned uint8[] source=pb.get_pixels_with_length(); source[0]=source[1]=source[2]=255;
    var second=fx.apply_grayscale(pb,"stable"); uint8[] cached=second.get_pixels_with_length();
    assert(cached[0]==expected && cached[0] < 255);
}

private void test_oil_paint() {
    string root; var fx=fixture(out root); var pb=solid(7,5,20,90,180);
    var result=fx.apply_oil_paint(pb,"oil",2); assert(result.width==7 && result.height==5);
}

private void test_quote_overlay() {
    string root; var fx=fixture(out root); var pb=solid(320,180,30,60,90);
    var result=fx.apply_quote_overlay(pb,"quote","Hello world","Sans Bold 24");
    uint8[] p=result.get_pixels_with_length(); int s=result.rowstride, c=result.n_channels; bool changed=false;
    for(int y=90;y<180 && !changed;y++) for(int x=0;x<320;x++) { int i=y*s+x*c; if(p[i]!=30 || p[i+1]!=60 || p[i+2]!=90) { changed=true; break; } }
    assert(changed); assert(result.width==320 && result.height==180);
}

public int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/wallpaper-effects/grayscale", test_grayscale);
    Test.add_func("/wallpaper-effects/blur", test_blur);
    Test.add_func("/wallpaper-effects/cache-hit", test_cache_hit);
    Test.add_func("/wallpaper-effects/oil-paint", test_oil_paint);
    Test.add_func("/wallpaper-effects/quote-overlay", test_quote_overlay);
    Test.add_func("/wallpaper-effects/settings-roundtrip", test_settings_roundtrip);
    return Test.run();
}
