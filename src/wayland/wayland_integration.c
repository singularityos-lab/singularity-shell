#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <execinfo.h>
#include <wayland-client.h>
#include <glib.h>
#include "wayland_integration.h"
#include <gtk/gtk.h>
#include <gdk/wayland/gdkwayland.h>

static void crash_handler(int sig) {
    void *array[64];
    int size = backtrace(array, 64);
    fprintf(stderr, "\n=== CRASH: signal %d ===\n", sig);
    backtrace_symbols_fd(array, size, STDERR_FILENO);
    fprintf(stderr, "=== END CRASH ===\n");
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor))
static void install_crash_handler(void) {
    signal(SIGSEGV, crash_handler);
    signal(SIGABRT, crash_handler);
    signal(SIGBUS, crash_handler);
}
#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
#include "ext-workspace-v1-client-protocol.h"
#include "singularity-preview-unstable-v1-client-protocol.h"
#include "singularity-pip-unstable-v1-client-protocol.h"
#include "wlr-output-management-unstable-v1-client-protocol.h"
#include "singularity-tiling-unstable-v1-client-protocol.h"
#include "singularity-gesture-unstable-v1-client-protocol.h"
#include "wlr-gamma-control-unstable-v1-client-protocol.h"
void singularity_display_manager_add_head(void *head_handle);
void singularity_display_manager_update_head(void *head_handle, const char *name, const char *description, int phys_w, int phys_h, int x, int y, int transform, double scale, int enabled);
void singularity_display_manager_update_head_info(void *head_handle, const char *make, const char *model, const char *serial);
void singularity_display_manager_add_mode(void *head_handle, int width, int height, int refresh, int preferred);
void singularity_display_manager_set_current_mode(void *head_handle, int width, int height, int refresh);
void singularity_display_manager_remove_head(void *head_handle);
void singularity_display_manager_set_serial(uint32_t serial);
struct SingularityWaylandContext {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct wl_shm *shm;
    struct zwlr_foreign_toplevel_manager_v1 *toplevel_manager;
    struct ext_workspace_manager_v1 *workspace_manager;
    struct ext_workspace_group_handle_v1 *workspace_group;
    struct zsingularity_preview_manager_v1 *preview_manager;
    struct zsingularity_pip_manager_v1 *pip_manager;
    struct zwlr_output_manager_v1 *output_manager;
    struct zsingularity_tiling_manager_v1 *tiling_manager;
    struct zsingularity_gesture_manager_v1 *gesture_manager;
    struct zwlr_gamma_control_manager_v1 *gamma_manager;
    /* Set of zwlr_foreign_toplevel_handle_v1* that are currently alive.
     * Handles are added on toplevel creation and removed before the closed
     * callback fires so that snap_view is never called on a dead resource. */
    GHashTable *valid_handles;
    AppOpenedCallback opened_cb;
    AppClosedCallback closed_cb;
    AppFocusedCallback focused_cb;
    AppTitleChangedCallback title_cb;
    AppStateChangedCallback state_cb;
    WorkspaceCreatedCallback ws_created_cb;
    WorkspaceDestroyedCallback ws_destroyed_cb;
    WorkspaceStateCallback ws_state_cb;
    void *user_data;
};
static struct SingularityWaylandContext ctx;
static GHashTable *toplevel_output_map = NULL;
static GHashTable *geometry_map = NULL;
static struct {
    int x, y, w, h;
    int got;
    int done;
} layout_workarea;
static struct {
    int x, y, w, h;
} layout_output_workareas[32];
static int layout_output_workarea_count;
static void invalidate_toplevel_tileable(void *handle);
/* Maps wl_output* (our binding), connector name (heap string, owned) */
static GHashTable *output_connector_map = NULL;
static GHashTable *workspace_group_map = NULL;
static GHashTable *group_outputs_map = NULL;
/* Optional callback fired when a toplevel changes its output */
static WindowOutputChangedCallback window_output_changed_cb = NULL;
static void *window_output_changed_user_data = NULL;
static DesktopGestureCallback desktop_gesture_cb = NULL;
static void *desktop_gesture_user_data = NULL;
static TilingInteractionCallback tiling_interaction_cb = NULL;
static void *tiling_interaction_user_data = NULL;
static CursorPositionCallback cursor_position_cb = NULL;
static void *cursor_position_user_data = NULL;
static uint32_t desktop_gesture_fingers = 0;
static uint32_t desktop_gesture_direction = 0;
static int wayland_debug_enabled = -1;
static bool wl_debug(void) {
    if (wayland_debug_enabled < 0)
        wayland_debug_enabled = g_strcmp0(g_getenv("SINGULARITY_WAYLAND_DEBUG"), "1") == 0;
    return wayland_debug_enabled != 0;
}
struct ModeEntry {
    struct zwlr_output_mode_v1 *mode;
    int32_t width, height, refresh;
    struct ModeEntry *next;
};
struct HeadData {
    struct zwlr_output_head_v1 *head;
    char *name;
    char *description;
    char *make;
    char *model;
    char *serial_number;
    int phys_width, phys_height;
    int x, y;
    int transform;
    double scale;
    int enabled;
    int adaptive_sync_state; /* 0=disabled, 1=enabled, -1=unknown */
    struct ModeEntry *modes;
    struct zwlr_output_mode_v1 *current_mode_ptr;
};
struct HeadNode {
    struct HeadData *data;
    struct HeadNode *next;
};
static struct HeadNode *heads_list = NULL;
static void add_head_to_list(struct HeadData *hd) {
    struct HeadNode *node = calloc(1, sizeof(*node));
    node->data = hd;
    node->next = heads_list;
    heads_list = node;
}
static void remove_head_from_list(struct HeadData *hd) {
    struct HeadNode **curr = &heads_list;
    while (*curr) {
        if ((*curr)->data == hd) {
            struct HeadNode *tmp = *curr;
            *curr = (*curr)->next;
            free(tmp);
            return;
        }
        curr = &(*curr)->next;
    }
}
static void head_handle_name(void *data, struct zwlr_output_head_v1 *head, const char *name) {
    struct HeadData *hd = data;
    if (hd->name) free(hd->name);
    hd->name = strdup(name);
}
static void head_handle_description(void *data, struct zwlr_output_head_v1 *head, const char *description) {
    struct HeadData *hd = data;
    if (hd->description) free(hd->description);
    hd->description = strdup(description);
}
static void head_handle_physical_size(void *data, struct zwlr_output_head_v1 *head, int32_t width, int32_t height) {
    struct HeadData *hd = data;
    hd->phys_width = width;
    hd->phys_height = height;
}
static void head_handle_mode(void *data, struct zwlr_output_head_v1 *head, struct zwlr_output_mode_v1 *mode);
static void head_handle_enabled(void *data, struct zwlr_output_head_v1 *head, int32_t enabled) {
    struct HeadData *hd = data;
    hd->enabled = enabled;
}
static void head_handle_current_mode(void *data, struct zwlr_output_head_v1 *head, struct zwlr_output_mode_v1 *mode);
static void head_handle_position(void *data, struct zwlr_output_head_v1 *head, int32_t x, int32_t y) {
    struct HeadData *hd = data;
    hd->x = x;
    hd->y = y;
}
static void head_handle_transform(void *data, struct zwlr_output_head_v1 *head, int32_t transform) {
    struct HeadData *hd = data;
    hd->transform = transform;
}
static void head_handle_scale(void *data, struct zwlr_output_head_v1 *head, wl_fixed_t scale) {
    struct HeadData *hd = data;
    hd->scale = wl_fixed_to_double(scale);
}
static void head_handle_finished(void *data, struct zwlr_output_head_v1 *head) {
    struct HeadData *hd = data;
    singularity_display_manager_remove_head(head);
    remove_head_from_list(hd);
    struct ModeEntry *current = hd->modes;
    while (current) {
        struct ModeEntry *next = current->next;
        zwlr_output_mode_v1_destroy(current->mode);
        free(current);
        current = next;
    }
    zwlr_output_head_v1_destroy(head);
    if (hd->name) free(hd->name);
    if (hd->description) free(hd->description);
    if (hd->make) free(hd->make);
    if (hd->model) free(hd->model);
    if (hd->serial_number) free(hd->serial_number);
    free(hd);
}
static void head_handle_make(void *data, struct zwlr_output_head_v1 *head, const char *make) {
    struct HeadData *hd = data;
    if (hd->make) free(hd->make);
    hd->make = strdup(make);
}
static void head_handle_model(void *data, struct zwlr_output_head_v1 *head, const char *model) {
    struct HeadData *hd = data;
    if (hd->model) free(hd->model);
    hd->model = strdup(model);
}
static void head_handle_serial_number(void *data, struct zwlr_output_head_v1 *head, const char *serial_number) {
    struct HeadData *hd = data;
    if (hd->serial_number) free(hd->serial_number);
    hd->serial_number = strdup(serial_number);
}
static void head_handle_adaptive_sync(void *data, struct zwlr_output_head_v1 *head, uint32_t state) {
    struct HeadData *hd = data;
    hd->adaptive_sync_state = (int)state;
    singularity_display_manager_update_adaptive_sync(hd, state);
}
static const struct zwlr_output_head_v1_listener head_listener = {
    .name = head_handle_name,
    .description = head_handle_description,
    .physical_size = head_handle_physical_size,
    .mode = head_handle_mode,
    .enabled = head_handle_enabled,
    .current_mode = head_handle_current_mode,
    .position = head_handle_position,
    .transform = head_handle_transform,
    .scale = head_handle_scale,
    .finished = head_handle_finished,
    .make = head_handle_make,
    .model = head_handle_model,
    .serial_number = head_handle_serial_number,
    .adaptive_sync = head_handle_adaptive_sync,
};
struct ModeData {
    struct zwlr_output_mode_v1 *mode;
    struct zwlr_output_head_v1 *head;
    struct HeadData *head_data;
    int width, height, refresh;
    int preferred;
};
static void mode_handle_size(void *data, struct zwlr_output_mode_v1 *mode, int32_t width, int32_t height) {
    struct ModeData *md = data;
    md->width = width;
    md->height = height;
    struct ModeEntry *entry = md->head_data->modes;
    while (entry) {
        if (entry->mode == mode) {
            entry->width = width;
            entry->height = height;
            break;
        }
        entry = entry->next;
    }
}
static void mode_handle_refresh(void *data, struct zwlr_output_mode_v1 *mode, int32_t refresh) {
    struct ModeData *md = data;
    md->refresh = refresh;
    struct ModeEntry *entry = md->head_data->modes;
    while (entry) {
        if (entry->mode == mode) {
            entry->refresh = refresh;
            break;
        }
        entry = entry->next;
    }
}
static void mode_handle_preferred(void *data, struct zwlr_output_mode_v1 *mode) {
    struct ModeData *md = data;
    md->preferred = 1;
}
static void mode_handle_finished(void *data, struct zwlr_output_mode_v1 *mode) {
    struct ModeData *md = data;
    free(md);
}
static const struct zwlr_output_mode_v1_listener mode_listener = {
    .size = mode_handle_size,
    .refresh = mode_handle_refresh,
    .preferred = mode_handle_preferred,
    .finished = mode_handle_finished,
};
static void head_handle_mode(void *data, struct zwlr_output_head_v1 *head, struct zwlr_output_mode_v1 *mode) {
    struct HeadData *hd = data;
    struct ModeData *md = calloc(1, sizeof(*md));
    md->mode = mode;
    md->head = head;
    md->head_data = hd;
    struct ModeEntry *entry = calloc(1, sizeof(*entry));
    entry->mode = mode;
    entry->next = hd->modes;
    hd->modes = entry;
    zwlr_output_mode_v1_add_listener(mode, &mode_listener, md);
}
static void head_handle_current_mode(void *data, struct zwlr_output_head_v1 *head, struct zwlr_output_mode_v1 *mode) {
    struct HeadData *hd = data;
    hd->current_mode_ptr = mode;
}
static void output_manager_head(void *data, struct zwlr_output_manager_v1 *manager, struct zwlr_output_head_v1 *head) {
    struct HeadData *hd = calloc(1, sizeof(*hd));
    hd->head = head;
    zwlr_output_head_v1_add_listener(head, &head_listener, hd);
    add_head_to_list(hd);
    singularity_display_manager_add_head(head);
}
static void output_manager_done(void *data, struct zwlr_output_manager_v1 *manager, uint32_t serial) {
    singularity_display_manager_set_serial(serial);
    struct HeadNode *curr = heads_list;
    while (curr) {
        struct HeadData *hd = curr->data;
        singularity_display_manager_update_head(
            hd->head,
            hd->name,
            hd->description,
            hd->phys_width,
            hd->phys_height,
            hd->x,
            hd->y,
            hd->transform,
            hd->scale,
            hd->enabled
        );
        singularity_display_manager_update_head_info(
            hd->head,
            hd->make,
            hd->model,
            hd->serial_number
        );
        struct ModeEntry *me = hd->modes;
        while (me) {
            int preferred = (hd->current_mode_ptr != NULL && me->mode == hd->current_mode_ptr) ? 1 : 0;
            singularity_display_manager_add_mode(
                hd->head,
                me->width,
                me->height,
                me->refresh,
                preferred
            );
            if (preferred) {
                singularity_display_manager_set_current_mode(
                    hd->head,
                    me->width,
                    me->height,
                    me->refresh
                );
            }
            me = me->next;
        }
        curr = curr->next;
    }
}
static void output_manager_finished(void *data, struct zwlr_output_manager_v1 *manager) {
    zwlr_output_manager_v1_destroy(manager);
    ctx.output_manager = NULL;
}
static const struct zwlr_output_manager_v1_listener output_manager_listener = {
    .head = output_manager_head,
    .done = output_manager_done,
    .finished = output_manager_finished,
};
static void randname(char *buf) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long r = ts.tv_nsec;
    for (int i = 0; i < 6; ++i) {
        buf[i] = 'A'+(r&15)+(r&16)*2;
        r >>= 5;
    }
}
static int create_shm_file(off_t size) {
    char name[] = "/wl_shm-XXXXXX";
    int retries = 100;
    do {
        randname(name + strlen(name) - 6);
        --retries;
        #ifdef __NR_memfd_create
        int fd = syscall(__NR_memfd_create, "wl_shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
        if (fd >= 0) {
            ftruncate(fd, size);
            return fd;
        }
        #endif
        int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd >= 0) {
            shm_unlink(name);
            ftruncate(fd, size);
            return fd;
        }
    } while (retries > 0 && errno == EEXIST);
    return -1;
}
static int allocate_shm_file(size_t size) {
    int fd = create_shm_file(size);
    if (fd < 0) return -1;
    int ret;
    do {
        ret = ftruncate(fd, size);
    } while (ret < 0 && errno == EINTR);
    if (ret < 0) {
        close(fd);
        return -1;
    }
    return fd;
}
/*
 * Bounded, reusable pool of preview SHM buffers.
 *
 * Previously every capture allocated a fresh full-size SHM pool. With the
 * 640x360 downscale removed each is window-sized (~8.6MB), and labwc retains
 * its mapping for the lifetime of the wl_buffer object - so re-capturing the
 * same windows on every overview open accumulated to GBs in the compositor
 * (measured: 598 buffers / 3.3GB, growing, never shrinking).
 *
 * The fix is structural: keep a small set of wl_buffer objects keyed by exact
 * geometry and recycle them. The client never creates more than POOL_MAX
 * distinct buffers, so labwc can never map more than that. Re-capturing the
 * same window reuses its buffer (one mapping, not 199). A burst larger than
 * the pool falls back to one-shot transient buffers (freed on completion).
 * Sized to comfortably cover the windows captured in one overview open;
 * preview_pool_trim() (called when the overview closes) frees the idle
 * buffers so nothing lingers between sessions.
 */
