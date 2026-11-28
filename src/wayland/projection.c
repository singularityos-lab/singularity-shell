#include <string.h>
#include <wayland-client.h>

#include "projection.h"
#include "wayland_integration.h"
#include "singularity-projection-unstable-v1-client-protocol.h"

static struct zsingularity_projection_manager_v1 *manager;
static struct wl_display *bound_display;
static struct wl_event_queue *projection_queue;

struct reply {
	gboolean done;
	gboolean ok;
	char *name;
	int width;
	int height;
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct zsingularity_projection_manager_v1 **out = data;
	if (strcmp(interface, zsingularity_projection_manager_v1_interface.name) != 0)
		return;
	*out = wl_registry_bind(registry, name,
		&zsingularity_projection_manager_v1_interface, 1);
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

static struct zsingularity_projection_manager_v1 *
get_manager(void)
{
	struct wl_display *display = singularity_wayland_display();
	if (!display)
		return NULL;
	if (display == bound_display)
		return manager;
	struct zsingularity_projection_manager_v1 *found = NULL;
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue)
		return NULL;
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &found);
	wl_display_roundtrip_queue(display, queue);
	wl_registry_destroy(registry);
	if (found)
		projection_queue = queue;
	else
		wl_event_queue_destroy(queue);
	bound_display = display;
	manager = found;
	return manager;
}

static void
handle_ready(void *data, struct zsingularity_projection_output_v1 *output,
		const char *name, int32_t width, int32_t height)
{
	(void)output;
	struct reply *reply = data;
	if (!reply)
		return;
	g_free(reply->name);
	reply->name = g_strdup(name);
	reply->width = width;
	reply->height = height;
	reply->ok = TRUE;
	reply->done = TRUE;
}

static void
handle_failed(void *data, struct zsingularity_projection_output_v1 *output, uint32_t reason)
{
	(void)output;
	(void)reason;
	struct reply *reply = data;
	if (!reply)
		return;
	reply->ok = FALSE;
	reply->done = TRUE;
}

static const struct zsingularity_projection_output_v1_listener output_listener = {
	.ready = handle_ready,
	.failed = handle_failed,
};

gboolean
singularity_projection_available(void)
{
	return get_manager() != NULL;
}

static gboolean
wait_reply(struct zsingularity_projection_output_v1 *output, struct reply *reply)
{
	wl_proxy_set_user_data((struct wl_proxy *)output, reply);
	wl_display_roundtrip_queue(bound_display, projection_queue);
	wl_proxy_set_user_data((struct wl_proxy *)output, NULL);
	return reply->done && reply->ok;
}

void *
singularity_projection_create(const char *name, int width, int height,
		int refresh, const char *form_factor, char **output_name, int *out_width, int *out_height)
{
	*output_name = NULL;
	*out_width = 0;
	*out_height = 0;
	struct zsingularity_projection_manager_v1 *mgr = get_manager();
	if (!mgr)
		return NULL;
	struct zsingularity_projection_output_v1 *output =
		zsingularity_projection_manager_v1_create_output(mgr, name, width, height, refresh, form_factor);
	struct reply reply = { 0 };
	zsingularity_projection_output_v1_add_listener(output, &output_listener, NULL);
	if (!wait_reply(output, &reply)) {
		g_free(reply.name);
		zsingularity_projection_output_v1_destroy(output);
		wl_display_flush(bound_display);
		return NULL;
	}
	*output_name = reply.name;
	*out_width = reply.width;
	*out_height = reply.height;
	return output;
}

void
singularity_projection_map_touch(void *projection, const char *device_name)
{
	if (!projection || !bound_display)
		return;
	zsingularity_projection_output_v1_map_touch(projection, device_name);
	wl_display_flush(bound_display);
}

gboolean
singularity_projection_set_mode(void *projection, int width, int height, int refresh)
{
	if (!projection || !bound_display)
		return FALSE;
	struct reply reply = { 0 };
	zsingularity_projection_output_v1_set_mode(projection, width, height, refresh);
	gboolean ok = wait_reply(projection, &reply);
	g_free(reply.name);
	return ok;
}

void
singularity_projection_destroy(void *projection)
{
	if (!projection || !bound_display)
		return;
	zsingularity_projection_output_v1_destroy(projection);
	wl_display_flush(bound_display);
}
