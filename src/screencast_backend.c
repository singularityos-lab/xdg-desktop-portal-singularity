#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <pthread.h>

#include <glib.h>
#include <glib-unix.h>
#include <json-glib/json-glib.h>

#include <wayland-client.h>
#include "ext-foreign-toplevel-list-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/utils/defs.h>
#include <spa/buffer/meta.h>

#include "screencast_backend.h"

/* ─── Output entry ──────────────────────────────────────────────────────────── */

typedef struct OutputEntry {
    struct wl_output   *output;
    uint32_t            global_id;
    char               *name;
    int                 width, height;
    struct OutputEntry *next;
} OutputEntry;

typedef struct ToplevelEntry {
    struct ScreencastBackend                *backend;
    struct ext_foreign_toplevel_handle_v1 *handle;
    char                                  *identifier;
    char                                  *title;
    char                                  *app_id;
    struct ToplevelEntry                  *next;
} ToplevelEntry;

/* ─── Backend state ─────────────────────────────────────────────────────────── */

struct ScreencastBackend {
    /* Wayland */
    struct wl_display                                *display;
    struct wl_registry                               *registry;
    struct wl_shm                                    *shm;
    struct ext_output_image_capture_source_manager_v1 *source_manager;
    struct ext_foreign_toplevel_image_capture_source_manager_v1 *toplevel_source_manager;
    struct ext_image_copy_capture_manager_v1         *capture_manager;
    struct ext_foreign_toplevel_list_v1              *toplevel_list;
    guint                                             wl_source_id;

    /* Known sources (protected by outputs_mutex) */
    OutputEntry    *outputs;
    ToplevelEntry  *toplevels;
    pthread_mutex_t outputs_mutex;

    /* Active capture session */
    struct wl_output                         *capture_output;
    struct ext_foreign_toplevel_handle_v1    *capture_toplevel;
    struct ext_image_capture_source_v1       *current_source;
    struct ext_image_copy_capture_session_v1 *current_session;
    struct ext_image_copy_capture_frame_v1   *current_frame;
    uint64_t                                  capture_serial;
    guint                                     frame_retry_source_id;

    /* SHM capture buffer */
    struct wl_buffer   *shm_buffer;
    struct wl_shm_pool *shm_pool;
    void               *shm_data;
    int                 shm_fd;
    size_t              shm_size;
    uint32_t            frame_w, frame_h, frame_stride, frame_fmt;
    uint32_t            capture_fmt;
    uint32_t            capture_stride;
    uint32_t            capture_bpp;
    bool                buf_allocated;
    bool                constraints_received;
    bool                have_buffer_size;
    bool                have_shm_format;

    /* Latest captured frame (mutex-protected: written main thread, read PW thread) */
    pthread_mutex_t frame_mutex;
    void           *latest_data;
    size_t          latest_size;
    uint32_t        latest_w, latest_h, latest_stride;
    uint32_t        latest_fmt;
    bool            frame_ready;

    /* PipeWire */
    struct pw_main_loop *pw_loop;
    struct pw_context   *pw_context;
    struct pw_core      *pw_core;
    struct pw_stream    *pw_stream;
    struct spa_hook      stream_hook;
    uint32_t             node_id;
    uint64_t             seq;
    enum spa_video_format pw_format;
    uint32_t             pw_stride;
    uint32_t             pw_bpp;
    bool                 pw_setup_done;
    bool                 needs_pw_conversion;

    /* For OpenPipeWireRemote */
    struct pw_core *remote_core;

    /* Control */
    volatile bool running;
    guint         pw_source_id;
    bool          wayland_failed;
    bool          start_failed;
};

typedef struct FrameRetry {
    ScreencastBackend *backend;
    uint64_t serial;
} FrameRetry;

/* ─── Forward declarations ──────────────────────────────────────────────────── */

static void start_next_frame(ScreencastBackend *b);
static void setup_pw_stream(ScreencastBackend *b, uint32_t w, uint32_t h);
static void teardown_capture(ScreencastBackend *b);
static gboolean retry_start_next_frame(gpointer data);
static void mark_wayland_failed(ScreencastBackend *b, const char *context);

static const char *shm_format_name(uint32_t fmt) {
    switch (fmt) {
    case WL_SHM_FORMAT_ARGB8888: return "ARGB8888";
    case WL_SHM_FORMAT_XRGB8888: return "XRGB8888";
    case WL_SHM_FORMAT_ABGR8888: return "ABGR8888";
    case WL_SHM_FORMAT_XBGR8888: return "XBGR8888";
    case WL_SHM_FORMAT_RGB888:   return "RGB888";
    case WL_SHM_FORMAT_BGR888:   return "BGR888";
    default: return "unsupported";
    }
}

static bool shm_format_info(uint32_t fmt, uint32_t *bytes_per_pixel) {
    switch (fmt) {
    case WL_SHM_FORMAT_ARGB8888:
    case WL_SHM_FORMAT_XRGB8888:
    case WL_SHM_FORMAT_ABGR8888:
    case WL_SHM_FORMAT_XBGR8888:
        if (bytes_per_pixel) *bytes_per_pixel = 4;
        return true;
    case WL_SHM_FORMAT_RGB888:
    case WL_SHM_FORMAT_BGR888:
        if (bytes_per_pixel) *bytes_per_pixel = 3;
        return true;
    default:
        return false;
    }
}

static enum spa_video_format native_spa_format_for_shm(uint32_t fmt) {
    switch (fmt) {
    case WL_SHM_FORMAT_ARGB8888: return SPA_VIDEO_FORMAT_BGRA;
    case WL_SHM_FORMAT_XRGB8888: return SPA_VIDEO_FORMAT_BGRx;
    case WL_SHM_FORMAT_ABGR8888: return SPA_VIDEO_FORMAT_RGBA;
    case WL_SHM_FORMAT_XBGR8888: return SPA_VIDEO_FORMAT_RGBx;
    case WL_SHM_FORMAT_RGB888:   return SPA_VIDEO_FORMAT_RGB;
    case WL_SHM_FORMAT_BGR888:   return SPA_VIDEO_FORMAT_BGR;
    default:                     return SPA_VIDEO_FORMAT_UNKNOWN;
    }
}

static int shm_format_rank(uint32_t fmt) {
    switch (fmt) {
    case WL_SHM_FORMAT_XRGB8888:
    case WL_SHM_FORMAT_ARGB8888:
        return 30;
    case WL_SHM_FORMAT_XBGR8888:
    case WL_SHM_FORMAT_ABGR8888:
        return 20;
    case WL_SHM_FORMAT_BGR888:
    case WL_SHM_FORMAT_RGB888:
        return 10;
    default:
        return 0;
    }
}

