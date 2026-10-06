public class MarkupApp : Singularity.Application {
    private bool in_place = false;

    public MarkupApp() {
        Object(application_id: "dev.sinty.markup", flags: ApplicationFlags.HANDLES_OPEN | ApplicationFlags.NON_UNIQUE);
        add_main_option("in-place", 0, OptionFlags.NONE, OptionArg.NONE, _("Save changes over the original image"), null);
        handle_local_options.connect((options) => {
            in_place = options.contains("in-place");
            return -1;
        });
    }

    public override void activate() {
        if (get_active_window() == null) {
            stderr.printf("%s\n", _("Usage: singularity-markup [--in-place] IMAGE"));
            quit();
        }
    }

    public override void open(File[] files, string hint) {
        foreach (var file in files) {
            var window = new Singularity.Widgets.MarkupWindow(this, file, in_place);
            window.present();
        }
    }
}

int main(string[] args) {
    Intl.setlocale(LocaleCategory.ALL, "");
    return new MarkupApp().run(args);
}
