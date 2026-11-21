#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include "window_card.h"
#include "wayland_integration.h"
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "singularity-motion-unstable-v1-client-protocol.h"

struct window_card {
	struct zsingularity_motion_card_v1 *proxy;
	SingularityMotionCardDone done;
	gpointer user_data;
	GDestroyNotify notify;
	gboolean finished;
};

static struct zsingularity_motion_manager_v1 *manager;
static struct wl_display *bound_display;

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct zsingularity_motion_manager_v1 **out = data;
	if (strcmp(interface, zsingularity_motion_manager_v1_interface.name) != 0
			|| version < 2)
		return;
	*out = wl_registry_bind(registry, name,
		&zsingularity_motion_manager_v1_interface, 2);
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
get_manager(void)
{
	struct wl_display *display = singularity_wayland_display();
	if (!display)
		return NULL;
	if (display == bound_display)
		return manager;
	struct zsingularity_motion_manager_v1 *found = NULL;
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue)
		return NULL;
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &found);
	wl_display_roundtrip_queue(display, queue);
	wl_registry_destroy(registry);
	if (found)
		wl_proxy_set_queue((struct wl_proxy *)found, NULL);
	wl_event_queue_destroy(queue);
	bound_display = display;
	manager = found;
	return manager;
}

static void
handle_done(void *data, struct zsingularity_motion_card_v1 *proxy)
{
	(void)proxy;
	struct window_card *card = data;
	if (card->finished)
		return;
	card->finished = TRUE;
	if (card->done)
		card->done(card->user_data);
}

static const struct zsingularity_motion_card_v1_listener card_listener = {
	.done = handle_done,
};

gboolean
singularity_motion_card_available(void)
{
	return get_manager() != NULL;
}

gpointer
singularity_motion_card_new(gpointer toplevel, SingularityMotionCardDone done,
		gpointer user_data, GDestroyNotify notify)
{
	struct zsingularity_motion_manager_v1 *mgr = get_manager();
	if (!mgr || !singularity_wayland_handle_is_valid(toplevel)) {
		if (notify)
			notify(user_data);
		return NULL;
	}
	struct window_card *card = calloc(1, sizeof(*card));
	if (!card) {
		if (notify)
			notify(user_data);
		return NULL;
	}
	card->done = done;
	card->user_data = user_data;
	card->notify = notify;
	card->proxy = zsingularity_motion_manager_v1_get_card(mgr, toplevel);
	zsingularity_motion_card_v1_add_listener(card->proxy, &card_listener, card);
	wl_display_flush(bound_display);
	return card;
}

void
singularity_motion_card_set_rect(gpointer data, int x, int y, int width,
		int height, int radius)
{
	struct window_card *card = data;
	if (!card || card->finished)
		return;
	zsingularity_motion_card_v1_set_rect(card->proxy, x, y, width, height,
		radius);
	wl_display_flush(bound_display);
}

void
singularity_motion_card_release(gpointer data, gboolean minimize, int x, int y,
		int width, int height, int radius, int velocity_x, int velocity_y)
{
	struct window_card *card = data;
	if (!card || card->finished)
		return;
	zsingularity_motion_card_v1_release(card->proxy,
		minimize ? ZSINGULARITY_MOTION_CARD_V1_RELEASE_ACTION_MINIMIZE
			: ZSINGULARITY_MOTION_CARD_V1_RELEASE_ACTION_SHOW,
		x, y, width, height, radius, velocity_x, velocity_y);
	wl_display_flush(bound_display);
}

void
singularity_motion_card_free(gpointer data)
{
	struct window_card *card = data;
	if (!card)
		return;
	zsingularity_motion_card_v1_destroy(card->proxy);
	wl_display_flush(bound_display);
	if (card->notify)
		card->notify(card->user_data);
	free(card);
}
