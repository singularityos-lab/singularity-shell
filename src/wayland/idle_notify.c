#define _POSIX_C_SOURCE 200809L

#include <stdlib.h>
#include <string.h>
#include <gtk/gtk.h>
#include <wayland-client.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "ext-idle-notify-v1-client-protocol.h"
#include "wlr-output-power-management-unstable-v1-client-protocol.h"
#include "idle_notify.h"

struct idle_watch {
	int id;
	struct ext_idle_notification_v1 *notification;
	SingularityIdleCallback callback;
	void *data;
	struct idle_watch *next;
};

struct power_output {
	uint32_t name;
	struct wl_output *output;
	struct zwlr_output_power_v1 *power;
	struct power_output *next;
};

static struct {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_seat *seat;
	struct ext_idle_notifier_v1 *notifier;
	uint32_t notifier_version;
	struct zwlr_output_power_manager_v1 *power_manager;
	struct idle_watch *watches;
	struct power_output *outputs;
	int want_on;
} idle;

static void
notification_idled(void *data, struct ext_idle_notification_v1 *notification)
{
	struct idle_watch *watch = data;
	(void)notification;
	if (watch->callback) {
		watch->callback(watch->id, 1, watch->data);
	}
}

static void
notification_resumed(void *data, struct ext_idle_notification_v1 *notification)
{
	struct idle_watch *watch = data;
	(void)notification;
	if (watch->callback) {
		watch->callback(watch->id, 0, watch->data);
	}
}

static const struct ext_idle_notification_v1_listener notification_listener = {
	.idled = notification_idled,
	.resumed = notification_resumed,
};

static void
power_mode(void *data, struct zwlr_output_power_v1 *power, uint32_t mode)
{
	(void)data;
	(void)power;
	(void)mode;
}

static void
power_failed(void *data, struct zwlr_output_power_v1 *power)
{
	struct power_output *output = data;
	zwlr_output_power_v1_destroy(power);
	output->power = NULL;
}

static const struct zwlr_output_power_v1_listener power_listener = {
	.mode = power_mode,
	.failed = power_failed,
};

static void
output_apply(struct power_output *output)
{
	if (!idle.power_manager || !output->output) {
		return;
	}
	if (!output->power) {
		output->power = zwlr_output_power_manager_v1_get_output_power(
			idle.power_manager, output->output);
		zwlr_output_power_v1_add_listener(output->power, &power_listener, output);
	}
	zwlr_output_power_v1_set_mode(output->power,
		idle.want_on ? ZWLR_OUTPUT_POWER_V1_MODE_ON : ZWLR_OUTPUT_POWER_V1_MODE_OFF);
}

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	(void)data;
	if (strcmp(interface, ext_idle_notifier_v1_interface.name) == 0) {
		idle.notifier_version = version < 2 ? version : 2;
		idle.notifier = wl_registry_bind(registry, name,
			&ext_idle_notifier_v1_interface, idle.notifier_version);
	} else if (strcmp(interface, wl_seat_interface.name) == 0 && !idle.seat) {
		idle.seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
	} else if (strcmp(interface, zwlr_output_power_manager_v1_interface.name) == 0) {
		idle.power_manager = wl_registry_bind(registry, name,
			&zwlr_output_power_manager_v1_interface, 1);
	} else if (strcmp(interface, wl_output_interface.name) == 0) {
		struct power_output *output = calloc(1, sizeof(*output));
		if (!output) {
			return;
		}
		output->name = name;
		output->output = wl_registry_bind(registry, name, &wl_output_interface, 1);
		output->next = idle.outputs;
		idle.outputs = output;
	}
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void)data;
	(void)registry;
	struct power_output **link = &idle.outputs;
	while (*link) {
		struct power_output *output = *link;
		if (output->name == name) {
			*link = output->next;
			if (output->power) {
				zwlr_output_power_v1_destroy(output->power);
			}
			wl_output_destroy(output->output);
			free(output);
			return;
		}
		link = &output->next;
	}
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

int
singularity_idle_init(void)
{
#ifdef GDK_WINDOWING_WAYLAND
	if (idle.registry) {
		return idle.notifier != NULL && idle.seat != NULL;
	}
	GdkDisplay *gdk_display = gdk_display_get_default();
	if (!gdk_display || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return 0;
	}
	idle.display = gdk_wayland_display_get_wl_display(GDK_WAYLAND_DISPLAY(gdk_display));
	idle.want_on = 1;
	idle.registry = wl_display_get_registry(idle.display);
	wl_registry_add_listener(idle.registry, &registry_listener, NULL);
	wl_display_roundtrip(idle.display);
	return idle.notifier != NULL && idle.seat != NULL;
#else
	return 0;
#endif
}

int
singularity_idle_input_only_supported(void)
{
	return idle.notifier_version >= 2;
}

int
singularity_output_power_supported(void)
{
	return idle.power_manager != NULL;
}

void
singularity_idle_watch(int id, uint32_t timeout_ms, int input_only,
		SingularityIdleCallback callback, void *data)
{
	singularity_idle_unwatch(id);
	if (!idle.notifier || !idle.seat) {
		return;
	}
	struct idle_watch *watch = calloc(1, sizeof(*watch));
	if (!watch) {
		return;
	}
	watch->id = id;
	watch->callback = callback;
	watch->data = data;
	if (input_only && idle.notifier_version >= 2) {
		watch->notification = ext_idle_notifier_v1_get_input_idle_notification(
			idle.notifier, timeout_ms, idle.seat);
	} else {
		watch->notification = ext_idle_notifier_v1_get_idle_notification(
			idle.notifier, timeout_ms, idle.seat);
	}
	ext_idle_notification_v1_add_listener(watch->notification, &notification_listener, watch);
	watch->next = idle.watches;
	idle.watches = watch;
	wl_display_flush(idle.display);
}

void
singularity_idle_unwatch(int id)
{
	struct idle_watch **link = &idle.watches;
	while (*link) {
		struct idle_watch *watch = *link;
		if (watch->id == id) {
			*link = watch->next;
			ext_idle_notification_v1_destroy(watch->notification);
			free(watch);
			if (idle.display) {
				wl_display_flush(idle.display);
			}
			return;
		}
		link = &watch->next;
	}
}

void
singularity_output_power_set(int on)
{
	idle.want_on = on;
	for (struct power_output *output = idle.outputs; output; output = output->next) {
		output_apply(output);
	}
	if (idle.display) {
		wl_display_flush(idle.display);
	}
}