static bool prefer_shm_format(uint32_t current, uint32_t candidate) {
    return shm_format_rank(candidate) > shm_format_rank(current);
}

static bool can_send_wayland_requests(ScreencastBackend *b) {
    return b && b->display && !b->wayland_failed &&
           wl_display_get_error(b->display) == 0;
}

static void destroy_proxy_local(void *proxy) {
    if (proxy) wl_proxy_destroy((struct wl_proxy *)proxy);
}

/* ─── wl_output listener ────────────────────────────────────────────────────── */

static void out_geometry(void *d, struct wl_output *o,
    int32_t x, int32_t y, int32_t pw, int32_t ph,
    int32_t sub, const char *make, const char *model, int32_t t) {}

static void out_mode(void *d, struct wl_output *o,
    uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    OutputEntry *e = d;
    if (flags & WL_OUTPUT_MODE_CURRENT) { e->width = w; e->height = h; }
}

static void out_done(void *d, struct wl_output *o) {}
static void out_scale(void *d, struct wl_output *o, int32_t s) {}

static void out_name(void *d, struct wl_output *o, const char *name) {
    OutputEntry *e = d;
    free(e->name);
    e->name = strdup(name);
}

static void out_desc(void *d, struct wl_output *o, const char *desc) {}

static const struct wl_output_listener output_listener = {
    .geometry    = out_geometry,
    .mode        = out_mode,
    .done        = out_done,
    .scale       = out_scale,
    .name        = out_name,
    .description = out_desc,
};

/* ─── wl_registry listener ──────────────────────────────────────────────────── */

static void toplevel_entry_free(ToplevelEntry *e, bool send_destroy) {
    if (!e) return;
    if (e->handle) {
        if (send_destroy)
            ext_foreign_toplevel_handle_v1_destroy(e->handle);
        else
            destroy_proxy_local(e->handle);
    }
    free(e->identifier);
    free(e->title);
    free(e->app_id);
    free(e);
}

static void tl_handle_closed(void *data, struct ext_foreign_toplevel_handle_v1 *handle) {
    ToplevelEntry *closed = data;
    ScreencastBackend *b = closed->backend;
    pthread_mutex_lock(&b->outputs_mutex);
    for (ToplevelEntry **p = &b->toplevels; *p; p = &(*p)->next) {
        if ((*p)->handle == handle) {
            ToplevelEntry *e = *p;
            *p = e->next;
            toplevel_entry_free(e, true);
            break;
        }
    }
    pthread_mutex_unlock(&b->outputs_mutex);
}

static void tl_handle_done(void *data, struct ext_foreign_toplevel_handle_v1 *handle) {}

static void tl_handle_title(void *data, struct ext_foreign_toplevel_handle_v1 *handle,
    const char *title) {
    ToplevelEntry *e = data;
    free(e->title);
    e->title = strdup(title ? title : "");
}

static void tl_handle_app_id(void *data, struct ext_foreign_toplevel_handle_v1 *handle,
    const char *app_id) {
    ToplevelEntry *e = data;
    free(e->app_id);
    e->app_id = strdup(app_id ? app_id : "");
}

static void tl_handle_identifier(void *data, struct ext_foreign_toplevel_handle_v1 *handle,
    const char *identifier) {
    ToplevelEntry *e = data;
    free(e->identifier);
    e->identifier = strdup(identifier ? identifier : "");
}

static const struct ext_foreign_toplevel_handle_v1_listener toplevel_handle_listener = {
    .closed     = tl_handle_closed,
    .done       = tl_handle_done,
    .title      = tl_handle_title,
    .app_id     = tl_handle_app_id,
    .identifier = tl_handle_identifier,
};

static void tl_list_toplevel(void *data, struct ext_foreign_toplevel_list_v1 *list,
    struct ext_foreign_toplevel_handle_v1 *handle) {
    ScreencastBackend *b = data;
    ToplevelEntry *e = calloc(1, sizeof(*e));
    if (!e) {
        ext_foreign_toplevel_handle_v1_destroy(handle);
        return;
    }
    e->backend = b;
    e->handle = handle;
    ext_foreign_toplevel_handle_v1_add_listener(handle, &toplevel_handle_listener, e);

    pthread_mutex_lock(&b->outputs_mutex);
    e->next = b->toplevels;
    b->toplevels = e;
    pthread_mutex_unlock(&b->outputs_mutex);
}

static void tl_list_finished(void *data, struct ext_foreign_toplevel_list_v1 *list) {
    ScreencastBackend *b = data;
    if (b->toplevel_list == list)
        b->toplevel_list = NULL;
    ext_foreign_toplevel_list_v1_destroy(list);
}

static const struct ext_foreign_toplevel_list_v1_listener toplevel_list_listener = {
    .toplevel = tl_list_toplevel,
    .finished = tl_list_finished,
};

static void reg_global(void *data, struct wl_registry *reg,
    uint32_t id, const char *iface, uint32_t ver) {
    ScreencastBackend *b = data;

    if (strcmp(iface, wl_shm_interface.name) == 0) {
        b->shm = wl_registry_bind(reg, id, &wl_shm_interface, 1);
    } else if (strcmp(iface, ext_output_image_capture_source_manager_v1_interface.name) == 0) {
        b->source_manager = wl_registry_bind(reg, id,
            &ext_output_image_capture_source_manager_v1_interface, 1);
    } else if (strcmp(iface, ext_foreign_toplevel_image_capture_source_manager_v1_interface.name) == 0) {
        b->toplevel_source_manager = wl_registry_bind(reg, id,
            &ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1);
    } else if (strcmp(iface, ext_image_copy_capture_manager_v1_interface.name) == 0) {
        b->capture_manager = wl_registry_bind(reg, id,
            &ext_image_copy_capture_manager_v1_interface, 1);
    } else if (strcmp(iface, ext_foreign_toplevel_list_v1_interface.name) == 0) {
        b->toplevel_list = wl_registry_bind(reg, id,
            &ext_foreign_toplevel_list_v1_interface, 1);
        ext_foreign_toplevel_list_v1_add_listener(b->toplevel_list,
            &toplevel_list_listener, b);
    } else if (strcmp(iface, wl_output_interface.name) == 0) {
        uint32_t bv = ver >= 4 ? 4 : ver;
        struct wl_output *out = wl_registry_bind(reg, id, &wl_output_interface, bv);
        OutputEntry *e = calloc(1, sizeof(*e));
        e->output    = out;
        e->global_id = id;
        wl_output_add_listener(out, &output_listener, e);
        pthread_mutex_lock(&b->outputs_mutex);
        e->next    = b->outputs;
        b->outputs = e;
        pthread_mutex_unlock(&b->outputs_mutex);
    }
}