#define PREVIEW_POOL_MAX 24
struct PreviewBuffer {
    struct wl_buffer *buffer;
    void *data;
    size_t size;
    int width, height, stride;
    uint32_t format;
    bool in_use;
};
static struct PreviewBuffer preview_pool[PREVIEW_POOL_MAX];

/* Find a free buffer matching the geometry (reuse), or (re)allocate a free
 * slot, or return NULL when every slot is busy (caller uses a transient). */
static struct PreviewBuffer *preview_buffer_acquire(uint32_t format,
        int width, int height, int stride) {
    size_t size = (size_t)stride * height;
    for (int i = 0; i < PREVIEW_POOL_MAX; i++) {
        struct PreviewBuffer *pb = &preview_pool[i];
        if (!pb->in_use && pb->buffer && pb->format == format &&
                pb->width == width && pb->height == height && pb->stride == stride) {
            pb->in_use = true;
            return pb;
        }
    }
    for (int i = 0; i < PREVIEW_POOL_MAX; i++) {
        struct PreviewBuffer *pb = &preview_pool[i];
        if (pb->in_use) continue;
        if (pb->buffer) { /* geometry changed: tear the old one down */
            wl_buffer_destroy(pb->buffer);
            if (pb->data && pb->data != MAP_FAILED) munmap(pb->data, pb->size);
            pb->buffer = NULL; pb->data = NULL; pb->size = 0;
        }
        int fd = allocate_shm_file(size);
        if (fd < 0) return NULL;
        void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (map == MAP_FAILED) { close(fd); return NULL; }
        struct wl_shm_pool *pool = wl_shm_create_pool(ctx.shm, fd, size);
        close(fd);
        if (!pool) { munmap(map, size); return NULL; }
        struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, width, height, stride, format);
        wl_shm_pool_destroy(pool);
        if (!buf) { munmap(map, size); return NULL; }
        pb->buffer = buf; pb->data = map; pb->size = size;
        pb->width = width; pb->height = height; pb->stride = stride;
        pb->format = format; pb->in_use = true;
        return pb;
    }
    return NULL;
}

static void preview_buffer_release(struct PreviewBuffer *pb) {
    if (pb) pb->in_use = false; /* keep the mapping for reuse */
}

/* Free every idle pool buffer (and the labwc-side mapping with it). Called
 * when the overview closes - buffers in_use by an in-flight capture are left
 * alone and recycled normally on completion. */
void singularity_wayland_preview_pool_trim(void) {
    for (int i = 0; i < PREVIEW_POOL_MAX; i++) {
        struct PreviewBuffer *pb = &preview_pool[i];
        if (pb->in_use || !pb->buffer) continue;
        wl_buffer_destroy(pb->buffer);
        if (pb->data && pb->data != MAP_FAILED) munmap(pb->data, pb->size);
        pb->buffer = NULL; pb->data = NULL; pb->size = 0;
        pb->width = pb->height = pb->stride = 0; pb->format = 0;
    }
    if (ctx.display) wl_display_flush(ctx.display);
}

struct PreviewRequest {
    struct zsingularity_preview_frame_v1 *frame;
    struct wl_buffer *buffer;
    struct PreviewBuffer *pb; /* non-NULL when the buffer came from the pool */
    void *data;
    size_t size;
    int width, height, stride;
    PreviewCallback callback;
    void *user_data;
    GDestroyNotify destroy;
    bool cancelled;
    bool external; /* true when token returned to Vala - req freed by cancel_capture only */
    bool done;     /* true when frame_handle_ready/failed ran (only for external requests) */
};

