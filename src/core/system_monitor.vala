namespace Singularity {

    public class SystemMonitor : Object {
        private static SystemMonitor? _instance;

        public PowerManager power { get { if (_power == null) _power = new PowerManager(); return _power; } }
        public NetworkManagerWrapper network { get { if (_network == null) _network = new NetworkManagerWrapper(); return _network; } }
        public AudioManager audio { get { if (_audio == null) _audio = new AudioManager(); return _audio; } }
        public BrightnessManager brightness { get { if (_brightness == null) _brightness = BrightnessManager.get_default(); return _brightness; } }
        public KbdBrightnessManager kbd_brightness { get { if (_kbd_brightness == null) _kbd_brightness = new KbdBrightnessManager(); return _kbd_brightness; } }
        public NightLightManager night_light { get { if (_night_light == null) { _night_light = new NightLightManager(); _night_light.backend = new WaylandGammaBackend(); } return _night_light; } }
        public ShortcutManager shortcuts { get { if (_shortcuts == null) _shortcuts = new ShortcutManager(); return _shortcuts; } }
        public NotificationManager notifications { get { if (_notifications == null) _notifications = new NotificationManager(); return _notifications; } }
        public DateTimeManager datetime { get { if (_datetime == null) _datetime = new DateTimeManager(); return _datetime; } }
        public LocaleManager locale { get { if (_locale == null) _locale = new LocaleManager(); return _locale; } }
        public BluetoothManager bluetooth { get { if (_bluetooth == null) _bluetooth = new BluetoothManager(); return _bluetooth; } }
        public PowerProfilesManager power_profiles { get { if (_power_profiles == null) _power_profiles = new PowerProfilesManager(); return _power_profiles; } }
        public ResourceMonitor resources { get { if (_resources == null) _resources = new ResourceMonitor(); return _resources; } }
        public CallMonitor call_monitor { get { if (_call_monitor == null) _call_monitor = new CallMonitor(audio); return _call_monitor; } }

        private PowerManager? _power;
        private NetworkManagerWrapper? _network;
        private AudioManager? _audio;
        private BrightnessManager? _brightness;
        private KbdBrightnessManager? _kbd_brightness;
        private NightLightManager? _night_light;
        private ShortcutManager? _shortcuts;
        private NotificationManager? _notifications;
        private DateTimeManager? _datetime;
        private LocaleManager? _locale;
        private BluetoothManager? _bluetooth;
        private PowerProfilesManager? _power_profiles;
        private ResourceMonitor? _resources;
        private CallMonitor? _call_monitor;

        public static SystemMonitor get_default() {
            if (_instance == null) {
                _instance = new SystemMonitor();
            }
            return _instance;
        }

        private SystemMonitor() {
        }
    }
}