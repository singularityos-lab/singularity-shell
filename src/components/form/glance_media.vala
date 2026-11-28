using Gtk;

namespace Singularity {

    public class GlanceMedia : Box {
        private Singularity.Widgets.MediaArtwork _artwork;
        private Label _title;
        private Label _artist;
        private Label _source;
        private ProgressBar _progress;
        private Image _play_icon;
        private Box _controls;
        private Box _empty;
        private Box _info;
        private ulong _sig = 0;
        private uint _tick = 0;
        private uint _cover_serial = uint.MAX;
        private bool _full;

        public signal void expand();

        public int cover_size {
            get { return _artwork.size; }
            set { _artwork.size = value; }
        }

        public GlanceMedia(bool full, int cover, string card_class) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            _full = full;
            add_css_class(card_class);
            add_css_class("glance-media");
            if (full) add_css_class("glance-media-full");
            hexpand = true;
            vexpand = true;

            var body = new Box(Orientation.HORIZONTAL, 0);
            body.add_css_class("glance-media-body");
            body.vexpand = true;
            body.hexpand = true;
            _artwork = new Singularity.Widgets.MediaArtwork(cover, full ? 32 : 20);
            _artwork.add_css_class("glance-media-art");
            _artwork.halign = Align.START;
            _artwork.valign = Align.CENTER;
            body.append(_artwork);

            _info = new Box(Orientation.VERTICAL, 0);
            _info.add_css_class("glance-media-info");
            _info.hexpand = true;
            _info.valign = Align.CENTER;
            _source = new Label("");
            _source.add_css_class("glance-media-source");
            _source.xalign = 0;
            _title = new Label("");
            _title.add_css_class("glance-media-title");
            _title.xalign = 0;
            _title.ellipsize = Pango.EllipsizeMode.END;
            _artist = new Label("");
            _artist.add_css_class("glance-media-artist");
            _artist.xalign = 0;
            _artist.ellipsize = Pango.EllipsizeMode.END;
            _info.append(_source);
            _info.append(_title);
            _info.append(_artist);
            _progress = new ProgressBar();
            _progress.add_css_class("glance-media-progress");
            _progress.visible = full;
            _info.append(_progress);
            _controls = new Box(Orientation.HORIZONTAL, 0);
            _controls.add_css_class("glance-media-controls");
            _controls.halign = Align.START;
            _controls.append(control("media-skip-backward-symbolic", _("Previous"), () => NowPlayingCache.get_default().previous.begin()));
            var play = control("media-playback-start-symbolic", _("Play"), () => NowPlayingCache.get_default().play_pause.begin());
            play.add_css_class("glance-media-play");
            _play_icon = (Image) play.child;
            _controls.append(play);
            _controls.append(control("media-skip-forward-symbolic", _("Next"), () => NowPlayingCache.get_default().next.begin()));
            _info.append(_controls);
            body.append(_info);
            append(body);

            _empty = new Box(Orientation.VERTICAL, 0);
            _empty.vexpand = true;
            _empty.valign = Align.CENTER;
            var nothing = new Label(_("Nothing playing"));
            nothing.add_css_class("glance-title");
            nothing.xalign = 0;
            _empty.append(nothing);
            var hint = new Label(_("Music, podcasts and radio show up here."));
            hint.add_css_class("glance-subtitle");
            hint.xalign = 0;
            hint.wrap = true;
            _empty.append(hint);
            append(_empty);

            if (!full) {
                var click = new GestureClick();
                click.released.connect(() => expand());
                _artwork.add_controller(click);
            }
            _sig = NowPlayingCache.get_default().changed.connect(() => update());
            map.connect(() => update());
            unmap.connect(() => stop_ticking());
            update();
        }

        public override void dispose() {
            stop_ticking();
            if (_sig != 0) {
                NowPlayingCache.get_default().disconnect(_sig);
                _sig = 0;
            }
            base.dispose();
        }

        private Button control(string icon, string label, owned VoidFunc action) {
            var image = new Image.from_icon_name(icon);
            var button = new Button();
            button.child = image;
            button.add_css_class("glance-round");
            button.tooltip_text = label;
            button.update_property(Gtk.AccessibleProperty.LABEL, label, -1);
            button.clicked.connect(() => action());
            return button;
        }

        public delegate void VoidFunc();

        private void update() {
            var np = NowPlayingCache.get_default();
            bool active = np.active && (np.title != "" || np.artist != "");
            _artwork.visible = active;
            _info.visible = active;
            _empty.visible = !active;
            if (!active) {
                stop_ticking();
                return;
            }
            _title.label = np.title != "" ? np.title : _("Unknown Title");
            _artist.label = np.artist;
            _artist.visible = np.artist != "";
            var info = np.app_id != "" ? new GLib.DesktopAppInfo(np.app_id.has_suffix(".desktop") ? np.app_id : np.app_id + ".desktop") : null;
            _source.label = info != null ? info.get_display_name() : _("Now Playing");
            _artwork.set_app(np.app_id);
            if (np.cover_serial != _cover_serial) {
                _cover_serial = np.cover_serial;
                Gdk.Texture? cover = null;
                if (np.cover_path != "") {
                    try {
                        cover = Gdk.Texture.from_filename(np.cover_path);
                    } catch (Error e) {
                        cover = null;
                    }
                }
                _artwork.cover = cover;
            }
            _play_icon.icon_name = np.playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
            update_position();
            if (_full && np.playing && np.length_us > 0 && get_mapped()) {
                if (_tick == 0) _tick = Timeout.add_seconds(1, () => {
                    update_position();
                    return Source.CONTINUE;
                });
            } else {
                stop_ticking();
            }
        }

        private void update_position() {
            var np = NowPlayingCache.get_default();
            if (!_full || np.length_us <= 0) return;
            _progress.fraction = ((double) np.position_us() / np.length_us).clamp(0.0, 1.0);
        }

        private void stop_ticking() {
            if (_tick != 0) {
                Source.remove(_tick);
                _tick = 0;
            }
        }
    }
}