/* Release a request's buffer: recycle if pooled, free if transient. */
static void preview_request_free_buffer(struct PreviewRequest *req) {
    if (req->pb) {
        preview_buffer_release(req->pb);
        req->pb = NULL;
        req->buffer = NULL; /* owned by the pool */
        req->data = NULL;
    } else {
        if (req->data && req->data != MAP_FAILED) munmap(req->data, req->size);
        if (req->buffer) wl_buffer_destroy(req->buffer);
        req->buffer = NULL;
        req->data = NULL;
    }
}
static void frame_handle_buffer(void *data, struct zsingularity_preview_frame_v1 *frame, uint32_t format, uint32_t width, uint32_t height, uint32_t stride) {
    struct PreviewRequest *req = data;
    req->width = width;
    req->height = height;
    req->stride = stride;
    req->size = (size_t)stride * height;

    /* Preferred path: a recycled (or freshly slotted) pool buffer. */
    struct PreviewBuffer *pb = preview_buffer_acquire(format, width, height, stride);
    if (pb) {
        req->pb = pb;
        req->buffer = pb->buffer;
        req->data = pb->data;
        zsingularity_preview_frame_v1_copy(frame, req->buffer);
        wl_display_flush(ctx.display);
        return;
    }

    /* Fallback: pool exhausted (more concurrent captures than slots). Use a
     * one-shot buffer, freed on the terminal event. */
    int fd = allocate_shm_file(req->size);
    if (fd < 0) {
        g_warning("Failed to create SHM file for preview");
        if (req->callback) req->callback(0, 0, 0, NULL, req->user_data);
        if (req->destroy) req->destroy(req->user_data);
        zsingularity_preview_frame_v1_destroy(frame);
        free(req);
        return;
    }
    req->data = mmap(NULL, req->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (req->data == MAP_FAILED) {
        g_warning("Failed to mmap SHM file");
        if (req->callback) req->callback(0, 0, 0, NULL, req->user_data);
        if (req->destroy) req->destroy(req->user_data);
        close(fd);
        zsingularity_preview_frame_v1_destroy(frame);
        free(req);
        return;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(ctx.shm, fd, req->size);
    if (!pool) {
        g_warning("Failed to create SHM pool");
        munmap(req->data, req->size);
        if (req->callback) req->callback(0, 0, 0, NULL, req->user_data);
        if (req->destroy) req->destroy(req->user_data);
        close(fd);
        zsingularity_preview_frame_v1_destroy(frame);
        free(req);
        return;
    }
    req->buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, format);
    wl_shm_pool_destroy(pool);
    close(fd);
    if (!req->buffer) {
        g_warning("Failed to create SHM buffer");
        munmap(req->data, req->size);
        if (req->callback) req->callback(0, 0, 0, NULL, req->user_data);
        if (req->destroy) req->destroy(req->user_data);
        zsingularity_preview_frame_v1_destroy(frame);
        free(req);
        return;
    }
    zsingularity_preview_frame_v1_copy(frame, req->buffer);
    wl_display_flush(ctx.display);
}
static void frame_handle_flags(void *data, struct zsingularity_preview_frame_v1 *frame, uint32_t flags) {}
static void frame_handle_ready(void *data, struct zsingularity_preview_frame_v1 *frame) {
    struct PreviewRequest *req = data;
    if (!req->cancelled && req->callback) {
        /* Callback copies the pixels out (into a GdkTexture) before we recycle. */
        req->callback(req->width, req->height, req->stride, req->data, req->user_data);
    }
    preview_request_free_buffer(req);
    zsingularity_preview_frame_v1_destroy(frame);
    req->frame = NULL;
    if (req->destroy) { req->destroy(req->user_data); req->destroy = NULL; }
    if (req->external) {
        req->done = true; /* cancel_capture will free req */
    } else {
        free(req);
    }
}
static void frame_handle_failed(void *data, struct zsingularity_preview_frame_v1 *frame) {
    g_warning("[PREVIEW] frame_handle_failed event received");
    struct PreviewRequest *req = data;
    if (!req->cancelled && req->callback) {
        req->callback(0, 0, 0, NULL, req->user_data);
    }
    preview_request_free_buffer(req);
    zsingularity_preview_frame_v1_destroy(frame);
    req->frame = NULL;
    if (req->destroy) { req->destroy(req->user_data); req->destroy = NULL; }
    if (req->external) {
        req->done = true;
    } else {
        free(req);
    }
}
static const struct zsingularity_preview_frame_v1_listener frame_listener = {
    .buffer = frame_handle_buffer,
    .flags = frame_handle_flags,
    .ready = frame_handle_ready,
    .failed = frame_handle_failed,
};
void singularity_wayland_capture_preview(void *toplevel_handle, PreviewCallback callback, void *user_data, GDestroyNotify destroy) {
    g_debug("[PREVIEW] capture_preview called: handle=%p manager=%p shm=%p", toplevel_handle, ctx.preview_manager, ctx.shm);
    if (!ctx.preview_manager) {
        g_warning("[PREVIEW] Preview manager not available");
        if (callback) callback(0, 0, 0, NULL, user_data);
        if (destroy) destroy(user_data);
        return;
    }
    if (!ctx.shm) {
        g_warning("[PREVIEW] SHM not available");
        if (callback) callback(0, 0, 0, NULL, user_data);
        if (destroy) destroy(user_data);
        return;
    }
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) {
        g_message("[PREVIEW] capture skipped: handle %p is no longer valid", toplevel_handle);
        if (callback) callback(0, 0, 0, NULL, user_data);
        if (destroy) destroy(user_data);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = toplevel_handle;
    struct zsingularity_preview_frame_v1 *frame = zsingularity_preview_manager_v1_capture_toplevel(ctx.preview_manager, toplevel, 0);
    if (!frame) {
        g_warning("[PREVIEW] capture_toplevel returned NULL");
        if (callback) callback(0, 0, 0, NULL, user_data);
        if (destroy) destroy(user_data);
        return;
    }
    struct PreviewRequest *req = calloc(1, sizeof(*req));
    req->frame = frame;
    req->callback = callback;
    req->user_data = user_data;
    req->destroy = destroy;
    zsingularity_preview_frame_v1_add_listener(frame, &frame_listener, req);
    wl_display_flush(ctx.display);
}
void* singularity_wayland_capture_preview_cancellable(void *toplevel_handle, PreviewCallback callback, void *user_data, GDestroyNotify destroy) {
    if (!ctx.preview_manager || !ctx.shm ||
        !ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) {
        if (callback) callback(0, 0, 0, NULL, user_data);
        if (destroy) destroy(user_data);
        return NULL;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = toplevel_handle;
    struct zsingularity_preview_frame_v1 *frame = zsingularity_preview_manager_v1_capture_toplevel(ctx.preview_manager, toplevel, 0);
    if (!frame) {
        if (callback) callback(0, 0, 0, NULL, user_data);
        if (destroy) destroy(user_data);
        return NULL;
    }
    struct PreviewRequest *req = calloc(1, sizeof(*req));
    req->frame = frame;
    req->callback = callback;
    req->user_data = user_data;
    req->destroy = destroy;
    req->cancelled = false;
    req->external = true;
    req->done = false;
    zsingularity_preview_frame_v1_add_listener(frame, &frame_listener, req);
    wl_display_flush(ctx.display);
    return req;
}
void singularity_wayland_cancel_capture(void *token) {
    if (!token) return;
    struct PreviewRequest *req = token;

    if (req->done) {
        /* Capture already completed - resources freed in frame_handle_ready/failed. Just free req. */
        free(req);
        return;
    }

    req->cancelled = true;
    if (req->frame) {
        zsingularity_preview_frame_v1_destroy(req->frame);
        req->frame = NULL;
    }
    preview_request_free_buffer(req);
    if (req->destroy) {
        req->destroy(req->user_data);
        req->destroy = NULL;
    }
    free(req);
}
static void toplevel_handle_title(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, const char *title) {
    if (ctx.title_cb) {
        ctx.title_cb(handle, title, ctx.user_data);
    }
}
static void toplevel_handle_app_id(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, const char *app_id) {
    if (wl_debug()) g_message("[Wayland] Toplevel App ID: %s (handle: %p)", app_id, handle);
    if (ctx.opened_cb) {
        ctx.opened_cb(handle, app_id, ctx.user_data);
    }
}
static void toplevel_handle_output_enter(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct wl_output *output) {
    if (!toplevel_output_map)
        toplevel_output_map = g_hash_table_new(NULL, NULL);
    g_hash_table_insert(toplevel_output_map, handle, output);
    if (window_output_changed_cb)
        window_output_changed_cb(handle, window_output_changed_user_data);
}
static void toplevel_handle_output_leave(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct wl_output *output) {
    if (toplevel_output_map && g_hash_table_lookup(toplevel_output_map, handle) == output)
        g_hash_table_remove(toplevel_output_map, handle);
    if (window_output_changed_cb)
        window_output_changed_cb(handle, window_output_changed_user_data);
}
static void toplevel_handle_state(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct wl_array *state) {
    uint32_t *entry;
    int is_maximized = 0;
    int is_fullscreen = 0;
    int is_minimized = 0;
    wl_array_for_each(entry, state) {
        if (*entry == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) {
            if (ctx.focused_cb) {
                ctx.focused_cb(handle, ctx.user_data);
            }
        }
        if (*entry == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MAXIMIZED) {
            is_maximized = 1;
        }
        if (*entry == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_FULLSCREEN) {
            is_fullscreen = 1;
        }
        if (*entry == ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_MINIMIZED) {
            is_minimized = 1;
        }
    }
    if (ctx.state_cb) {
        ctx.state_cb(handle, is_maximized, is_fullscreen, is_minimized, ctx.user_data);
    }
}
static void toplevel_handle_done(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle) {}
static void toplevel_handle_closed(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle) {
    if (toplevel_output_map)
        g_hash_table_remove(toplevel_output_map, handle);
    if (geometry_map)
        g_hash_table_remove(geometry_map, handle);
    /* Mark handle invalid BEFORE notifying Vala so apply_layout can never
     * race and send snap_view for a handle that labwc already destroyed. */
    if (ctx.valid_handles)
        g_hash_table_remove(ctx.valid_handles, handle);
    if (ctx.closed_cb) {
        ctx.closed_cb(handle, ctx.user_data);
    }
    zwlr_foreign_toplevel_handle_v1_destroy(handle);
}
static void toplevel_handle_parent(void *data, struct zwlr_foreign_toplevel_handle_v1 *handle, struct zwlr_foreign_toplevel_handle_v1 *parent) {
    invalidate_toplevel_tileable(handle);
}
static const struct zwlr_foreign_toplevel_handle_v1_listener toplevel_handle_listener = {
    .title = toplevel_handle_title,
    .app_id = toplevel_handle_app_id,
    .output_enter = toplevel_handle_output_enter,
    .output_leave = toplevel_handle_output_leave,
    .state = toplevel_handle_state,
    .done = toplevel_handle_done,
    .closed = toplevel_handle_closed,
    .parent = toplevel_handle_parent,
};
static void toplevel_manager_toplevel(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager, struct zwlr_foreign_toplevel_handle_v1 *toplevel) {
    if (wl_debug()) g_message("[Wayland] New Toplevel Handle: %p", toplevel);
    if (ctx.valid_handles)
        g_hash_table_add(ctx.valid_handles, toplevel);
    zwlr_foreign_toplevel_handle_v1_add_listener(toplevel, &toplevel_handle_listener, NULL);
}
static void toplevel_manager_finished(void *data, struct zwlr_foreign_toplevel_manager_v1 *manager) {
    zwlr_foreign_toplevel_manager_v1_destroy(manager);
    ctx.toplevel_manager = NULL;
}
static const struct zwlr_foreign_toplevel_manager_v1_listener toplevel_manager_listener = {
    .toplevel = toplevel_manager_toplevel,
    .finished = toplevel_manager_finished,
};
static void workspace_handle_id(void *data, struct ext_workspace_handle_v1 *handle, const char *id) {}
static void workspace_handle_name(void *data, struct ext_workspace_handle_v1 *handle, const char *name) {
    if (ctx.ws_created_cb) {
        ctx.ws_created_cb(handle, name, ctx.user_data);
    }
}
static void workspace_handle_coordinates(void *data, struct ext_workspace_handle_v1 *handle, struct wl_array *coordinates) {}
static void workspace_handle_state(void *data, struct ext_workspace_handle_v1 *handle, uint32_t state) {
    if (ctx.ws_state_cb) {
        ctx.ws_state_cb(handle, state, ctx.user_data);
    }
}
static void workspace_handle_capabilities(void *data, struct ext_workspace_handle_v1 *handle, uint32_t capabilities) {}
static void workspace_handle_removed(void *data, struct ext_workspace_handle_v1 *handle) {
    if (ctx.ws_destroyed_cb) {
        ctx.ws_destroyed_cb(handle, ctx.user_data);
    }
    if (workspace_group_map) {
        g_hash_table_remove(workspace_group_map, handle);
    }
    ext_workspace_handle_v1_destroy(handle);
}
static const struct ext_workspace_handle_v1_listener workspace_handle_listener = {
    .id = workspace_handle_id,
    .name = workspace_handle_name,
    .coordinates = workspace_handle_coordinates,
    .state = workspace_handle_state,
    .capabilities = workspace_handle_capabilities,
    .removed = workspace_handle_removed,
};
static void workspace_group_capabilities(void *data, struct ext_workspace_group_handle_v1 *group, uint32_t capabilities) {}
static GPtrArray *group_outputs(struct ext_workspace_group_handle_v1 *group) {
    if (!group_outputs_map) {
        group_outputs_map = g_hash_table_new_full(NULL, NULL, NULL,
            (GDestroyNotify)g_ptr_array_unref);
    }
    GPtrArray *outputs = g_hash_table_lookup(group_outputs_map, group);
    if (!outputs) {
        outputs = g_ptr_array_new();
        g_hash_table_insert(group_outputs_map, group, outputs);
    }
    return outputs;
}
static void workspace_group_output_enter(void *data, struct ext_workspace_group_handle_v1 *group, struct wl_output *output) {
    GPtrArray *outputs = group_outputs(group);
    if (!g_ptr_array_find(outputs, output, NULL)) {
        g_ptr_array_add(outputs, output);
    }
}
static void workspace_group_output_leave(void *data, struct ext_workspace_group_handle_v1 *group, struct wl_output *output) {
    g_ptr_array_remove(group_outputs(group), output);
}
static void workspace_group_workspace_enter(void *data, struct ext_workspace_group_handle_v1 *group, struct ext_workspace_handle_v1 *workspace) {
    if (!workspace_group_map) {
        workspace_group_map = g_hash_table_new(NULL, NULL);
    }
    g_hash_table_insert(workspace_group_map, workspace, group);
}
static void workspace_group_workspace_leave(void *data, struct ext_workspace_group_handle_v1 *group, struct ext_workspace_handle_v1 *workspace) {
    if (workspace_group_map && g_hash_table_lookup(workspace_group_map, workspace) == group) {
        g_hash_table_remove(workspace_group_map, workspace);
    }
}
static void workspace_group_removed(void *data, struct ext_workspace_group_handle_v1 *group) {
    if (ctx.workspace_group == group) {
        ctx.workspace_group = NULL;
    }
    if (group_outputs_map) {
        g_hash_table_remove(group_outputs_map, group);
    }
    ext_workspace_group_handle_v1_destroy(group);
}
static const struct ext_workspace_group_handle_v1_listener workspace_group_listener = {
    .capabilities = workspace_group_capabilities,
    .output_enter = workspace_group_output_enter,
    .output_leave = workspace_group_output_leave,
    .workspace_enter = workspace_group_workspace_enter,
    .workspace_leave = workspace_group_workspace_leave,
    .removed = workspace_group_removed,
};
static void workspace_manager_workspace_group(void *data, struct ext_workspace_manager_v1 *manager, struct ext_workspace_group_handle_v1 *group) {
    if (!ctx.workspace_group) {
        ctx.workspace_group = group;
    }
    ext_workspace_group_handle_v1_add_listener(group, &workspace_group_listener, NULL);
}
static void workspace_manager_workspace(void *data, struct ext_workspace_manager_v1 *manager, struct ext_workspace_handle_v1 *workspace) {
    ext_workspace_handle_v1_add_listener(workspace, &workspace_handle_listener, NULL);
}
static void workspace_manager_done(void *data, struct ext_workspace_manager_v1 *manager) {}
static void workspace_manager_finished(void *data, struct ext_workspace_manager_v1 *manager) {
    ext_workspace_manager_v1_destroy(manager);
    ctx.workspace_manager = NULL;
}
static const struct ext_workspace_manager_v1_listener workspace_manager_listener = {
    .workspace_group = workspace_manager_workspace_group,
    .workspace = workspace_manager_workspace,
    .done = workspace_manager_done,
    .finished = workspace_manager_finished,
};
/* ---- wl_output listener to capture connector names ---- */
static void wl_output_handle_geometry(void *data, struct wl_output *output,
    int32_t x, int32_t y, int32_t phys_w, int32_t phys_h,
    int32_t subpixel, const char *make, const char *model, int32_t transform) {}
static void wl_output_handle_mode(void *data, struct wl_output *output,
    uint32_t flags, int32_t w, int32_t h, int32_t refresh) {}
static void wl_output_handle_done(void *data, struct wl_output *output) {}
static void wl_output_handle_scale(void *data, struct wl_output *output, int32_t factor) {}
static void wl_output_handle_name(void *data, struct wl_output *output, const char *name) {
    if (!output_connector_map)
        output_connector_map = g_hash_table_new_full(NULL, NULL, NULL, g_free);
    g_hash_table_insert(output_connector_map, output, g_strdup(name));
}
static void wl_output_handle_description(void *data, struct wl_output *output, const char *desc) {}
static const struct wl_output_listener wl_output_connector_listener = {
    .geometry    = wl_output_handle_geometry,
    .mode        = wl_output_handle_mode,
    .done        = wl_output_handle_done,
    .scale       = wl_output_handle_scale,
    .name        = wl_output_handle_name,
    .description = wl_output_handle_description,
};

/* ---- Gamma control (wlr-gamma-control-unstable-v1) ---- */

struct GammaOutput {
    struct wl_output *output;
    struct zwlr_gamma_control_v1 *gamma_control;
    uint32_t ramp_size;
    struct GammaOutput *next;
};
static struct GammaOutput *gamma_outputs = NULL;
static int pending_night_light_temp = 0;

/* Tanner Helland colour-temperature, linear RGB approximation */
static void kelvin_to_rgb(int temp_k, double *r, double *g, double *b) {
    double t = (double)temp_k / 100.0;
    if (t <= 66.0) {
        *r = 1.0;
        *g = (99.4708025861 * log(t) - 161.1195681661) / 255.0;
        *b = (t <= 19.0) ? 0.0 : (138.5177312231 * log(t - 10.0) - 305.0447927307) / 255.0;
    } else {
        *r = (329.698727446 * pow(t - 60.0, -0.1332047592)) / 255.0;
        *g = (288.1221695283 * pow(t - 60.0, -0.0755148492)) / 255.0;
        *b = 1.0;
    }
    *r = (*r < 0.0) ? 0.0 : (*r > 1.0) ? 1.0 : *r;
    *g = (*g < 0.0) ? 0.0 : (*g > 1.0) ? 1.0 : *g;
    *b = (*b < 0.0) ? 0.0 : (*b > 1.0) ? 1.0 : *b;
}

static void fill_gamma_ramp(uint16_t *table, uint32_t size,
                             double rw, double gw, double bw) {
    uint16_t *r = table;
    uint16_t *g = table + size;
    uint16_t *b = table + size * 2;
    for (uint32_t i = 0; i < size; i++) {
        double v = (double)i / (double)(size - 1);
        r[i] = (uint16_t)(65535.0 * v * rw);
        g[i] = (uint16_t)(65535.0 * v * gw);
        b[i] = (uint16_t)(65535.0 * v * bw);
    }
}

static void apply_temp_to_output(struct GammaOutput *go, int temp_k) {
    if (!go->gamma_control || go->ramp_size == 0) return;
    double rw, gw, bw;
    kelvin_to_rgb(temp_k, &rw, &gw, &bw);
    size_t sz = go->ramp_size * 3 * sizeof(uint16_t);
    int fd = create_shm_file((off_t)sz);
    if (fd < 0) return;
    uint16_t *table = mmap(NULL, sz, PROT_WRITE, MAP_SHARED, fd, 0);
    if (table != MAP_FAILED) {
        fill_gamma_ramp(table, go->ramp_size, rw, gw, bw);
        munmap(table, sz);
    }
    zwlr_gamma_control_v1_set_gamma(go->gamma_control, fd);
    close(fd);
}

static void gamma_control_gamma_size(void *data,
                                     struct zwlr_gamma_control_v1 *ctrl,
                                     uint32_t size) {
    struct GammaOutput *go = (struct GammaOutput *)data;
    go->ramp_size = size;
    if (pending_night_light_temp > 0) {
        apply_temp_to_output(go, pending_night_light_temp);
        wl_display_flush(ctx.display);
    }
}

static void gamma_control_failed(void *data,
                                  struct zwlr_gamma_control_v1 *ctrl) {
    struct GammaOutput *go = (struct GammaOutput *)data;
    zwlr_gamma_control_v1_destroy(go->gamma_control);
    go->gamma_control = NULL;
    go->ramp_size = 0;
}

static const struct zwlr_gamma_control_v1_listener gamma_control_listener = {
    .gamma_size = gamma_control_gamma_size,
    .failed     = gamma_control_failed,
};

static void gamma_output_attach(struct GammaOutput *go) {
    if (!ctx.gamma_manager || go->gamma_control) return;
    go->gamma_control = zwlr_gamma_control_manager_v1_get_gamma_control(
        ctx.gamma_manager, go->output);
    zwlr_gamma_control_v1_add_listener(go->gamma_control,
                                       &gamma_control_listener, go);
}

void singularity_wayland_set_night_light(int temperature) {
    pending_night_light_temp = temperature;
    for (struct GammaOutput *go = gamma_outputs; go; go = go->next) {
        if (!go->gamma_control && ctx.gamma_manager) {
            go->ramp_size = 0;
            go->gamma_control = zwlr_gamma_control_manager_v1_get_gamma_control(
                ctx.gamma_manager, go->output);
            zwlr_gamma_control_v1_add_listener(go->gamma_control,
                                               &gamma_control_listener, go);
        } else if (go->gamma_control && go->ramp_size > 0) {
            apply_temp_to_output(go, temperature);
        }
    }
    wl_display_flush(ctx.display);
}

void singularity_wayland_reset_night_light(void) {
    pending_night_light_temp = 0;
    for (struct GammaOutput *go = gamma_outputs; go; go = go->next) {
        if (go->gamma_control) {
            zwlr_gamma_control_v1_destroy(go->gamma_control);
            go->gamma_control = NULL;
            go->ramp_size = 0;
        }
    }
    wl_display_flush(ctx.display);
}

/* ---- End gamma control ---- */

/* ── Window geometry cache (for session save) ─────────────────────────────
 * The compositor replies to get_geometry with a single `geometry` event; we
 * cache the last reported geometry per toplevel and read it after a roundtrip. */
struct GeomEntry {
    int x, y, w, h, maximized, fullscreen;
    int work_x, work_y, work_w, work_h;
    char connector[64];
    int got;
    int workarea_got;
    int tileable;
    int tileable_got;
};

static void invalidate_toplevel_tileable(void *handle) {
    struct GeomEntry *e = geometry_map
        ? g_hash_table_lookup(geometry_map, handle) : NULL;
    if (e) e->tileable_got = 0;
}
static void tiling_handle_geometry(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        struct zwlr_foreign_toplevel_handle_v1 *toplevel,
        int32_t x, int32_t y, int32_t width, int32_t height,
        uint32_t maximized, uint32_t fullscreen, const char *output) {
    if (!geometry_map) return;
    struct GeomEntry *e = g_hash_table_lookup(geometry_map, toplevel);
    if (!e) { e = calloc(1, sizeof(*e)); g_hash_table_insert(geometry_map, toplevel, e); }
    e->x = x; e->y = y; e->w = width; e->h = height;
    e->maximized = (int) maximized; e->fullscreen = (int) fullscreen;
    g_strlcpy(e->connector, output ? output : "", sizeof(e->connector));
    e->got = 1;
}

static void tiling_handle_workarea(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        struct zwlr_foreign_toplevel_handle_v1 *toplevel,
        int32_t x, int32_t y, int32_t width, int32_t height) {
    if (!geometry_map) return;
    struct GeomEntry *e = g_hash_table_lookup(geometry_map, toplevel);
    if (!e) {
        e = calloc(1, sizeof(*e));
        g_hash_table_insert(geometry_map, toplevel, e);
    }
    e->work_x = x;
    e->work_y = y;
    e->work_w = width;
    e->work_h = height;
    e->workarea_got = 1;
}

static void tiling_handle_tileable(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        struct zwlr_foreign_toplevel_handle_v1 *toplevel,
        uint32_t tileable) {
    if (!geometry_map) return;
    struct GeomEntry *e = g_hash_table_lookup(geometry_map, toplevel);
    if (!e) {
        e = calloc(1, sizeof(*e));
        g_hash_table_insert(geometry_map, toplevel, e);
    }
    e->tileable = tileable != 0;
    e->tileable_got = 1;
}

static void tiling_handle_layout_workarea(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        int32_t x, int32_t y, int32_t width, int32_t height) {
    layout_workarea.x = x;
    layout_workarea.y = y;
    layout_workarea.w = width;
    layout_workarea.h = height;
    layout_workarea.got = 1;
}

static void tiling_handle_layout_output_workarea(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        int32_t x, int32_t y, int32_t width, int32_t height) {
    if (layout_output_workarea_count >= 32) return;
    int index = layout_output_workarea_count++;
    layout_output_workareas[index].x = x;
    layout_output_workareas[index].y = y;
    layout_output_workareas[index].w = width;
    layout_output_workareas[index].h = height;
}

static void tiling_handle_layout_workarea_done(void *data,
        struct zsingularity_tiling_manager_v1 *mgr) {
    layout_workarea.done = 1;
}

static void tiling_handle_cursor_position(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        int32_t x, int32_t y) {
    (void)data;
    (void)mgr;
    if (cursor_position_cb)
        cursor_position_cb(x, y, cursor_position_user_data);
}

static void tiling_handle_interaction(void *data,
        struct zsingularity_tiling_manager_v1 *mgr,
        struct zwlr_foreign_toplevel_handle_v1 *toplevel,
        uint32_t phase, uint32_t kind,
        int32_t x, int32_t y, int32_t width, int32_t height,
        int32_t cursor_x, int32_t cursor_y, uint32_t edges,
        uint32_t float_candidate) {
    (void)data;
    (void)mgr;
    if (tiling_interaction_cb)
        tiling_interaction_cb(toplevel, phase, kind, x, y, width, height,
            cursor_x, cursor_y, edges, float_candidate != 0,
            tiling_interaction_user_data);
}
static const struct zsingularity_tiling_manager_v1_listener tiling_listener = {
    .geometry = tiling_handle_geometry,
    .workarea = tiling_handle_workarea,
    .interaction = tiling_handle_interaction,
    .tileable = tiling_handle_tileable,
    .layout_workarea = tiling_handle_layout_workarea,
    .layout_output_workarea = tiling_handle_layout_output_workarea,
    .layout_workarea_done = tiling_handle_layout_workarea_done,
    .cursor_position = tiling_handle_cursor_position,
};

static void gesture_handle_begin(void *data,
        struct zsingularity_gesture_manager_v1 *manager,
        uint32_t fingers, uint32_t direction) {
    (void)data;
    (void)manager;
    desktop_gesture_fingers = fingers;
    desktop_gesture_direction = direction;
    if (desktop_gesture_cb)
        desktop_gesture_cb(0, fingers, direction, 0, 0, 0, 0,
            desktop_gesture_user_data);
}

static void gesture_handle_update(void *data,
        struct zsingularity_gesture_manager_v1 *manager,
        wl_fixed_t dx, wl_fixed_t dy) {
    (void)data;
    (void)manager;
    if (desktop_gesture_cb)
        desktop_gesture_cb(1, desktop_gesture_fingers,
            desktop_gesture_direction,
            wl_fixed_to_double(dx), wl_fixed_to_double(dy), 0, 0,
            desktop_gesture_user_data);
}

static void gesture_handle_end(void *data,
        struct zsingularity_gesture_manager_v1 *manager,
        uint32_t cancelled, uint32_t committed) {
    (void)data;
    (void)manager;
    if (desktop_gesture_cb)
        desktop_gesture_cb(2, desktop_gesture_fingers,
            desktop_gesture_direction, 0, 0,
            cancelled != 0, committed != 0, desktop_gesture_user_data);
    desktop_gesture_fingers = 0;
    desktop_gesture_direction = 0;
}

static const struct zsingularity_gesture_manager_v1_listener gesture_listener = {
    .begin = gesture_handle_begin,
    .update = gesture_handle_update,
    .end = gesture_handle_end,
};

static void pip_handle_shown(void *data,
        struct zsingularity_pip_manager_v1 *manager) {
    (void)data;
    (void)manager;
    if (wl_debug()) g_message("[PiP] compositor view ready");
}

static void pip_handle_failed(void *data,
        struct zsingularity_pip_manager_v1 *manager, uint32_t reason) {
    (void)data;
    (void)manager;
    const char *message = "render failed";
    switch (reason) {
        case ZSINGULARITY_PIP_MANAGER_V1_FAILURE_REASON_INVALID_TOPLEVEL:
            message = "invalid toplevel";
            break;
        case ZSINGULARITY_PIP_MANAGER_V1_FAILURE_REASON_INVALID_REGION:
            message = "invalid region";
            break;
        case ZSINGULARITY_PIP_MANAGER_V1_FAILURE_REASON_NO_WINDOW:
            message = "no window in the selected region";
            break;
    }
    g_warning("[PiP] %s", message);
}

static const struct zsingularity_pip_manager_v1_listener pip_listener = {
    .shown = pip_handle_shown,
    .failed = pip_handle_failed,
};

static void registry_handle_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (strcmp(interface, zwlr_foreign_toplevel_manager_v1_interface.name) == 0) {
        if (wl_debug()) g_message("[Wayland] Found Toplevel Manager");
        ctx.toplevel_manager = wl_registry_bind(registry, name, &zwlr_foreign_toplevel_manager_v1_interface, 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(ctx.toplevel_manager, &toplevel_manager_listener, NULL);
    } else if (strcmp(interface, ext_workspace_manager_v1_interface.name) == 0) {
        ctx.workspace_manager = wl_registry_bind(registry, name, &ext_workspace_manager_v1_interface, 1);
        ext_workspace_manager_v1_add_listener(ctx.workspace_manager, &workspace_manager_listener, NULL);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        ctx.seat = wl_registry_bind(registry, name, &wl_seat_interface, 7);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        ctx.shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, zsingularity_preview_manager_v1_interface.name) == 0) {
        ctx.preview_manager = wl_registry_bind(registry, name, &zsingularity_preview_manager_v1_interface, 1);
    } else if (strcmp(interface, zsingularity_pip_manager_v1_interface.name) == 0) {
        ctx.pip_manager = wl_registry_bind(registry, name,
            &zsingularity_pip_manager_v1_interface, 1);
        zsingularity_pip_manager_v1_add_listener(ctx.pip_manager,
            &pip_listener, NULL);
    } else if (strcmp(interface, zwlr_output_manager_v1_interface.name) == 0) {
        ctx.output_manager = wl_registry_bind(registry, name, &zwlr_output_manager_v1_interface, 4);
        zwlr_output_manager_v1_add_listener(ctx.output_manager, &output_manager_listener, NULL);
    } else if (strcmp(interface, zsingularity_tiling_manager_v1_interface.name) == 0) {
        uint32_t v = version < 10 ? version : 10;
        ctx.tiling_manager = wl_registry_bind(registry, name, &zsingularity_tiling_manager_v1_interface, v);
        if (v >= 2)
            zsingularity_tiling_manager_v1_add_listener(ctx.tiling_manager, &tiling_listener, NULL);
    } else if (strcmp(interface, zsingularity_gesture_manager_v1_interface.name) == 0) {
        uint32_t bind_version = version < 2 ? version : 2;
        ctx.gesture_manager = wl_registry_bind(registry, name,
            &zsingularity_gesture_manager_v1_interface, bind_version);
        zsingularity_gesture_manager_v1_add_listener(ctx.gesture_manager,
            &gesture_listener, NULL);
    } else if (strcmp(interface, zwlr_gamma_control_manager_v1_interface.name) == 0) {
        ctx.gamma_manager = wl_registry_bind(registry, name, &zwlr_gamma_control_manager_v1_interface, 1);
        for (struct GammaOutput *go = gamma_outputs; go; go = go->next)
            gamma_output_attach(go);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        struct GammaOutput *go = calloc(1, sizeof(*go));
        /* Bind at version 4 to receive the wl_output.name event (connector string) */
        uint32_t ver = (version >= 4) ? 4 : version;
        go->output = wl_registry_bind(registry, name, &wl_output_interface, ver);
        go->next = gamma_outputs;
        gamma_outputs = go;
        gamma_output_attach(go);
        /* Listen for connector name so we can match toplevel outputs to GdkMonitors */
        wl_output_add_listener(go->output, &wl_output_connector_listener, NULL);
    }
}

void singularity_wayland_set_desktop_gesture_callback(
        DesktopGestureCallback cb, void *user_data) {
    desktop_gesture_cb = cb;
    desktop_gesture_user_data = user_data;
}

void singularity_wayland_toggle_desktop_reveal(void) {
    if (ctx.gesture_manager &&
            zsingularity_gesture_manager_v1_get_version(ctx.gesture_manager) >= 2)
        zsingularity_gesture_manager_v1_toggle_desktop_reveal(
            ctx.gesture_manager);
}

void singularity_wayland_set_tiling_interaction_callback(
        TilingInteractionCallback cb, void *user_data) {
    tiling_interaction_cb = cb;
    tiling_interaction_user_data = user_data;
}

void singularity_wayland_set_cursor_position_callback(
        CursorPositionCallback cb, void *user_data) {
    cursor_position_cb = cb;
    cursor_position_user_data = user_data;
}
static void registry_handle_global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
    .global = registry_handle_global,
    .global_remove = registry_handle_global_remove,
};

