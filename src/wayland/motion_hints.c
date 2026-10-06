#define _POSIX_C_SOURCE 200809L

#include <gtk/gtk.h>
#include <string.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "motion_hints.h"
#include "singularity-motion-unstable-v1-client-protocol.h"

#ifdef GDK_WINDOWING_WAYLAND

static struct zsingularity_motion_manager_v1 *cached_manager;
static struct wl_display *cached_display;

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct zsingularity_motion_manager_v1 **manager = data;
	if (strcmp(interface, zsingularity_motion_manager_v1_interface.name) != 0) {
		return;
	}
	*manager = wl_registry_bind(registry, name,
		&zsingularity_motion_manager_v1_interface, 1);
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

static struct zsingularity_motion_manager_v1 *
get_manager(struct wl_display *display)
{
	if (display == cached_display) {
		return cached_manager;
	}
	struct zsingularity_motion_manager_v1 *manager = NULL;
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue) {
		return NULL;
	}
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &manager);
	wl_display_roundtrip_queue(display, queue);
	if (manager) {
		wl_proxy_set_queue((struct wl_proxy *)manager, NULL);
	}
	wl_registry_destroy(registry);
	wl_event_queue_destroy(queue);
	cached_display = display;
	cached_manager = manager;
	return cached_manager;
}

static gboolean
resolve(GtkWidget *window, struct zsingularity_motion_manager_v1 **manager,
		struct wl_surface **surface)
{
	GdkDisplay *gdk_display = gtk_widget_get_display(window);
	if (!GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return FALSE;
	}
	*manager = get_manager(gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display)));
	if (!*manager) {
		return FALSE;
	}
	if (!surface) {
		return TRUE;
	}
	GtkNative *native = gtk_widget_get_native(window);
	GdkSurface *gdk_surface = native ? gtk_native_get_surface(native) : NULL;
	if (!gdk_surface || !GDK_IS_WAYLAND_SURFACE(gdk_surface)) {
		return FALSE;
	}
	*surface = gdk_wayland_surface_get_wl_surface(GDK_WAYLAND_SURFACE(gdk_surface));
	return *surface != NULL;
}

#endif

void
singularity_motion_hints_set_icon_rect(GtkWidget *window, const char *app_id,
		int x, int y, int width, int height)
{
#ifdef GDK_WINDOWING_WAYLAND
	struct zsingularity_motion_manager_v1 *manager;
	struct wl_surface *surface;
	if (!app_id || !resolve(window, &manager, &surface)) {
		return;
	}
	zsingularity_motion_manager_v1_set_icon_rect(manager, surface, app_id,
		x, y, width, height);
#else
	(void)window;
	(void)app_id;
	(void)x;
	(void)y;
	(void)width;
	(void)height;
#endif
}

void
singularity_motion_hints_clear(GtkWidget *window)
{
#ifdef GDK_WINDOWING_WAYLAND
	struct zsingularity_motion_manager_v1 *manager;
	struct wl_surface *surface;
	if (!resolve(window, &manager, &surface)) {
		return;
	}
	zsingularity_motion_manager_v1_clear_icon_rects(manager, surface);
#else
	(void)window;
#endif
}

void
singularity_motion_hints_launch(GtkWidget *window, const char *app_id)
{
#ifdef GDK_WINDOWING_WAYLAND
	struct zsingularity_motion_manager_v1 *manager;
	if (!app_id || !resolve(window, &manager, NULL)) {
		return;
	}
	zsingularity_motion_manager_v1_launch(manager, app_id);
	GdkDisplay *gdk_display = gtk_widget_get_display(window);
	wl_display_flush(gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display)));
#else
	(void)window;
	(void)app_id;
#endif
}

gboolean
singularity_motion_hints_available(GtkWidget *window)
{
#ifdef GDK_WINDOWING_WAYLAND
	struct zsingularity_motion_manager_v1 *manager;
	return resolve(window, &manager, NULL);
#else
	(void)window;
	return FALSE;
#endif
}
