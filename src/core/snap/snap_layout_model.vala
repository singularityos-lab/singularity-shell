namespace Singularity {

    public struct SnapRect {
        public int x;
        public int y;
        public int width;
        public int height;

        public SnapRect(int x, int y, int width, int height) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
        }

        public bool contains(int px, int py) {
            return px >= x && py >= y && px < x + width && py < y + height;
        }

        public bool is_empty() {
            return width <= 0 || height <= 0;
        }
    }

    public class SnapZone : Object {
        public int x { get; construct; }
        public int y { get; construct; }
        public int width { get; construct; }
        public int height { get; construct; }

        public SnapZone(int x, int y, int width, int height) {
            Object(x: x, y: y, width: width, height: height);
        }

        public SnapRect rect_in(SnapRect area) {
            int left = area.x + (int) ((int64) area.width * x / 1000);
            int right = area.x + (int) ((int64) area.width * (x + width) / 1000);
            int top = area.y + (int) ((int64) area.height * y / 1000);
            int bottom = area.y + (int) ((int64) area.height * (y + height) / 1000);
            return SnapRect(left, top, right - left, bottom - top);
        }

        public bool same_as(SnapZone other) {
            return x == other.x && y == other.y
                && width == other.width && height == other.height;
        }
    }

    public class SnapLayout : Object {
        public string id { get; construct; }
        public string name { get; construct; }
        public SnapZone[] zones;

        public SnapLayout(string id, string name, SnapZone[] zones) {
            Object(id: id, name: name);
            this.zones = zones;
        }

        public int index_of(SnapZone zone) {
            for (int i = 0; i < zones.length; i++) {
                if (zones[i].same_as(zone)) return i;
            }
            return -1;
        }

        public SnapZone[] remaining(SnapZone taken) {
            SnapZone[] rest = {};
            foreach (var zone in zones) {
                if (!zone.same_as(taken)) rest += zone;
            }
            return rest;
        }
    }

    public enum SnapAspect {
        PORTRAIT,
        STANDARD,
        ULTRAWIDE;

        public static SnapAspect for_size(int width, int height) {
            if (width <= 0 || height <= 0) return STANDARD;
            double ratio = (double) width / height;
            if (ratio < 1.0) return PORTRAIT;
            if (ratio >= 2.1) return ULTRAWIDE;
            return STANDARD;
        }
    }

    public class SnapLayoutModel : Object {
        public const int THIRD = 333;
        public const int TWO_THIRDS = 667;

        private static SnapZone z(int x, int y, int w, int h) {
            return new SnapZone(x, y, w, h);
        }

        private static SnapLayout halves() {
            return new SnapLayout("halves", _("Halves"), {
                z(0, 0, 500, 1000), z(500, 0, 500, 1000)
            });
        }

        private static SnapLayout wide_narrow() {
            return new SnapLayout("two-thirds", _("Two Thirds and One Third"), {
                z(0, 0, TWO_THIRDS, 1000), z(TWO_THIRDS, 0, 1000 - TWO_THIRDS, 1000)
            });
        }

        private static SnapLayout thirds() {
            return new SnapLayout("thirds", _("Thirds"), {
                z(0, 0, THIRD, 1000),
                z(THIRD, 0, TWO_THIRDS - THIRD, 1000),
                z(TWO_THIRDS, 0, 1000 - TWO_THIRDS, 1000)
            });
        }

        private static SnapLayout quarters() {
            return new SnapLayout("quarters", _("Quarters"), {
                z(0, 0, 500, 500), z(500, 0, 500, 500),
                z(0, 500, 500, 500), z(500, 500, 500, 500)
            });
        }

        private static SnapLayout half_and_quarters() {
            return new SnapLayout("half-quarters", _("Half and Quarters"), {
                z(0, 0, 500, 1000), z(500, 0, 500, 500), z(500, 500, 500, 500)
            });
        }

        private static SnapLayout wide_center() {
            return new SnapLayout("wide-center", _("Wide Center"), {
                z(0, 0, 250, 1000), z(250, 0, 500, 1000), z(750, 0, 250, 1000)
            });
        }

        private static SnapLayout four_columns() {
            return new SnapLayout("columns", _("Four Columns"), {
                z(0, 0, 250, 1000), z(250, 0, 250, 1000),
                z(500, 0, 250, 1000), z(750, 0, 250, 1000)
            });
        }

        private static SnapLayout stacked_halves() {
            return new SnapLayout("rows", _("Top and Bottom"), {
                z(0, 0, 1000, 500), z(0, 500, 1000, 500)
            });
        }

        private static SnapLayout stacked_two_thirds() {
            return new SnapLayout("rows-two-thirds", _("Two Thirds and One Third"), {
                z(0, 0, 1000, TWO_THIRDS), z(0, TWO_THIRDS, 1000, 1000 - TWO_THIRDS)
            });
        }

        private static SnapLayout stacked_thirds() {
            return new SnapLayout("rows-thirds", _("Thirds"), {
                z(0, 0, 1000, THIRD),
                z(0, THIRD, 1000, TWO_THIRDS - THIRD),
                z(0, TWO_THIRDS, 1000, 1000 - TWO_THIRDS)
            });
        }

        public static SnapLayout[] layouts_for(int width, int height) {
            switch (SnapAspect.for_size(width, height)) {
                case SnapAspect.PORTRAIT:
                    return {
                        stacked_halves(), stacked_two_thirds(), stacked_thirds(), quarters()
                    };
                case SnapAspect.ULTRAWIDE:
                    return {
                        halves(), wide_narrow(), thirds(), wide_center(), four_columns(), quarters()
                    };
                default:
                    return {
                        halves(), wide_narrow(), thirds(), quarters(), half_and_quarters()
                    };
            }
        }

        public static SnapLayout? find(SnapLayout[] layouts, SnapZone zone) {
            foreach (var layout in layouts) {
                if (layout.index_of(zone) >= 0) return layout;
            }
            return null;
        }

        public static SnapZone? zone_at(SnapLayout layout, SnapRect cell, int px, int py) {
            foreach (var zone in layout.zones) {
                if (zone.rect_in(cell).contains(px, py)) return zone;
            }
            return null;
        }

        public static bool overlaps(SnapZone a, SnapZone b) {
            return a.x < b.x + b.width && b.x < a.x + a.width
                && a.y < b.y + b.height && b.y < a.y + a.height;
        }
    }
}