static void log_wayland_dispatch_error(struct wl_display *display,
        const char *context) {
    int error = wl_display_get_error(display);
    if (error == EPROTO) {
        const struct wl_interface *interface = NULL;
        uint32_t object_id = 0;
        uint32_t code = wl_display_get_protocol_error(display, &interface,
            &object_id);
        g_critical("%s: protocol error %u on %s@%u", context, code,
            interface ? interface->name : "unknown", object_id);
        return;
    }
    g_critical("%s: %s", context,
        error ? g_strerror(error) : "Wayland socket closed");
}

static gboolean wayland_event_source_cb(GIOChannel *source, GIOCondition condition, gpointer data) {
    struct wl_display *display = (struct wl_display *)data;
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        log_wayland_dispatch_error(display, "Wayland connection lost");
        exit(1);
    }
    if (wl_display_dispatch(display) < 0) {
        log_wayland_dispatch_error(display, "Wayland dispatch failed");
        exit(1);
    }
    return TRUE;
}
void singularity_wayland_init(
    AppOpenedCallback opened_cb, 
    AppClosedCallback closed_cb, 
    AppFocusedCallback focused_cb,
    AppTitleChangedCallback title_cb,
    AppStateChangedCallback state_cb,
    WorkspaceCreatedCallback ws_created_cb,
    WorkspaceDestroyedCallback ws_destroyed_cb,
    WorkspaceStateCallback ws_state_cb,
    void* user_data
) {
    ctx.opened_cb = opened_cb;
    ctx.closed_cb = closed_cb;
    ctx.focused_cb = focused_cb;
    ctx.title_cb = title_cb;
    ctx.state_cb = state_cb;
    ctx.ws_created_cb = ws_created_cb;
    ctx.ws_destroyed_cb = ws_destroyed_cb;
    ctx.ws_state_cb = ws_state_cb;
    ctx.user_data = user_data;
    ctx.valid_handles = g_hash_table_new(NULL, NULL);
    if (wl_debug()) fprintf(stderr, "[Wayland] Initializing Wayland Integration...\n");
    ctx.display = wl_display_connect(NULL);
    if (!ctx.display) {
        fprintf(stderr, "Failed to connect to Wayland display\n");
        return;
    }
    ctx.registry = wl_display_get_registry(ctx.display);
    if (!ctx.registry) {
        fprintf(stderr, "[Wayland] Failed to get registry\n");
        return;
    }
    if (wl_debug()) fprintf(stderr, "[Wayland] Registry: %p\n", ctx.registry);
    wl_registry_add_listener(ctx.registry, &registry_listener, NULL);
    int ret = wl_display_roundtrip(ctx.display);
    if (wl_debug()) fprintf(stderr, "[Wayland] Roundtrip 1: %d\n", ret);
    if (ret < 0) {
        fprintf(stderr, "[Wayland] Fatal: roundtrip 1 failed, restarting\n");
        exit(1);
    }
    ret = wl_display_roundtrip(ctx.display);
    if (wl_debug()) fprintf(stderr, "[Wayland] Roundtrip 2: %d\n", ret);
    if (ret < 0) {
        fprintf(stderr, "[Wayland] Fatal: roundtrip 2 failed, restarting\n");
        exit(1);
    }
    int fd = wl_display_get_fd(ctx.display);
    GIOChannel *channel = g_io_channel_unix_new(fd);
    g_io_add_watch(channel, G_IO_IN | G_IO_HUP | G_IO_ERR, wayland_event_source_cb, ctx.display);
    g_io_channel_unref(channel);
}
void singularity_wayland_activate_window(void *handle) {
    if (!ctx.seat) return;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, handle)) {
        if (wl_debug()) g_message("[Wayland] activate_window skipped: handle %p is no longer valid", handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)handle;
    zwlr_foreign_toplevel_handle_v1_activate(toplevel, ctx.seat);
    wl_display_flush(ctx.display);
}