static void reg_global_remove(void *data, struct wl_registry *reg, uint32_t id) {
    ScreencastBackend *b = data;
    pthread_mutex_lock(&b->outputs_mutex);
    for (OutputEntry **p = &b->outputs; *p; p = &(*p)->next) {
        if ((*p)->global_id == id) {
            OutputEntry *e = *p;
            *p = e->next;
            wl_output_destroy(e->output);
            free(e->name);
            free(e);
            break;
        }
    }
    pthread_mutex_unlock(&b->outputs_mutex);
}

static const struct wl_registry_listener registry_listener = {
    .global        = reg_global,
    .global_remove = reg_global_remove,
};

/* ─── SHM buffer helpers ────────────────────────────────────────────────────── */

static int create_shm_fd(size_t sz) {
    int fd = memfd_create("sc-shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) return -1;
    if (ftruncate(fd, sz) < 0) { close(fd); return -1; }
    return fd;
}

static bool alloc_shm_buffer(ScreencastBackend *b,
    uint32_t w, uint32_t h, uint32_t stride, uint32_t fmt) {
    if (b->shm_buffer)  { wl_buffer_destroy(b->shm_buffer);    b->shm_buffer = NULL; }
    if (b->shm_pool)    { wl_shm_pool_destroy(b->shm_pool);    b->shm_pool   = NULL; }
    if (b->shm_data)    { munmap(b->shm_data, b->shm_size);    b->shm_data   = NULL; }
    if (b->shm_fd >= 0) { close(b->shm_fd);                    b->shm_fd     = -1;   }

    b->shm_size = (size_t)stride * h;
    b->shm_fd   = create_shm_fd(b->shm_size);
    if (b->shm_fd < 0) return false;

    b->shm_data = mmap(NULL, b->shm_size, PROT_READ | PROT_WRITE,
                       MAP_SHARED, b->shm_fd, 0);
    if (b->shm_data == MAP_FAILED) {
        b->shm_data = NULL; close(b->shm_fd); b->shm_fd = -1; return false;
    }

    b->shm_pool   = wl_shm_create_pool(b->shm, b->shm_fd, (int32_t)b->shm_size);
    b->shm_buffer = wl_shm_pool_create_buffer(b->shm_pool, 0,
                        (int32_t)w, (int32_t)h, (int32_t)stride, fmt);

    b->frame_w = w; b->frame_h = h;
    b->frame_stride = stride; b->frame_fmt = fmt;
    b->capture_stride = stride; b->capture_fmt = fmt;
    b->buf_allocated = true;
    return true;
}

/* ─── ext_image_copy_capture_frame_v1 listener ─────────────────────────────── */

static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f) {
    ScreencastBackend *b = data;
    if (f != b->current_frame) {
        g_message("screencast: ignoring stale frame ready event");
        return;
    }
    size_t sz = (size_t)b->frame_stride * b->frame_h;

    pthread_mutex_lock(&b->frame_mutex);
    if (b->latest_size < sz) {
        free(b->latest_data);
        b->latest_data = malloc(sz);
        b->latest_size = b->latest_data ? sz : 0;
    }
    if (b->latest_data && b->shm_data) {
        memcpy(b->latest_data, b->shm_data, sz);
        b->latest_w      = b->frame_w;
        b->latest_h      = b->frame_h;
        b->latest_stride = b->frame_stride;
        b->latest_fmt    = b->capture_fmt;
        b->frame_ready   = true;
    }
    pthread_mutex_unlock(&b->frame_mutex);

    if (b->pw_stream) pw_stream_trigger_process(b->pw_stream);

    if (b->current_frame) {
        ext_image_copy_capture_frame_v1_destroy(b->current_frame);
        b->current_frame = NULL;
    }
    if (b->running) start_next_frame(b);
}

static void frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *f, uint32_t reason) {
    ScreencastBackend *b = data;
    (void) reason;
    if (f != b->current_frame) {
        g_message("screencast: ignoring stale frame failed event");
        return;
    }
    if (b->current_frame) {
        ext_image_copy_capture_frame_v1_destroy(b->current_frame);
        b->current_frame = NULL;
    }
    if (b->running && !b->frame_retry_source_id) {
        FrameRetry *retry = g_new0(FrameRetry, 1);
        retry->backend = b;
        retry->serial = b->capture_serial;
        b->frame_retry_source_id = g_timeout_add_full(G_PRIORITY_DEFAULT, 100,
            retry_start_next_frame, retry, g_free);
        g_message("screencast: scheduled frame retry");
    }
}

static void frame_transform(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t transform) {
    ScreencastBackend *b = d;
    if (f != b->current_frame) return;
}
static void frame_damage(void *d, struct ext_image_copy_capture_frame_v1 *f,
    int32_t x, int32_t y, int32_t w, int32_t h) {
    ScreencastBackend *b = d;
    if (f != b->current_frame) return;
}
static void frame_presentation_time(void *d, struct ext_image_copy_capture_frame_v1 *f,
    uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {
    ScreencastBackend *b = d;
    if (f != b->current_frame) return;
}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
    .ready             = frame_ready,
    .failed            = frame_failed,
    .transform         = frame_transform,
    .damage            = frame_damage,
    .presentation_time = frame_presentation_time,
};

/* ─── ext_image_copy_capture_session_v1 listener ─────────────────────────────── */

static void session_buffer_size(void *data, struct ext_image_copy_capture_session_v1 *session,
    uint32_t w, uint32_t h) {
    ScreencastBackend *b = data;
    if (session != b->current_session) {
        g_message("screencast: ignoring stale session buffer_size event");
        return;
    }
    b->frame_w = w;
    b->frame_h = h;
    b->have_buffer_size = true;
    g_message("screencast: buffer constraints %ux%u", w, h);
}

static void session_shm_format(void *data, struct ext_image_copy_capture_session_v1 *session,
    uint32_t format) {
    ScreencastBackend *b = data;
    if (session != b->current_session) {
        g_message("screencast: ignoring stale session shm_format event");
        return;
    }

    uint32_t bytes_per_pixel = 0;
    if (!shm_format_info(format, &bytes_per_pixel)) {
        g_message("screencast: ignoring unsupported shm format 0x%x", format);
        return;
    }

    if (!b->have_shm_format || prefer_shm_format(b->capture_fmt, format)) {
        b->capture_fmt = format;
        b->capture_bpp = bytes_per_pixel;
        b->frame_fmt = format;
        b->have_shm_format = true;
        g_message("screencast: selected shm format %s (0x%x)",
            shm_format_name(format), format);
    }
}

static void session_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *session,
    struct wl_array *device) {}
static void session_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *session,
    uint32_t format, struct wl_array *modifiers) {}

