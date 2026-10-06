#include <string.h>
#include <wayland-client.h>

#include "process_info.h"
#include "wayland_integration.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "singularity-process-unstable-v1-client-protocol.h"

static struct zsingularity_process_manager_v1 *manager;
static struct wl_display *bound_display;
static struct wl_event_queue *process_queue;

struct pid_reply {
	void *toplevel;
	int32_t pid;
	uint32_t source;
	gboolean received;
};

static struct pid_reply pending_reply;

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct zsingularity_process_manager_v1 **out = data;
	(void)version;
	if (strcmp(interface, zsingularity_process_manager_v1_interface.name) != 0)
		return;
	*out = wl_registry_bind(registry, name,
		&zsingularity_process_manager_v1_interface, 1);
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

static void
handle_pid(void *data, struct zsingularity_process_manager_v1 *mgr,
		struct zwlr_foreign_toplevel_handle_v1 *toplevel,
		int32_t pid, uint32_t source)
{
	(void)data;
	(void)mgr;
	if ((void *)toplevel != pending_reply.toplevel)
		return;
	pending_reply.pid = pid;
	pending_reply.source = source;
	pending_reply.received = TRUE;
}

static const struct zsingularity_process_manager_v1_listener manager_listener = {
	.pid = handle_pid,
};

static struct zsingularity_process_manager_v1 *
get_manager(void)
{
	struct wl_display *display = singularity_wayland_display();
	if (!display)
		return NULL;
	if (display == bound_display)
		return manager;
	struct zsingularity_process_manager_v1 *found = NULL;
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue)
		return NULL;
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &found);
	wl_display_roundtrip_queue(display, queue);
	wl_registry_destroy(registry);
	if (found) {
		zsingularity_process_manager_v1_add_listener(found,
			&manager_listener, NULL);
		process_queue = queue;
	} else {
		wl_event_queue_destroy(queue);
	}
	bound_display = display;
	manager = found;
	return manager;
}

gboolean
singularity_process_info_available(void)
{
	return get_manager() != NULL;
}

gboolean
singularity_process_info_get_pid(void *toplevel, int *pid, guint *source)
{
	*pid = 0;
	*source = 0;
	struct zsingularity_process_manager_v1 *mgr = get_manager();
	if (!mgr || !process_queue || !singularity_wayland_handle_is_valid(toplevel))
		return FALSE;
	pending_reply = (struct pid_reply){ .toplevel = toplevel };
	zsingularity_process_manager_v1_get_pid(mgr, toplevel);
	if (wl_display_roundtrip_queue(bound_display, process_queue) < 0
			|| !pending_reply.received || pending_reply.pid <= 0)
		return FALSE;
	*pid = pending_reply.pid;
	*source = pending_reply.source;
	return TRUE;
}