int singularity_wayland_show_window_pip(void *handle) {
    if (!ctx.pip_manager || !ctx.valid_handles ||
            !g_hash_table_contains(ctx.valid_handles, handle)) {
        return 0;
    }
    zsingularity_pip_manager_v1_show_toplevel(ctx.pip_manager,
        (struct zwlr_foreign_toplevel_handle_v1 *)handle);
    wl_display_flush(ctx.display);
    return 1;
}

int singularity_wayland_show_region_pip(int x, int y, int width, int height) {
    if (!ctx.pip_manager || width <= 0 || height <= 0) {
        return 0;
    }
    zsingularity_pip_manager_v1_show_region(ctx.pip_manager,
        x, y, width, height);
    wl_display_flush(ctx.display);
    return 1;
}

void singularity_wayland_close_pip(void) {
    if (!ctx.pip_manager) return;
    zsingularity_pip_manager_v1_close(ctx.pip_manager);
    wl_display_flush(ctx.display);
}
const char *singularity_wayland_get_workspace_connector(void *handle) {
    if (!workspace_group_map || !output_connector_map) return NULL;
    struct ext_workspace_group_handle_v1 *group = g_hash_table_lookup(workspace_group_map, handle);
    if (!group || !group_outputs_map) return NULL;
    GPtrArray *outputs = g_hash_table_lookup(group_outputs_map, group);
    if (!outputs || outputs->len != 1) return NULL;
    return g_hash_table_lookup(output_connector_map, g_ptr_array_index(outputs, 0));
}