static void session_done(void *data, struct ext_image_copy_capture_session_v1 *session) {
    ScreencastBackend *b = data;
    if (session != b->current_session) {
        g_message("screencast: ignoring stale session done event");
        return;
    }
    if (!b->constraints_received) {
        b->constraints_received = true;

        if (!b->have_buffer_size || b->frame_w == 0 || b->frame_h == 0) {
            g_warning("screencast: capture failed: missing/invalid buffer size");
            b->start_failed = true;
            b->running = false;
            return;
        }
        if (!b->have_shm_format) {
            g_warning("screencast: capture failed: no supported shm format");
            b->start_failed = true;
            b->running = false;
            return;
        }

        uint32_t bytes_per_pixel = 0;
        if (!shm_format_info(b->capture_fmt, &bytes_per_pixel) || bytes_per_pixel == 0) {
            g_warning("screencast: capture failed: invalid selected shm format %s (0x%x)",
                shm_format_name(b->capture_fmt), b->capture_fmt);
            b->start_failed = true;
            b->running = false;
            return;
        }

        b->capture_bpp = bytes_per_pixel;
        b->capture_stride = b->frame_w * b->capture_bpp;
        b->frame_stride = b->capture_stride;
        b->frame_fmt = b->capture_fmt;
        b->pw_format = SPA_VIDEO_FORMAT_BGRx;
        b->pw_bpp = 4;
        b->pw_stride = b->frame_w * b->pw_bpp;
        b->needs_pw_conversion =
            native_spa_format_for_shm(b->capture_fmt) != b->pw_format ||
            b->capture_stride != b->pw_stride;

        g_message("screencast: selected shm format %s (0x%x), capture_stride=%u",
            shm_format_name(b->capture_fmt), b->capture_fmt, b->capture_stride);
        g_message("screencast: publishing PipeWire format BGRx, pw_stride=%u",
            b->pw_stride);

        if (alloc_shm_buffer(b, b->frame_w, b->frame_h, b->capture_stride, b->capture_fmt)) {
            if (!b->pw_setup_done) setup_pw_stream(b, b->frame_w, b->frame_h);
            if (b->running) start_next_frame(b);
        } else {
            g_message ("screencast: alloc_shm_buffer failed (%ux%u)", b->frame_w, b->frame_h);
            b->start_failed = true;
            b->running = false;
        }
    }
}

static void session_stopped(void *data, struct ext_image_copy_capture_session_v1 *session) {
    ScreencastBackend *b = data;
    if (session != b->current_session) {
        g_message("screencast: ignoring stale session stopped event");
        return;
    }
    b->running = false;
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    .buffer_size   = session_buffer_size,
    .shm_format    = session_shm_format,
    .dmabuf_device = session_dmabuf_device,
    .dmabuf_format = session_dmabuf_format,
    .done          = session_done,
    .stopped       = session_stopped,
};

/* ─── Start next capture frame ───────────────────────────────────────────── */

static void start_next_frame(ScreencastBackend *b) {
    if (!b || b->wayland_failed || !b->running || !b->current_session ||
        !b->shm_buffer || b->current_frame)
        return;
    b->current_frame = ext_image_copy_capture_session_v1_create_frame(b->current_session);
    if (!b->current_frame) return;
    ext_image_copy_capture_frame_v1_add_listener(b->current_frame, &frame_listener, b);
    ext_image_copy_capture_frame_v1_attach_buffer(b->current_frame, b->shm_buffer);
    ext_image_copy_capture_frame_v1_damage_buffer(b->current_frame, 0, 0, (int32_t)b->frame_w, (int32_t)b->frame_h);
    ext_image_copy_capture_frame_v1_capture(b->current_frame);
    if (wl_display_flush(b->display) < 0 && errno != EAGAIN)
        mark_wayland_failed(b, "start next frame flush");
}

static gboolean retry_start_next_frame(gpointer data) {
    FrameRetry *retry = data;
    ScreencastBackend *b = retry->backend;

    if (b->frame_retry_source_id)
        b->frame_retry_source_id = 0;

    if (retry->serial != b->capture_serial) {
        g_message("screencast: cancelled stale frame retry");
        return G_SOURCE_REMOVE;
    }

    if (b->running && b->current_session)
        start_next_frame(b);

    return G_SOURCE_REMOVE;
}

/* ─── PipeWire stream callbacks ─────────────────────────────────────────────── */

static void pw_state_changed(void *data, enum pw_stream_state old,
    enum pw_stream_state state, const char *error) {
    ScreencastBackend *b = data;
    if (!b->pw_stream) return;
    if (state == PW_STREAM_STATE_ERROR)
        g_warning ("screencast: pipewire stream error: %s", error ? error : "unknown");
    if ((state == PW_STREAM_STATE_PAUSED || state == PW_STREAM_STATE_STREAMING)
        && b->node_id == SPA_ID_INVALID) {
        uint32_t nid = pw_stream_get_node_id(b->pw_stream);
        if (nid != SPA_ID_INVALID) {
            b->node_id = nid;
            g_message("screencast: acquired PipeWire node id %u", nid);
        }
    }
}

static void pw_param_changed(void *data, uint32_t id,
    const struct spa_pod *param) {
    ScreencastBackend *b = data;
    if (!b->pw_stream) return;
    if (!param || id != SPA_PARAM_Format) return;

    struct spa_video_info_raw vi;
    if (spa_format_video_raw_parse(param, &vi) < 0) return;

    uint32_t stride = b->pw_stride ? b->pw_stride : SPA_ROUND_UP_N(vi.size.width * 4, 4);
    uint32_t sz     = stride * vi.size.height;

    uint8_t pbuf[512];
    struct spa_pod_builder pod = SPA_POD_BUILDER_INIT(pbuf, sizeof(pbuf));
    const struct spa_pod *params[2];

    params[0] = spa_pod_builder_add_object(&pod,
        SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers,  SPA_POD_CHOICE_RANGE_Int(2, 1, 8),
        SPA_PARAM_BUFFERS_blocks,   SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_size,     SPA_POD_Int((int)sz),
        SPA_PARAM_BUFFERS_stride,   SPA_POD_Int((int)stride),
        SPA_PARAM_BUFFERS_align,    SPA_POD_Int(16),
        // dataType must be a CHOICE (flags), not a plain Int, or PipeWire
        // rejects the params ("alloc buffers: Invalid argument"). Use MemFd:
        // the buffers are shared with the consumer process (Chrome), so they
        // must be a shareable fd, not a process-local MemPtr.
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(1 << SPA_DATA_MemFd));

    params[1] = spa_pod_builder_add_object(&pod,
        SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));

    pw_stream_update_params(b->pw_stream, params, 2);
}

