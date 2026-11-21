#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>
#include <gtk/gtk.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-pacing-unstable-v1-client-protocol.h"
#include "frame_pacing.h"

struct named_output {
	struct wl_output *output;
	uint32_t global;
	char *name;
	struct named_output *next;
};

static struct {
	struct wl_display *display;
	struct wl_registry *registry;
	struct zsingularity_pacing_manager_v1 *manager;
	struct named_output *outputs;
	GHashTable *rates;
} fp;

static void
send_rate(struct named_output *out, uint32_t rate)
{
	if (!fp.manager || !out->name) {
		return;
	}
	zsingularity_pacing_manager_v1_set_max_rate(fp.manager, out->output, rate);
	wl_display_flush(fp.display);
}

static void
output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw,
		int32_t ph, int32_t sub, const char *make, const char *model, int32_t t) {}
static void output_mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t r) {}
static void output_done(void *d, struct wl_output *o) {}
static void output_scale(void *d, struct wl_output *o, int32_t s) {}
static void output_description(void *d, struct wl_output *o, const char *desc) {}

static void
output_name(void *data, struct wl_output *o, const char *name)
{
	struct named_output *out = data;
	free(out->name);
	out->name = strdup(name);
	gpointer rate;
	if (fp.rates && g_hash_table_lookup_extended(fp.rates, name, NULL, &rate)) {
		send_rate(out, GPOINTER_TO_UINT(rate));
	}
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	if (strcmp(interface, zsingularity_pacing_manager_v1_interface.name) == 0
			&& !fp.manager) {
		fp.manager = wl_registry_bind(registry, name,
			&zsingularity_pacing_manager_v1_interface, 1);
	} else if (strcmp(interface, wl_output_interface.name) == 0 && version >= 4) {
		struct named_output *out = calloc(1, sizeof(*out));
		if (!out) {
			return;
		}
		out->global = name;
		out->output = wl_registry_bind(registry, name, &wl_output_interface, 4);
		wl_output_add_listener(out->output, &output_listener, out);
		out->next = fp.outputs;
		fp.outputs = out;
	}
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	for (struct named_output **link = &fp.outputs; *link; link = &(*link)->next) {
		struct named_output *out = *link;
		if (out->global == name) {
			*link = out->next;
			wl_output_destroy(out->output);
			free(out->name);
			free(out);
			return;
		}
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

int
singularity_frame_pacing_init(void)
{
	if (fp.registry) {
		return fp.manager != NULL;
	}
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gdk_display_get_default();
	if (!gdk_display || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return 0;
	}
	fp.rates = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
	fp.display = gdk_wayland_display_get_wl_display(GDK_WAYLAND_DISPLAY(gdk_display));
	fp.registry = wl_display_get_registry(fp.display);
	wl_registry_add_listener(fp.registry, &registry_listener, NULL);
	wl_display_roundtrip(fp.display);
	wl_display_roundtrip(fp.display);
	return fp.manager != NULL;
#else
	return 0;
#endif
}

void
singularity_frame_pacing_set(const char *connector, uint32_t rate)
{
	if (!connector || !fp.rates) {
		return;
	}
	g_hash_table_insert(fp.rates, g_strdup(connector), GUINT_TO_POINTER(rate));
	for (struct named_output *out = fp.outputs; out; out = out->next) {
		if (out->name && strcmp(out->name, connector) == 0) {
			send_rate(out, rate);
		}
	}
}