void *singularity_wayland_get_workspace_group(void *handle) {
    return workspace_group_map ? g_hash_table_lookup(workspace_group_map, handle) : NULL;
}

void singularity_wayland_activate_workspace(void *handle) {
    if (!handle) return;
    struct ext_workspace_handle_v1 *ws = (struct ext_workspace_handle_v1 *)handle;
    ext_workspace_handle_v1_activate(ws);
    if (ctx.workspace_manager) {
        ext_workspace_manager_v1_commit(ctx.workspace_manager);
        wl_display_flush(ctx.display);
    }
}
void singularity_wayland_create_workspace(const char *name) {
    if (ctx.workspace_group) {
        ext_workspace_group_handle_v1_create_workspace(ctx.workspace_group, name);
        if (ctx.workspace_manager) {
            ext_workspace_manager_v1_commit(ctx.workspace_manager);
        }
    }
}
void singularity_wayland_remove_workspace(void *handle) {
    if (!handle) return;
    struct ext_workspace_handle_v1 *ws = (struct ext_workspace_handle_v1 *)handle;
    ext_workspace_handle_v1_remove(ws);
    if (ctx.workspace_manager) {
        ext_workspace_manager_v1_commit(ctx.workspace_manager);
        wl_display_flush(ctx.display);
    }
}
void singularity_wayland_assign_toplevel(void *workspace_handle, void *toplevel_handle) {
    // NOTE: ext-workspace-v1 has no standard way to assign a toplevel to a
    // workspace; that was a custom request a patched labwc/wlroots used to
    // implement. Upstream labwc (wlroots wlr_ext_workspace_v1) only handles
    // ACTIVATE, so sending the old assign request triggers a Wayland protocol
    // error that aborts the shell. Until the compositor exposes a supported
    // path, do nothing here rather than crash.
    (void) workspace_handle;
    (void) toplevel_handle;
    if (wl_debug()) g_message("[Wayland] assign_toplevel is unsupported by the current compositor; skipping");
}
void singularity_wayland_minimize_window(void* handle) {
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, handle)) {
        if (wl_debug()) g_message("[Wayland] minimize skipped: handle %p is no longer valid", handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)handle;
    zwlr_foreign_toplevel_handle_v1_minimize(toplevel);
    wl_display_flush(ctx.display);
}
void singularity_wayland_unminimize_window(void* handle) {
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, handle)) {
        if (wl_debug()) g_message("[Wayland] unminimize skipped: handle %p is no longer valid", handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)handle;
    zwlr_foreign_toplevel_handle_v1_unset_minimize(toplevel);
    wl_display_flush(ctx.display);
}
void singularity_wayland_close_window(void* handle) {
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, handle)) {
        if (wl_debug()) g_message("[Wayland] close skipped: handle %p is no longer valid", handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)handle;
    zwlr_foreign_toplevel_handle_v1_close(toplevel);
    wl_display_flush(ctx.display);
}
static struct zwlr_output_configuration_v1 *current_config = NULL;
static void config_handle_succeeded(void *data, struct zwlr_output_configuration_v1 *config) {
    if (wl_debug()) g_message("Output config: SUCCEEDED");
    zwlr_output_configuration_v1_destroy(config);
    if (current_config == config) current_config = NULL;
}
static void config_handle_failed(void *data, struct zwlr_output_configuration_v1 *config) {
    g_warning("Output config: FAILED");
    zwlr_output_configuration_v1_destroy(config);
    if (current_config == config) current_config = NULL;
}
static void config_handle_cancelled(void *data, struct zwlr_output_configuration_v1 *config) {
    g_warning("Output config: CANCELLED");
    zwlr_output_configuration_v1_destroy(config);
    if (current_config == config) current_config = NULL;
}
static const struct zwlr_output_configuration_v1_listener config_listener = {
    .succeeded = config_handle_succeeded,
    .failed = config_handle_failed,
    .cancelled = config_handle_cancelled,
};
void singularity_wayland_begin_output_config(uint32_t serial) {
    if (!ctx.output_manager) return;
    current_config = zwlr_output_manager_v1_create_configuration(ctx.output_manager, serial);
    zwlr_output_configuration_v1_add_listener(current_config, &config_listener, NULL);
}
void singularity_wayland_config_head(void *head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh) {
    if (!current_config) return;
    struct zwlr_output_head_v1 *head = head_handle;
    if (wl_debug()) g_message("config_head: enabled=%d x=%d y=%d scale=%.2f mode=%dx%d@%d", enabled, x, y, scale, mode_width, mode_height, mode_refresh);
    if (enabled) {
        struct zwlr_output_configuration_head_v1 *config_head = zwlr_output_configuration_v1_enable_head(current_config, head);
        zwlr_output_configuration_head_v1_set_position(config_head, x, y);
        zwlr_output_configuration_head_v1_set_scale(config_head, wl_fixed_from_double(scale));
        zwlr_output_configuration_head_v1_set_transform(config_head, transform);
        // Only set mode if dimensions are valid
        if (mode_width > 0 && mode_height > 0) {
            struct zwlr_output_mode_v1 *matching_mode = NULL;
            struct HeadNode *curr = heads_list;
            while (curr) {
                if (curr->data->head == head) {
                    struct ModeEntry *me = curr->data->modes;
                    // First pass: exact match (width + height + refresh)
                    while (me) {
                        if (me->width == mode_width && me->height == mode_height && me->refresh == mode_refresh) {
                            matching_mode = me->mode;
                            break;
                        }
                        me = me->next;
                    }
                    // Second pass: match by size only (closest refresh)
                    if (!matching_mode) {
                        me = curr->data->modes;
                        while (me) {
                            if (me->width == mode_width && me->height == mode_height) {
                                matching_mode = me->mode;
                                break;
                            }
                            me = me->next;
                        }
                    }
                    break;
                }
                curr = curr->next;
            }
            if (matching_mode) {
                zwlr_output_configuration_head_v1_set_mode(config_head, matching_mode);
            }
            // If no match found, don't set a mode - compositor keeps current mode
        }
        // If mode is 0x0, don't set a mode - compositor keeps current mode
    } else {
        zwlr_output_configuration_v1_disable_head(current_config, head);
    }
}
void singularity_wayland_config_head_v2(void *head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh, int adaptive_sync) {
    if (!current_config) return;
    struct zwlr_output_head_v1 *head = head_handle;
    if (wl_debug()) g_message("config_head_v2: enabled=%d x=%d y=%d scale=%.2f mode=%dx%d@%d adaptive_sync=%d", enabled, x, y, scale, mode_width, mode_height, mode_refresh, adaptive_sync);
    if (enabled) {
        struct zwlr_output_configuration_head_v1 *config_head = zwlr_output_configuration_v1_enable_head(current_config, head);
        zwlr_output_configuration_head_v1_set_position(config_head, x, y);
        zwlr_output_configuration_head_v1_set_scale(config_head, wl_fixed_from_double(scale));
        zwlr_output_configuration_head_v1_set_transform(config_head, transform);
        if (adaptive_sync != 2) {
            zwlr_output_configuration_head_v1_set_adaptive_sync(config_head, (uint32_t)adaptive_sync);
        }
        if (mode_width > 0 && mode_height > 0) {
            struct zwlr_output_mode_v1 *matching_mode = NULL;
            struct HeadNode *curr = heads_list;
            while (curr) {
                if (curr->data->head == head) {
                    struct ModeEntry *me = curr->data->modes;
                    while (me) {
                        if (me->width == mode_width && me->height == mode_height && me->refresh == mode_refresh) {
                            matching_mode = me->mode;
                            break;
                        }
                        me = me->next;
                    }
                    if (!matching_mode) {
                        me = curr->data->modes;
                        while (me) {
                            if (me->width == mode_width && me->height == mode_height) {
                                matching_mode = me->mode;
                                break;
                            }
                            me = me->next;
                        }
                    }
                    break;
                }
                curr = curr->next;
            }
            if (matching_mode) {
                zwlr_output_configuration_head_v1_set_mode(config_head, matching_mode);
            }
        }
    } else {
        zwlr_output_configuration_v1_disable_head(current_config, head);
    }
}
void singularity_wayland_finish_output_config() {
    if (!current_config) return;
    zwlr_output_configuration_v1_apply(current_config);
    wl_display_flush(ctx.display);
}