static bool copy_frame_to_pw_buffer(ScreencastBackend *b, uint8_t *dst, size_t dst_max) {
    if (!b->latest_data || !dst || !b->latest_w || !b->latest_h)
        return false;

    uint32_t src_bpp = 0;
    if (!shm_format_info(b->latest_fmt, &src_bpp) ||
        b->latest_stride < b->latest_w * src_bpp)
        return false;

    size_t dst_size = (size_t)b->pw_stride * b->latest_h;
    if (!b->pw_stride || dst_size > dst_max)
        return false;

    const uint8_t *src_base = b->latest_data;
    for (uint32_t y = 0; y < b->latest_h; y++) {
        const uint8_t *src = src_base + (size_t)y * b->latest_stride;
        uint8_t *row = dst + (size_t)y * b->pw_stride;

        for (uint32_t x = 0; x < b->latest_w; x++) {
            uint8_t *px = row + (size_t)x * 4;

            switch (b->latest_fmt) {
            case WL_SHM_FORMAT_BGR888:
                /* BGR888 is R,G,B in little-endian memory; publish B,G,R,x. */
                px[0] = src[2];
                px[1] = src[1];
                px[2] = src[0];
                px[3] = 0xff;
                src += 3;
                break;
            case WL_SHM_FORMAT_RGB888:
                /* RGB888 is B,G,R in little-endian memory; publish B,G,R,x. */
                px[0] = src[0];
                px[1] = src[1];
                px[2] = src[2];
                px[3] = 0xff;
                src += 3;
                break;
            case WL_SHM_FORMAT_ARGB8888:
            case WL_SHM_FORMAT_XRGB8888:
                px[0] = src[0];
                px[1] = src[1];
                px[2] = src[2];
                px[3] = 0xff;
                src += 4;
                break;
            case WL_SHM_FORMAT_ABGR8888:
            case WL_SHM_FORMAT_XBGR8888:
                px[0] = src[2];
                px[1] = src[1];
                px[2] = src[0];
                px[3] = 0xff;
                src += 4;
                break;
            default:
                return false;
            }
        }
    }

    return true;
}

static void pw_process(void *data) {
    ScreencastBackend *b = data;
    if (!b->pw_stream) return;

    struct pw_buffer *pwb = pw_stream_dequeue_buffer(b->pw_stream);
    if (!pwb) return;

    struct spa_data *d = &pwb->buffer->datas[0];

    if (pthread_mutex_trylock(&b->frame_mutex) == 0) {
        size_t copy_sz = (size_t)b->pw_stride * b->latest_h;
        if (d->data && b->frame_ready &&
            copy_frame_to_pw_buffer(b, d->data, d->maxsize)) {
            d->chunk->offset = 0;
            d->chunk->stride = (int32_t)b->pw_stride;
            d->chunk->size   = (uint32_t)copy_sz;
        }
        pthread_mutex_unlock(&b->frame_mutex);
    }

    // Fill the buffer header with a timestamp/sequence. Without a valid pts
    // the consumer (Chrome/WebRTC) drops frames and keeps restarting the
    // stream, so nothing is ever displayed.
    struct spa_meta_header *h =
        spa_buffer_find_meta_data (pwb->buffer, SPA_META_Header, sizeof (*h));
    if (h) {
        struct timespec ts;
        clock_gettime (CLOCK_MONOTONIC, &ts);
        h->pts        = SPA_TIMESPEC_TO_NSEC (&ts);
        h->flags      = 0;
        h->seq        = b->seq++;
        h->dts_offset = 0;
    }

    pw_stream_queue_buffer(b->pw_stream, pwb);
}

// With PW_STREAM_FLAG_ALLOC_BUFFERS we provide the buffer memory. Back each
// buffer with a shared memfd so the consumer (Chrome, another process) can
// actually read the frames; MAP_BUFFERS gave process-local MemPtr buffers
// that Chrome could not see, hence the blank stream.
static void pw_add_buffer(void *data, struct pw_buffer *pwb) {
    ScreencastBackend *b = data;
    struct spa_data *d = &pwb->buffer->datas[0];
    uint32_t stride = b->pw_stride ? b->pw_stride : b->frame_w * 4;
    size_t size = (size_t)stride * b->frame_h;
    int fd = create_shm_fd(size);
    if (fd < 0) { g_message ("screencast: add_buffer: memfd alloc failed"); return; }
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (ptr == MAP_FAILED) { close(fd); return; }
    d->type          = SPA_DATA_MemFd;
    d->flags         = SPA_DATA_FLAG_READABLE;
    d->fd            = fd;
    d->mapoffset     = 0;
    d->maxsize       = (uint32_t)size;
    d->data          = ptr;
    d->chunk->offset = 0;
    d->chunk->stride = (int32_t)stride;
    d->chunk->size   = 0;
}

static void pw_remove_buffer(void *data, struct pw_buffer *pwb) {
    (void) data;
    struct spa_data *d = &pwb->buffer->datas[0];
    if (d->data && d->maxsize) munmap(d->data, d->maxsize);
    if ((int) d->fd >= 0) close((int) d->fd);
    d->data = NULL;
    d->fd   = -1;
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = pw_state_changed,
    .param_changed = pw_param_changed,
    .add_buffer    = pw_add_buffer,
    .remove_buffer = pw_remove_buffer,
    .process       = pw_process,
};

/* ─── PipeWire stream setup ──────────────── */

static void setup_pw_stream(ScreencastBackend *b,
    uint32_t w, uint32_t h) {
    if (b->pw_setup_done || !b->pw_core) return;
    b->pw_setup_done = true;

    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_CLASS,      "Video/Source",
        PW_KEY_NODE_NAME,        "singularity-screencast",
        PW_KEY_NODE_DESCRIPTION, "Singularity Desktop ScreenCast",
        NULL);

    b->pw_stream = pw_stream_new(b->pw_core, "Singularity ScreenCast", props);
    pw_stream_add_listener(b->pw_stream, &b->stream_hook, &stream_events, b);

    uint8_t pbuf[256];
    struct spa_pod_builder pod = SPA_POD_BUILDER_INIT(pbuf, sizeof(pbuf));
    struct spa_rectangle sz  = { w, h };
    // Variable framerate: a screencast source delivers frames on demand, not
    // at a fixed rate, so we advertise 0/1 and rely on per-buffer timestamps.
    // Declaring a fixed 30/1 made the WebRTC consumer expect a steady cadence
    // and drop our irregularly-timed frames, showing a blank stream.
    struct spa_fraction  fps     = { 0, 1 };
    struct spa_fraction  fps_min = { 1, 1 };
    struct spa_fraction  fps_max = { 60, 1 };
    enum spa_video_format spa_fmt = b->pw_format == SPA_VIDEO_FORMAT_UNKNOWN
        ? SPA_VIDEO_FORMAT_BGRx : b->pw_format;
    const struct spa_pod *params[1];

    params[0] = spa_pod_builder_add_object(&pod,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType,        SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype,     SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format,     SPA_POD_Id(spa_fmt),
        SPA_FORMAT_VIDEO_size,       SPA_POD_Rectangle(&sz),
        SPA_FORMAT_VIDEO_framerate,  SPA_POD_Fraction(&fps),
        SPA_FORMAT_VIDEO_maxFramerate,
            SPA_POD_CHOICE_RANGE_Fraction(&fps_max, &fps_min, &fps_max));

    pw_stream_connect(b->pw_stream,
        PW_DIRECTION_OUTPUT,
        PW_ID_ANY,
        PW_STREAM_FLAG_ALLOC_BUFFERS,
        params, 1);
}

