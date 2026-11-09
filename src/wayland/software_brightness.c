#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>
#include <gtk/gtk.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-brightness-unstable-v1-client-protocol.h"
#include "software_brightness.h"

struct named_output {
	struct wl_output *output;
	uint32_t global;
	char *name;
	struct named_output *next;
};

static struct {
	struct wl_display *display;
	struct wl_registry *registry;
	struct zsingularity_brightness_manager_v1 *manager;
	struct named_output *outputs;
	GHashTable *pending;
	SingularitySoftwareBrightnessReset reset;
	void *data;
} sb;

static void
send_level(struct named_output *out, uint32_t level)
{
	if (!sb.manager || !out->name) {
		return;
	}
	zsingularity_brightness_manager_v1_set_brightness(sb.manager, out->output, level);
	wl_display_flush(sb.display);
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
	gpointer level;
	if (sb.pending && g_hash_table_lookup_extended(sb.pending, name, NULL, &level)) {
		send_level(out, GPOINTER_TO_UINT(level));
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
handle_reset(void *data, struct zsingularity_brightness_manager_v1 *manager)
{
	if (sb.pending) {
		g_hash_table_remove_all(sb.pending);
	}
	if (sb.reset) {
		sb.reset(sb.data);
	}
}

static const struct zsingularity_brightness_manager_v1_listener manager_listener = {
	.reset = handle_reset,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	if (strcmp(interface, zsingularity_brightness_manager_v1_interface.name) == 0
			&& !sb.manager) {
		sb.manager = wl_registry_bind(registry, name,
			&zsingularity_brightness_manager_v1_interface, 1);
		zsingularity_brightness_manager_v1_add_listener(sb.manager, &manager_listener, NULL);
	} else if (strcmp(interface, wl_output_interface.name) == 0 && version >= 4) {
		struct named_output *out = calloc(1, sizeof(*out));
		if (!out) {
			return;
		}
		out->global = name;
		out->output = wl_registry_bind(registry, name, &wl_output_interface, 4);
		wl_output_add_listener(out->output, &output_listener, out);
		out->next = sb.outputs;
		sb.outputs = out;
	}
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	for (struct named_output **link = &sb.outputs; *link; link = &(*link)->next) {
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
singularity_software_brightness_init(SingularitySoftwareBrightnessReset reset, void *data)
{
	sb.reset = reset;
	sb.data = data;
	if (sb.registry) {
		return sb.manager != NULL;
	}
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gdk_display_get_default();
	if (!gdk_display || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return 0;
	}
	sb.pending = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
	sb.display = gdk_wayland_display_get_wl_display(GDK_WAYLAND_DISPLAY(gdk_display));
	sb.registry = wl_display_get_registry(sb.display);
	wl_registry_add_listener(sb.registry, &registry_listener, NULL);
	wl_display_roundtrip(sb.display);
	wl_display_roundtrip(sb.display);
	return sb.manager != NULL;
#else
	return 0;
#endif
}

int
singularity_software_brightness_supported(void)
{
	return sb.manager != NULL;
}

void
singularity_software_brightness_set(const char *connector, uint32_t level)
{
	if (!connector) {
		return;
	}
	if (sb.pending) {
		g_hash_table_insert(sb.pending, g_strdup(connector), GUINT_TO_POINTER(level));
	}
	for (struct named_output *out = sb.outputs; out; out = out->next) {
		if (out->name && strcmp(out->name, connector) == 0) {
			send_level(out, level);
		}
	}
}
