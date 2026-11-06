using Gtk;

namespace Singularity {

    public delegate Gtk.ListBoxRow SearchRowFactory(SearchResult result);

    public class SearchRowCache : GLib.Object {
        private HashTable<SearchResult, Gtk.ListBoxRow> rows =
            new HashTable<SearchResult, Gtk.ListBoxRow>(direct_hash, direct_equal);
        private SearchRowFactory factory;

        public SearchRowCache(owned SearchRowFactory factory) {
            this.factory = (owned) factory;
        }

        public void apply(Gtk.ListBox list, List<SearchResult> results) {
            var wanted = new HashTable<SearchResult, bool>(direct_hash, direct_equal);
            int index = 0;
            foreach (var result in results) {
                wanted[result] = true;
                var row = rows[result];
                if (row == null) {
                    row = factory(result);
                    rows[result] = row;
                }
                if (list.get_row_at_index(index) != row) {
                    if (row.get_parent() == list) list.remove(row);
                    list.insert(row, index);
                }
                index++;
            }
            var stale = list.get_row_at_index(index);
            while (stale != null) {
                list.remove(stale);
                stale = list.get_row_at_index(index);
            }
            var gone = new GenericArray<SearchResult>();
            rows.foreach((result, row) => {
                if (!wanted.contains(result)) gone.add(result);
            });
            foreach (var result in gone.data) rows.remove(result);
        }

        public void clear(Gtk.ListBox list) {
            var child = list.get_first_child();
            while (child != null) {
                list.remove(child);
                child = list.get_first_child();
            }
            rows.remove_all();
        }
    }
}