static void mark_wayland_failed(ScreencastBackend *b, const char *context) {
    if (!b || b->wayland_failed) return;

    int err = b->display ? wl_display_get_error(b->display) : 0;
    b->wayland_failed = true;
    b->start_failed = true;
    b->running = false;
    g_warning("screencast: Wayland connection failed in %s%s%s",
        context ? context : "unknown",
        err ? ": " : "",
        err ? strerror(err) : "");
}

static bool check_wayland_error(ScreencastBackend *b, const char *context) {
    if (!b || !b->display) return false;
    if (wl_display_get_error(b->display) != 0) {
        mark_wayland_failed(b, context);
        return true;
    }
    return false;
}

/* ─── GLib IO callback ─────────────────────────────────── */

static gboolean on_wl_io(int fd, GIOCondition cond, gpointer data) {
    (void) fd;
    ScreencastBackend *b = data;
    if (cond & (G_IO_ERR | G_IO_HUP)) {
        mark_wayland_failed(b, "Wayland fd");
        b->wl_source_id = 0;
        return G_SOURCE_REMOVE;
    }

    while (wl_display_prepare_read(b->display) != 0) {
        if (wl_display_dispatch_pending(b->display) < 0) {
            mark_wayland_failed(b, "dispatch pending");
            b->wl_source_id = 0;
            return G_SOURCE_REMOVE;
        }
    }

    if (wl_display_read_events(b->display) < 0) {
        mark_wayland_failed(b, "read events");
        b->wl_source_id = 0;
        return G_SOURCE_REMOVE;
    }

    if (wl_display_dispatch_pending(b->display) < 0) {
        mark_wayland_failed(b, "dispatch after read");
        b->wl_source_id = 0;
        return G_SOURCE_REMOVE;
    }

    if (wl_display_flush(b->display) < 0 && errno != EAGAIN) {
        mark_wayland_failed(b, "flush");
        b->wl_source_id = 0;
        return G_SOURCE_REMOVE;
    }

    if (check_wayland_error(b, "event processing")) {
        b->wl_source_id = 0;
        return G_SOURCE_REMOVE;
    }

    return G_SOURCE_CONTINUE;
}

/* ─── PipeWire loop driven from the GLib main loop ───────────────────────────── */

static gboolean on_pw_io(int fd, GIOCondition cond, gpointer data) {
    (void) fd; (void) cond;
    ScreencastBackend *b = data;
    struct pw_loop *l = pw_main_loop_get_loop(b->pw_loop);
    pw_loop_enter(l);
    pw_loop_iterate(l, 0);
    pw_loop_leave(l);
    return G_SOURCE_CONTINUE;
}

static void teardown_capture(ScreencastBackend *b) {
    if (!b) return;

    g_message("screencast: tearing down capture");
    b->running = false;
    b->capture_serial++;
    bool send_wayland_destroy = can_send_wayland_requests(b);

    if (b->frame_retry_source_id) {
        g_source_remove(b->frame_retry_source_id);
        b->frame_retry_source_id = 0;
        g_message("screencast: cancelled pending frame retry");
    }

    if (b->current_frame) {
        if (send_wayland_destroy)
            ext_image_copy_capture_frame_v1_destroy(b->current_frame);
        else
            destroy_proxy_local(b->current_frame);
        b->current_frame = NULL;
    }
    if (b->current_session) {
        if (send_wayland_destroy)
            ext_image_copy_capture_session_v1_destroy(b->current_session);
        else
            destroy_proxy_local(b->current_session);
        b->current_session = NULL;
    }
    if (b->current_source) {
        if (send_wayland_destroy)
            ext_image_capture_source_v1_destroy(b->current_source);
        else
            destroy_proxy_local(b->current_source);
        b->current_source = NULL;
    }
    if (b->pw_stream) {
        pw_stream_disconnect(b->pw_stream);
        pw_stream_destroy(b->pw_stream);
        b->pw_stream = NULL;
    }

    if (b->shm_buffer) {
        if (send_wayland_destroy)
            wl_buffer_destroy(b->shm_buffer);
        else
            destroy_proxy_local(b->shm_buffer);
        b->shm_buffer = NULL;
    }
    if (b->shm_pool) {
        if (send_wayland_destroy)
            wl_shm_pool_destroy(b->shm_pool);
        else
            destroy_proxy_local(b->shm_pool);
        b->shm_pool = NULL;
    }
    if (b->shm_data) {
        munmap(b->shm_data, b->shm_size);
        b->shm_data = NULL;
    }
    if (b->shm_fd >= 0) {
        close(b->shm_fd);
        b->shm_fd = -1;
    }

    b->capture_output = NULL;
    b->capture_toplevel = NULL;
    b->pw_setup_done = false;
    b->node_id = SPA_ID_INVALID;
    b->frame_ready = false;
    b->constraints_received = false;
    b->have_buffer_size = false;
    b->have_shm_format = false;
    b->buf_allocated = false;
    b->shm_size = 0;
    b->frame_w = 0;
    b->frame_h = 0;
    b->frame_stride = 0;
    b->frame_fmt = 0;
    b->capture_fmt = 0;
    b->capture_stride = 0;
    b->capture_bpp = 0;
    b->pw_format = SPA_VIDEO_FORMAT_UNKNOWN;
    b->pw_stride = 0;
    b->pw_bpp = 0;
    b->needs_pw_conversion = false;

    pthread_mutex_lock(&b->frame_mutex);
    b->latest_w = 0;
    b->latest_h = 0;
    b->latest_stride = 0;
    b->latest_fmt = 0;
    pthread_mutex_unlock(&b->frame_mutex);
}

/* ─── Public API ────────────────────────────────────────────────────────────── */

