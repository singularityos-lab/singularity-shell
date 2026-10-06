#define _POSIX_C_SOURCE 200809L

#include <string.h>
#include <gtk/gtk.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-key-hold-unstable-v1-client-protocol.h"
#include "key_hold.h"

static struct {
	struct wl_display *display;
	struct wl_registry *registry;
	struct zsingularity_key_hold_manager_v1 *manager;
	SingularityKeyHoldCallback callback;
	void *data;
	uint32_t delay_ms;
} hold;

static void
handle_hold_start(void *data, struct zsingularity_key_hold_manager_v1 *manager)
{
	(void)data;
	(void)manager;
	if (hold.callback) {
		hold.callback(1, 0, hold.data);
	}
}

static void
handle_hold_end(void *data, struct zsingularity_key_hold_manager_v1 *manager,
		uint32_t reason)
{
	(void)data;
	(void)manager;
	if (hold.callback) {
		hold.callback(0,
			reason == ZSINGULARITY_KEY_HOLD_MANAGER_V1_END_REASON_CANCELLED,
			hold.data);
	}
}

static const struct zsingularity_key_hold_manager_v1_listener manager_listener = {
	.hold_start = handle_hold_start,
	.hold_end = handle_hold_end,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	(void)data;
	(void)version;
	if (strcmp(interface, zsingularity_key_hold_manager_v1_interface.name) == 0
			&& !hold.manager) {
		hold.manager = wl_registry_bind(registry, name,
			&zsingularity_key_hold_manager_v1_interface, 1);
		zsingularity_key_hold_manager_v1_add_listener(hold.manager,
			&manager_listener, NULL);
		if (hold.delay_ms > 0) {
			zsingularity_key_hold_manager_v1_set_delay(hold.manager,
				hold.delay_ms);
		}
	}
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

int
singularity_key_hold_init(SingularityKeyHoldCallback callback, void *data)
{
	hold.callback = callback;
	hold.data = data;
	if (hold.registry) {
		return hold.manager != NULL;
	}
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gdk_display_get_default();
	if (!gdk_display || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return 0;
	}
	hold.display = gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display));
	hold.registry = wl_display_get_registry(hold.display);
	wl_registry_add_listener(hold.registry, &registry_listener, NULL);
	wl_display_roundtrip(hold.display);
	return hold.manager != NULL;
#else
	return 0;
#endif
}

int
singularity_key_hold_supported(void)
{
	return hold.manager != NULL;
}

void
singularity_key_hold_set_delay(uint32_t delay_ms)
{
	hold.delay_ms = delay_ms;
	if (hold.manager) {
		zsingularity_key_hold_manager_v1_set_delay(hold.manager, delay_ms);
		wl_display_flush(hold.display);
	}
}

void
singularity_key_hold_finish(void)
{
	if (hold.manager) {
		zsingularity_key_hold_manager_v1_finish(hold.manager);
		wl_display_flush(hold.display);
	}
}