int singularity_wayland_get_window_geometry(void* toplevel_handle,
        int* x, int* y, int* w, int* h, int* maximized, int* fullscreen,
        char** connector) {
    if (x) *x = 0; if (y) *y = 0; if (w) *w = 0; if (h) *h = 0;
    if (maximized) *maximized = 0; if (fullscreen) *fullscreen = 0;
    if (connector) *connector = NULL;
    if (!ctx.tiling_manager || !ctx.display) return 0;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) return 0;
    if (!geometry_map) geometry_map = g_hash_table_new_full(NULL, NULL, NULL, free);

    struct zwlr_foreign_toplevel_handle_v1 *toplevel = toplevel_handle;
    struct GeomEntry *e = g_hash_table_lookup(geometry_map, toplevel);
    if (e) e->got = 0;
    zsingularity_tiling_manager_v1_get_geometry(ctx.tiling_manager, toplevel);
    wl_display_roundtrip(ctx.display); /* process the geometry event */

    e = g_hash_table_lookup(geometry_map, toplevel);
    if (!e || !e->got) return 0;
    if (x) *x = e->x; if (y) *y = e->y; if (w) *w = e->w; if (h) *h = e->h;
    if (maximized) *maximized = e->maximized;
    if (fullscreen) *fullscreen = e->fullscreen;
    if (connector) *connector = g_strdup(e->connector);
    return 1;
}

