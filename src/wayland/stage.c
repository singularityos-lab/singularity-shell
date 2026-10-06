#include <string.h>
#include <wayland-client.h>

#include "stage.h"
#include "wayland_integration.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "singularity-stage-unstable-v1-client-protocol.h"

static struct zsingularity_stage_manager_v1 *manager;
static struct wl_display *bound_display;
static struct wl_event_queue *stage_queue;
static uint32_t bound_version;

struct group_reply {
	void *toplevel;
	uint32_t group;
	uint32_t hidden;
	gboolean received;
};

static struct group_reply pending_reply;

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct zsingularity_stage_manager_v1 **out = data;
	if (strcmp(interface, zsingularity_stage_manager_v1_interface.name) != 0)
		return;
	bound_version = version < 2 ? version : 2;
	*out = wl_registry_bind(registry, name,
		&zsingularity_stage_manager_v1_interface, bound_version);
}

static void
handle_group(void *data, struct zsingularity_stage_manager_v1 *mgr,
		struct zwlr_foreign_toplevel_handle_v1 *toplevel,
		uint32_t group, uint32_t hidden)
{
	(void)data;
	(void)mgr;
	if ((void *)toplevel != pending_reply.toplevel)
		return;
	pending_reply.group = group;
	pending_reply.hidden = hidden;
	pending_reply.received = TRUE;
}

static const struct zsingularity_stage_manager_v1_listener manager_listener = {
	.group = handle_group,
};

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

static struct zsingularity_stage_manager_v1 *
get_manager(void)
{
	struct wl_display *display = singularity_wayland_display();
	if (!display)
		return NULL;
	if (display == bound_display)
		return manager;
	struct zsingularity_stage_manager_v1 *found = NULL;
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue)
		return NULL;
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &found);
	wl_display_roundtrip_queue(display, queue);
	wl_registry_destroy(registry);
	if (found) {
		zsingularity_stage_manager_v1_add_listener(found,
			&manager_listener, NULL);
		stage_queue = queue;
	} else {
		wl_event_queue_destroy(queue);
	}
	bound_display = display;
	manager = found;
	return manager;
}

gboolean
singularity_stage_available(void)
{
	return get_manager() != NULL;
}

void
singularity_stage_set_hidden(void *toplevel, gboolean hidden,
		int x, int y, int width, int height)
{
	struct zsingularity_stage_manager_v1 *mgr = get_manager();
	if (!singularity_wayland_handle_is_valid(toplevel))
		return;
	if (!mgr) {
		if (hidden)
			zwlr_foreign_toplevel_handle_v1_minimize(toplevel);
		else
			zwlr_foreign_toplevel_handle_v1_unset_minimize(toplevel);
	} else {
		zsingularity_stage_manager_v1_set_hidden(mgr, toplevel,
			hidden ? 1 : 0, x, y, width, height);
	}
	wl_display_flush(bound_display ? bound_display : singularity_wayland_display());
}

gboolean
singularity_stage_groups_supported(void)
{
	return get_manager() != NULL && bound_version >= 2;
}

void
singularity_stage_set_group(void *toplevel, guint group)
{
	struct zsingularity_stage_manager_v1 *mgr = get_manager();
	if (!mgr || bound_version < 2 || !singularity_wayland_handle_is_valid(toplevel))
		return;
	zsingularity_stage_manager_v1_set_group(mgr, toplevel, group);
	wl_display_flush(bound_display);
}

gboolean
singularity_stage_get_group(void *toplevel, guint *group, gboolean *hidden)
{
	*group = 0;
	*hidden = FALSE;
	struct zsingularity_stage_manager_v1 *mgr = get_manager();
	if (!mgr || bound_version < 2 || !stage_queue
			|| !singularity_wayland_handle_is_valid(toplevel))
		return FALSE;
	pending_reply = (struct group_reply){ .toplevel = toplevel };
	zsingularity_stage_manager_v1_get_group(mgr, toplevel);
	if (wl_display_roundtrip_queue(bound_display, stage_queue) < 0
			|| !pending_reply.received)
		return FALSE;
	*group = pending_reply.group;
	*hidden = pending_reply.hidden != 0;
	return TRUE;
}
