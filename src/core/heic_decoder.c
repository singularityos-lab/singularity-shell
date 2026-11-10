#include <dlfcn.h>
#include <stdint.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>

typedef struct {
    int code;
    int subcode;
    const char *message;
} HeifError;

typedef void *(*ContextAlloc)(void);
typedef void (*ContextFree)(void *);
typedef HeifError (*ReadFromFile)(void *, const char *, const void *);
typedef int (*ImageCount)(void *);
typedef int (*ImageIds)(void *, uint32_t *, int);
typedef HeifError (*ImageHandle)(void *, uint32_t, void **);
typedef void (*HandleRelease)(void *);
typedef HeifError (*Decode)(void *, void **, int, int, const void *);
typedef const uint8_t *(*Plane)(const void *, int, int *);
typedef int (*Dimension)(const void *, int);
typedef void (*ImageRelease)(void *);

enum { COLORSPACE_RGB = 1, CHROMA_RGBA = 11, CHANNEL_INTERLEAVED = 10 };

static void *heif_library(void) {
    static void *lib = NULL;
    static gsize once = 0;
    if (g_once_init_enter(&once)) {
        lib = dlopen("libheif.so.1", RTLD_NOW | RTLD_LOCAL);
        g_once_init_leave(&once, 1);
    }
    return lib;
}

gboolean singularity_heic_available(void) {
    return heif_library() != NULL;
}

static GdkPixbuf *frame_pixbuf(const uint8_t *data, int stride, int width, int height) {
    GdkPixbuf *pb = gdk_pixbuf_new(GDK_COLORSPACE_RGB, TRUE, 8, width, height);
    if (pb == NULL) return NULL;
    guchar *dst = gdk_pixbuf_get_pixels(pb);
    int dst_stride = gdk_pixbuf_get_rowstride(pb);
    for (int y = 0; y < height; y++) memcpy(dst + (gsize) y * dst_stride, data + (gsize) y * stride, (gsize) width * 4);
    return pb;
}

gchar **singularity_heic_decode_frames(const gchar *source, gint count, const gchar *dir, GError **error) {
    void *lib = heif_library();
    if (lib == NULL) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "libheif is not installed");
        return NULL;
    }
    ContextAlloc ctx_alloc = (ContextAlloc) dlsym(lib, "heif_context_alloc");
    ContextFree ctx_free = (ContextFree) dlsym(lib, "heif_context_free");
    ReadFromFile read_file = (ReadFromFile) dlsym(lib, "heif_context_read_from_file");
    ImageCount image_count = (ImageCount) dlsym(lib, "heif_context_get_number_of_top_level_images");
    ImageIds image_ids = (ImageIds) dlsym(lib, "heif_context_get_list_of_top_level_image_IDs");
    ImageHandle image_handle = (ImageHandle) dlsym(lib, "heif_context_get_image_handle");
    HandleRelease handle_release = (HandleRelease) dlsym(lib, "heif_image_handle_release");
    Decode decode = (Decode) dlsym(lib, "heif_decode_image");
    Plane plane = (Plane) dlsym(lib, "heif_image_get_plane_readonly");
    Dimension get_width = (Dimension) dlsym(lib, "heif_image_get_width");
    Dimension get_height = (Dimension) dlsym(lib, "heif_image_get_height");
    ImageRelease image_release = (ImageRelease) dlsym(lib, "heif_image_release");
    if (!ctx_alloc || !ctx_free || !read_file || !image_count || !image_ids || !image_handle || !handle_release
        || !decode || !plane || !get_width || !get_height || !image_release) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "libheif is missing required functions");
        return NULL;
    }
    void *ctx = ctx_alloc();
    HeifError err = read_file(ctx, source, NULL);
    if (err.code != 0) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "%s", err.message ? err.message : "unreadable HEIC file");
        ctx_free(ctx);
        return NULL;
    }
    int total = image_count(ctx);
    if (total < count) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "the file holds %d images, %d expected", total, count);
        ctx_free(ctx);
        return NULL;
    }
    uint32_t *ids = g_new0(uint32_t, total);
    image_ids(ctx, ids, total);
    GPtrArray *frames = g_ptr_array_new_with_free_func(g_free);
    gboolean ok = TRUE;
    for (int i = 0; i < count && ok; i++) {
        void *handle = NULL;
        void *img = NULL;
        err = image_handle(ctx, ids[i], &handle);
        if (err.code == 0) err = decode(handle, &img, COLORSPACE_RGB, CHROMA_RGBA, NULL);
        if (err.code != 0) {
            g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "frame %d: %s", i, err.message ? err.message : "decode failed");
            ok = FALSE;
        } else {
            int stride = 0;
            const uint8_t *data = plane(img, CHANNEL_INTERLEAVED, &stride);
            int w = get_width(img, CHANNEL_INTERLEAVED);
            int h = get_height(img, CHANNEL_INTERLEAVED);
            GdkPixbuf *pb = data && w > 0 && h > 0 ? frame_pixbuf(data, stride, w, h) : NULL;
            gchar *name = g_strdup_printf("frame-%02d.png", i);
            gchar *path = g_build_filename(dir, name, NULL);
            g_free(name);
            if (pb == NULL) {
                g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "frame %d has no pixels", i);
                ok = FALSE;
                g_free(path);
            } else if (!gdk_pixbuf_save(pb, path, "png", error, NULL)) {
                ok = FALSE;
                g_free(path);
            } else {
                g_ptr_array_add(frames, path);
            }
            if (pb) g_object_unref(pb);
        }
        if (img) image_release(img);
        if (handle) handle_release(handle);
    }
    g_free(ids);
    ctx_free(ctx);
    if (!ok) {
        g_ptr_array_free(frames, TRUE);
        return NULL;
    }
    g_ptr_array_add(frames, NULL);
    return (gchar **) g_ptr_array_free(frames, FALSE);
}