int singularity_wayland_get_window_workarea(void *toplevel_handle,
        int *x, int *y, int *w, int *h) {
    if (x) *x = 0;
    if (y) *y = 0;
    if (w) *w = 0;
    if (h) *h = 0;
    if (!ctx.tiling_manager || !ctx.display) return 0;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 4) return 0;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) return 0;
    if (!geometry_map) geometry_map = g_hash_table_new_full(NULL, NULL, NULL, free);

    struct zwlr_foreign_toplevel_handle_v1 *toplevel = toplevel_handle;
    struct GeomEntry *e = g_hash_table_lookup(geometry_map, toplevel);
    if (e) e->workarea_got = 0;
    zsingularity_tiling_manager_v1_get_workarea(ctx.tiling_manager, toplevel);
    wl_display_roundtrip(ctx.display);

    e = g_hash_table_lookup(geometry_map, toplevel);
    if (!e || !e->workarea_got) return 0;
    if (x) *x = e->work_x;
    if (y) *y = e->work_y;
    if (w) *w = e->work_w;
    if (h) *h = e->work_h;
    return 1;
}

int singularity_wayland_get_layout_workarea(int *x, int *y, int *w, int *h) {
    if (x) *x = 0;
    if (y) *y = 0;
    if (w) *w = 0;
    if (h) *h = 0;
    if (!ctx.tiling_manager || !ctx.display) return 0;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 9)
        return 0;

    layout_workarea.got = 0;
    layout_workarea.done = 0;
    layout_output_workarea_count = 0;
    zsingularity_tiling_manager_v1_get_layout_workarea(ctx.tiling_manager);
    wl_display_roundtrip(ctx.display);
    if (!layout_workarea.got || !layout_workarea.done
            || layout_workarea.w < 1
            || layout_workarea.h < 1) return 0;
    if (x) *x = layout_workarea.x;
    if (y) *y = layout_workarea.y;
    if (w) *w = layout_workarea.w;
    if (h) *h = layout_workarea.h;
    return 1;
}

int singularity_wayland_get_layout_output_count(void) {
    return layout_workarea.done ? layout_output_workarea_count : 0;
}

int singularity_wayland_get_layout_output_workarea(int index,
        int *x, int *y, int *w, int *h) {
    if (index < 0 || index >= singularity_wayland_get_layout_output_count())
        return 0;
    if (x) *x = layout_output_workareas[index].x;
    if (y) *y = layout_output_workareas[index].y;
    if (w) *w = layout_output_workareas[index].w;
    if (h) *h = layout_output_workareas[index].h;
    return 1;
}

int singularity_wayland_request_cursor_position(void) {
    if (!ctx.tiling_manager || !ctx.display) return 0;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 10)
        return 0;
    zsingularity_tiling_manager_v1_get_cursor_position(ctx.tiling_manager);
    wl_display_flush(ctx.display);
    return 1;
}

int singularity_wayland_window_is_tileable(void *toplevel_handle) {
    if (!ctx.tiling_manager || !ctx.display) return 1;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 7)
        return 1;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles,
            toplevel_handle)) return 0;
    if (!geometry_map)
        geometry_map = g_hash_table_new_full(NULL, NULL, NULL, free);

    struct zwlr_foreign_toplevel_handle_v1 *toplevel = toplevel_handle;
    struct GeomEntry *e = g_hash_table_lookup(geometry_map, toplevel);
    if (!e || !e->tileable_got) {
        zsingularity_tiling_manager_v1_get_tileable(ctx.tiling_manager,
            toplevel);
        wl_display_roundtrip(ctx.display);
        e = g_hash_table_lookup(geometry_map, toplevel);
    }
    return e && e->tileable_got ? e->tileable : 1;
}

void singularity_wayland_set_geometry(void* toplevel_handle, int x, int y, int width, int height) {
    if (!ctx.tiling_manager) return;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) {
        if (wl_debug()) g_message("[Wayland] set_geometry skipped: handle %p is no longer valid", toplevel_handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)toplevel_handle;
    zsingularity_tiling_manager_v1_set_geometry(ctx.tiling_manager, toplevel, x, y, width, height);
    wl_display_flush(ctx.display);
}
void singularity_wayland_set_close_gesture_progress(void* toplevel_handle,
        double progress) {
    if (!ctx.tiling_manager) return;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 8) return;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles,
            toplevel_handle)) return;
    struct zwlr_foreign_toplevel_handle_v1 *toplevel =
        (struct zwlr_foreign_toplevel_handle_v1 *)toplevel_handle;
    zsingularity_tiling_manager_v1_set_close_gesture_progress(
        ctx.tiling_manager, toplevel, wl_fixed_from_double(progress));
    wl_display_flush(ctx.display);
}
void singularity_wayland_set_tiled(void* toplevel_handle, uint32_t tiled) {
    if (!ctx.tiling_manager) return;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) {
        if (wl_debug()) g_message("[Wayland] set_tiled skipped: handle %p is no longer valid", toplevel_handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)toplevel_handle;
    zsingularity_tiling_manager_v1_set_tiled(ctx.tiling_manager, toplevel, tiled);
    wl_display_flush(ctx.display);
}
void singularity_wayland_set_scrolling_mode(uint32_t enabled) {
    if (!ctx.tiling_manager) return;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 5) return;
    zsingularity_tiling_manager_v1_set_scrolling_mode(ctx.tiling_manager,
        enabled);
    wl_display_flush(ctx.display);
}
void singularity_wayland_detach_tiled(void* toplevel_handle) {
    if (!ctx.tiling_manager) return;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 5) return;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles,
            toplevel_handle)) return;
    struct zwlr_foreign_toplevel_handle_v1 *toplevel =
        (struct zwlr_foreign_toplevel_handle_v1 *)toplevel_handle;
    zsingularity_tiling_manager_v1_detach_tiled(ctx.tiling_manager, toplevel);
    wl_display_flush(ctx.display);
}
void singularity_wayland_set_tiling_drop_preview(int x, int y, int width,
        int height, uint32_t visible) {
    if (!ctx.tiling_manager) return;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 6) return;
    zsingularity_tiling_manager_v1_set_drop_preview(ctx.tiling_manager,
        x, y, width, height, visible);
    wl_display_flush(ctx.display);
}
void singularity_wayland_snap_view(void* toplevel_handle, uint32_t direction) {
    if (!ctx.tiling_manager) return;
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) {
        if (wl_debug()) g_message("[Wayland] snap_view skipped: handle %p is no longer valid", toplevel_handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)toplevel_handle;
    zsingularity_tiling_manager_v1_snap_view(ctx.tiling_manager, toplevel, direction);
    wl_display_flush(ctx.display);
}
void singularity_wayland_move_to_workspace(void* toplevel_handle, uint32_t workspace_index) {
    if (!ctx.tiling_manager) return;
    if (wl_proxy_get_version((struct wl_proxy *)ctx.tiling_manager) < 3) {
        if (wl_debug()) g_message("[Wayland] move_to_workspace unsupported by compositor (tiling < v3); skipping");
        return;
    }
    if (!ctx.valid_handles || !g_hash_table_contains(ctx.valid_handles, toplevel_handle)) {
        if (wl_debug()) g_message("[Wayland] move_to_workspace skipped: handle %p is no longer valid", toplevel_handle);
        return;
    }
    struct zwlr_foreign_toplevel_handle_v1 *toplevel = (struct zwlr_foreign_toplevel_handle_v1 *)toplevel_handle;
    zsingularity_tiling_manager_v1_move_to_workspace(ctx.tiling_manager, toplevel, workspace_index);
    wl_display_flush(ctx.display);
}

void singularity_wayland_set_window_output_changed_callback(WindowOutputChangedCallback cb, void *user_data) {
    window_output_changed_cb = cb;
    window_output_changed_user_data = user_data;
}

void* singularity_wayland_get_window_monitor(void *handle) {
    if (!toplevel_output_map) return NULL;
    struct wl_output *wl_out = (struct wl_output *)g_hash_table_lookup(toplevel_output_map, handle);
    if (!wl_out) return NULL;

    /* Our wl_output proxy and GDK's are from different connections; we bridge
     * via the connector name (set by wl_output.name event, v4). */
    const char *connector = output_connector_map
        ? (const char *)g_hash_table_lookup(output_connector_map, wl_out)
        : NULL;

    GdkDisplay *display = gdk_display_get_default();
    if (!display) return NULL;
    GListModel *monitors = gdk_display_get_monitors(display);
    guint n = g_list_model_get_n_items(monitors);

    if (connector) {
        /* Match by connector name - most reliable */
        for (guint i = 0; i < n; i++) {
            GdkMonitor *mon = GDK_MONITOR(g_list_model_get_item(monitors, i));
            const char *mon_conn = gdk_monitor_get_connector(mon);
            if (mon_conn && strcmp(mon_conn, connector) == 0)
                return (void *)mon;
            g_object_unref(mon);
        }
    }

    /* Fallback: compare by Wayland object ID (same connection only, may not work) */
    uint32_t wl_out_id = wl_proxy_get_id((struct wl_proxy *)wl_out);
    for (guint i = 0; i < n; i++) {
        GdkMonitor *mon = GDK_MONITOR(g_list_model_get_item(monitors, i));
        struct wl_output *mon_wl = gdk_wayland_monitor_get_wl_output(mon);
        if (mon_wl && wl_proxy_get_id((struct wl_proxy *)mon_wl) == wl_out_id)
            return (void *)mon;
        g_object_unref(mon);
    }
    return NULL;
}

static void probe_handle_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)registry; (void)name; (void)version;
    GString *s = (GString *)data;
    g_string_append(s, interface);
    g_string_append_c(s, '\n');
}
static void probe_handle_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener probe_registry_listener = {
    .global = probe_handle_global,
    .global_remove = probe_handle_global_remove,
};

/* Returns a newline-separated list of the Wayland global interfaces the running
 * compositor advertises. Opens its own short-lived connection so it is safe to
 * call independently of the main integration. Caller frees with g_free(). */
char* singularity_wayland_list_globals(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return g_strdup("");
    struct wl_registry *registry = wl_display_get_registry(display);
    if (!registry) { wl_display_disconnect(display); return g_strdup(""); }
    GString *s = g_string_new(NULL);
    wl_registry_add_listener(registry, &probe_registry_listener, s);
    wl_display_roundtrip(display);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return g_string_free(s, FALSE);
}