ScreencastBackend *screencast_backend_new(void) {
    pw_init(NULL, NULL);

    ScreencastBackend *b = calloc(1, sizeof(*b));
    if (!b) return NULL;

    pthread_mutex_init(&b->outputs_mutex, NULL);
    pthread_mutex_init(&b->frame_mutex,   NULL);
    b->shm_fd  = -1;
    b->node_id = SPA_ID_INVALID;
    b->running = true;

    b->display = wl_display_connect(NULL);
    if (!b->display) {
        fprintf(stderr, "screencast_backend: failed to connect to Wayland\n");
        goto fail;
    }

    b->registry = wl_display_get_registry(b->display);
    wl_registry_add_listener(b->registry, &registry_listener, b);
    if (wl_display_roundtrip(b->display) < 0 ||
        wl_display_roundtrip(b->display) < 0) {
        fprintf(stderr, "screencast_backend: Wayland registry roundtrip failed\n");
        goto fail;
    }

    if (!b->shm || !b->capture_manager ||
        (!b->source_manager && !b->toplevel_source_manager)) {
        fprintf(stderr, "screencast_backend: compositor missing required protocols"
                        " (ext-image-capture-source or ext-image-copy-capture)\n");
        goto fail;
    }

    b->wl_source_id = g_unix_fd_add(wl_display_get_fd(b->display),
                                    G_IO_IN | G_IO_ERR | G_IO_HUP,
                                    on_wl_io, b);

    b->pw_loop = pw_main_loop_new(NULL);
    if (!b->pw_loop) {
        fprintf(stderr, "screencast_backend: failed to create PipeWire loop\n");
        goto fail;
    }

    b->pw_context = pw_context_new(pw_main_loop_get_loop(b->pw_loop), NULL, 0);
    b->pw_core    = pw_context_connect(b->pw_context, NULL, 0);

    // Drive the PipeWire loop from the daemon's GLib main loop instead of a
    // separate thread. Stream creation/connect then runs on the same thread
    // that iterates the loop, so the stream negotiates and yields a node id;
    // the previous cross-thread setup left it stuck before PAUSED.
    {
        struct pw_loop *l = pw_main_loop_get_loop(b->pw_loop);
        b->pw_source_id = g_unix_fd_add(pw_loop_get_fd(l),
                                        G_IO_IN | G_IO_ERR | G_IO_HUP,
                                        on_pw_io, b);
    }
    return b;

fail:
    screencast_backend_free(b);
    return NULL;
}

void screencast_backend_free(ScreencastBackend *b) {
    if (!b) return;
    teardown_capture(b);
    bool send_wayland_destroy = can_send_wayland_requests(b);

    if (b->wl_source_id) {
        g_source_remove(b->wl_source_id);
        b->wl_source_id = 0;
    }

    if (b->pw_source_id) { g_source_remove(b->pw_source_id); b->pw_source_id = 0; }

    if (b->remote_core) { pw_core_disconnect(b->remote_core); b->remote_core = NULL; }
    if (b->pw_core)     { pw_core_disconnect(b->pw_core);     b->pw_core     = NULL; }
    if (b->pw_context)  { pw_context_destroy(b->pw_context);  b->pw_context  = NULL; }
    if (b->pw_loop)     { pw_main_loop_destroy(b->pw_loop);   b->pw_loop     = NULL; }

    if (b->shm_buffer) {
        if (send_wayland_destroy)
            wl_buffer_destroy(b->shm_buffer);
        else
            destroy_proxy_local(b->shm_buffer);
    }
    if (b->shm_pool) {
        if (send_wayland_destroy)
            wl_shm_pool_destroy(b->shm_pool);
        else
            destroy_proxy_local(b->shm_pool);
    }
    if (b->shm_data)   munmap(b->shm_data, b->shm_size);
    if (b->shm_fd >= 0) close(b->shm_fd);
    free(b->latest_data);

    pthread_mutex_lock(&b->outputs_mutex);
    OutputEntry *e = b->outputs;
    while (e) {
        OutputEntry *next = e->next;
        if (e->output) {
            if (send_wayland_destroy)
                wl_output_destroy(e->output);
            else
                destroy_proxy_local(e->output);
        }
        free(e->name);
        free(e);
        e = next;
    }
    ToplevelEntry *t = b->toplevels;
    while (t) {
        ToplevelEntry *next = t->next;
        toplevel_entry_free(t, send_wayland_destroy);
        t = next;
    }
    pthread_mutex_unlock(&b->outputs_mutex);
    pthread_mutex_destroy(&b->outputs_mutex);
    pthread_mutex_destroy(&b->frame_mutex);

    if (b->shm) {
        if (send_wayland_destroy) wl_shm_destroy(b->shm);
        else destroy_proxy_local(b->shm);
    }
    if (b->source_manager) {
        if (send_wayland_destroy)
            ext_output_image_capture_source_manager_v1_destroy(b->source_manager);
        else
            destroy_proxy_local(b->source_manager);
    }
    if (b->toplevel_source_manager) {
        if (send_wayland_destroy)
            ext_foreign_toplevel_image_capture_source_manager_v1_destroy(b->toplevel_source_manager);
        else
            destroy_proxy_local(b->toplevel_source_manager);
    }
    if (b->toplevel_list) {
        if (send_wayland_destroy)
            ext_foreign_toplevel_list_v1_destroy(b->toplevel_list);
        else
            destroy_proxy_local(b->toplevel_list);
    }
    if (b->capture_manager) {
        if (send_wayland_destroy)
            ext_image_copy_capture_manager_v1_destroy(b->capture_manager);
        else
            destroy_proxy_local(b->capture_manager);
    }
    if (b->registry) {
        if (send_wayland_destroy) wl_registry_destroy(b->registry);
        else destroy_proxy_local(b->registry);
    }
    if (b->display)           wl_display_disconnect(b->display);

    pw_deinit();
    free(b);
}

uint32_t screencast_backend_get_available_source_types(ScreencastBackend *b) {
    if (!screencast_backend_is_healthy(b) || !b->capture_manager) return 0;
    uint32_t types = 0;
    if (b->source_manager) types |= SCREENCAST_SOURCE_MONITOR;
    if (b->toplevel_source_manager && b->toplevel_list)
        types |= SCREENCAST_SOURCE_WINDOW;
    return types;
}

bool screencast_backend_is_healthy(ScreencastBackend *b) {
    if (!b || !b->display || b->wayland_failed) return false;
    if (wl_display_get_error(b->display) != 0) {
        mark_wayland_failed(b, "health check");
        return false;
    }
    return true;
}

bool screencast_backend_has_failed(ScreencastBackend *b) {
    if (!b) return true;
    if (!screencast_backend_is_healthy(b)) return true;
    return b->start_failed;
}

char *screencast_backend_list_sources_json(ScreencastBackend *b, uint32_t requested_types) {
    JsonBuilder *builder = json_builder_new();
    json_builder_begin_object(builder);
    json_builder_set_member_name(builder, "sources");
    json_builder_begin_array(builder);

    if (screencast_backend_is_healthy(b)) {
        pthread_mutex_lock(&b->outputs_mutex);
        if ((requested_types & SCREENCAST_SOURCE_MONITOR) && b->source_manager) {
            for (OutputEntry *e = b->outputs; e; e = e->next) {
                const char *name = e->name ? e->name : "output";
                json_builder_begin_object(builder);
                json_builder_set_member_name(builder, "type");
                json_builder_add_int_value(builder, SCREENCAST_SOURCE_MONITOR);
                json_builder_set_member_name(builder, "id");
                json_builder_add_string_value(builder, name);
                json_builder_set_member_name(builder, "label");
                json_builder_add_string_value(builder, name);
                json_builder_set_member_name(builder, "app_id");
                json_builder_add_string_value(builder, "");
                json_builder_end_object(builder);
            }
        }
        if ((requested_types & SCREENCAST_SOURCE_WINDOW) && b->toplevel_source_manager) {
            for (ToplevelEntry *t = b->toplevels; t; t = t->next) {
                if (!t->handle || !t->identifier || t->identifier[0] == '\0')
                    continue;
                const char *title = (t->title && t->title[0] != '\0')
                    ? t->title : "Untitled window";
                const char *app_id = t->app_id ? t->app_id : "";
                json_builder_begin_object(builder);
                json_builder_set_member_name(builder, "type");
                json_builder_add_int_value(builder, SCREENCAST_SOURCE_WINDOW);
                json_builder_set_member_name(builder, "id");
                json_builder_add_string_value(builder, t->identifier);
                json_builder_set_member_name(builder, "label");
                json_builder_add_string_value(builder, title);
                json_builder_set_member_name(builder, "app_id");
                json_builder_add_string_value(builder, app_id);
                json_builder_end_object(builder);
            }
        }
        pthread_mutex_unlock(&b->outputs_mutex);
    }

    json_builder_end_array(builder);
    json_builder_end_object(builder);

    JsonGenerator *gen = json_generator_new();
    JsonNode *root = json_builder_get_root(builder);
    json_generator_set_root(gen, root);
    char *data = json_generator_to_data(gen, NULL);
    json_node_unref(root);
    g_object_unref(gen);
    g_object_unref(builder);
    return data;
}

int screencast_backend_start(ScreencastBackend *b, uint32_t source_type,
    const char *source_id, bool paint_cursors) {
    if (!screencast_backend_is_healthy(b) || !source_id || !b->capture_manager)
        return -1;
    if (source_type != SCREENCAST_SOURCE_MONITOR &&
        source_type != SCREENCAST_SOURCE_WINDOW)
        return -1;

    b->start_failed = false;

    struct wl_output *found_output = NULL;
    struct ext_foreign_toplevel_handle_v1 *found_toplevel = NULL;

    pthread_mutex_lock(&b->outputs_mutex);
    if (source_type == SCREENCAST_SOURCE_MONITOR) {
        for (OutputEntry *e = b->outputs; e; e = e->next) {
            if (e->name && strcmp(e->name, source_id) == 0) {
                found_output = e->output;
                break;
            }
        }
    } else if (source_type == SCREENCAST_SOURCE_WINDOW) {
        for (ToplevelEntry *t = b->toplevels; t; t = t->next) {
            if (t->handle && t->identifier && strcmp(t->identifier, source_id) == 0) {
                found_toplevel = t->handle;
                break;
            }
        }
    }
    pthread_mutex_unlock(&b->outputs_mutex);

    if (source_type == SCREENCAST_SOURCE_MONITOR && !found_output) {
        g_message ("screencast: start: output '%s' not found", source_id);
        return -1;
    }
    if (source_type == SCREENCAST_SOURCE_WINDOW && !found_toplevel) {
        g_message ("screencast: start: window '%s' not found", source_id);
        return -1;
    }

    g_message("screencast: starting capture type=%u id=%s",
        source_type, source_id);
    teardown_capture(b);
    b->capture_output = found_output;
    b->capture_toplevel = found_toplevel;
    b->running        = true;
    b->pw_setup_done  = false;
    b->node_id        = SPA_ID_INVALID;
    b->frame_ready    = false;
    b->constraints_received = false;
    b->have_buffer_size = false;
    b->have_shm_format = false;
    b->frame_w = 0;
    b->frame_h = 0;
    b->frame_stride = 0;
    b->frame_fmt = 0;
    b->capture_fmt = 0;
    b->capture_stride = 0;
    b->capture_bpp = 0;
    b->pw_format = SPA_VIDEO_FORMAT_UNKNOWN;
    b->pw_stride = 0;
    b->pw_bpp = 0;
    b->needs_pw_conversion = false;

    if (source_type == SCREENCAST_SOURCE_MONITOR) {
        if (!b->source_manager) {
            teardown_capture(b);
            return -1;
        }
        b->current_source = ext_output_image_capture_source_manager_v1_create_source(
            b->source_manager, b->capture_output);
    } else {
        if (!b->toplevel_source_manager) {
            teardown_capture(b);
            return -1;
        }
        b->current_source = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(
            b->toplevel_source_manager, b->capture_toplevel);
    }
    if (!b->current_source) {
        teardown_capture(b);
        return -1;
    }
    uint32_t options = paint_cursors
        ? EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS : 0;
    b->current_session = ext_image_copy_capture_manager_v1_create_session(
        b->capture_manager, b->current_source, options);
    if (!b->current_session) {
        teardown_capture(b);
        return -1;
    }
    ext_image_copy_capture_session_v1_add_listener(b->current_session, &session_listener, b);

    // Flush so the compositor actually receives the create-source/create-session
    // requests; otherwise it never sends the buffer constraints and the session
    // never reaches "done", so no PipeWire node is ever produced.
    if (wl_display_flush(b->display) < 0 && errno != EAGAIN) {
        mark_wayland_failed(b, "start flush");
        return -1;
    }

    return 0;
}

void screencast_backend_stop(ScreencastBackend *b) {
    if (!b) return;
    teardown_capture(b);
}

uint32_t screencast_backend_get_node_id(ScreencastBackend *b) {
    return b ? b->node_id : SPA_ID_INVALID;
}

int screencast_backend_get_pw_fd(ScreencastBackend *b) {
    if (!b) return -1;

    const char *remote      = getenv("PIPEWIRE_REMOTE");
    const char *runtime_dir = getenv("XDG_RUNTIME_DIR");

    char path[256];
    if (remote && remote[0] == '/') {
        snprintf(path, sizeof(path), "%s", remote);
    } else {
        snprintf(path, sizeof(path), "%s/%s",
                 runtime_dir ? runtime_dir : "/run/user/1000",
                 remote      ? remote      : "pipewire-0");
    }

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}
