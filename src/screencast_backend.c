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

#include <wayland-client.h>
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

/* ─── Backend state ─────────────────────────────────────────────────────────── */

struct ScreencastBackend {
    /* Wayland */
    struct wl_display                                *display;
    struct wl_registry                               *registry;
    struct wl_shm                                    *shm;
    struct ext_output_image_capture_source_manager_v1 *source_manager;
    struct ext_image_copy_capture_manager_v1         *capture_manager;
    guint                                             wl_source_id;

    /* Known outputs (protected by outputs_mutex) */
    OutputEntry    *outputs;
    pthread_mutex_t outputs_mutex;

    /* Active capture session */
    struct wl_output                         *capture_output;
    struct ext_image_capture_source_v1       *current_source;
    struct ext_image_copy_capture_session_v1 *current_session;
    struct ext_image_copy_capture_frame_v1   *current_frame;

    /* SHM capture buffer */
    struct wl_buffer   *shm_buffer;
    struct wl_shm_pool *shm_pool;
    void               *shm_data;
    int                 shm_fd;
    size_t              shm_size;
    uint32_t            frame_w, frame_h, frame_stride, frame_fmt;
    bool                buf_allocated;
    bool                constraints_received;

    /* Latest captured frame (mutex-protected: written main thread, read PW thread) */
    pthread_mutex_t frame_mutex;
    void           *latest_data;
    size_t          latest_size;
    uint32_t        latest_w, latest_h, latest_stride;
    bool            frame_ready;

    /* PipeWire */
    struct pw_main_loop *pw_loop;
    struct pw_context   *pw_context;
    struct pw_core      *pw_core;
    struct pw_stream    *pw_stream;
    struct spa_hook      stream_hook;
    uint32_t             node_id;
    bool                 pw_setup_done;

    /* For OpenPipeWireRemote */
    struct pw_core *remote_core;

    /* Control */
    volatile bool running;
    GThread      *pw_thread;
};

/* ─── Forward declarations ──────────────────────────────────────────────────── */

static void start_next_frame(ScreencastBackend *b);
static void setup_pw_stream(ScreencastBackend *b, uint32_t w, uint32_t h, uint32_t fmt);

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

static void reg_global(void *data, struct wl_registry *reg,
    uint32_t id, const char *iface, uint32_t ver) {
    ScreencastBackend *b = data;

    if (strcmp(iface, wl_shm_interface.name) == 0) {
        b->shm = wl_registry_bind(reg, id, &wl_shm_interface, 1);
    } else if (strcmp(iface, ext_output_image_capture_source_manager_v1_interface.name) == 0) {
        b->source_manager = wl_registry_bind(reg, id,
            &ext_output_image_capture_source_manager_v1_interface, 1);
    } else if (strcmp(iface, ext_image_copy_capture_manager_v1_interface.name) == 0) {
        b->capture_manager = wl_registry_bind(reg, id,
            &ext_image_copy_capture_manager_v1_interface, 1);
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
    b->buf_allocated = true;
    return true;
}

/* ─── ext_image_copy_capture_frame_v1 listener ─────────────────────────────── */

static void frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *f) {
    ScreencastBackend *b = data;
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
    if (b->current_frame) {
        ext_image_copy_capture_frame_v1_destroy(b->current_frame);
        b->current_frame = NULL;
    }
    if (b->running)
        g_timeout_add(100, (GSourceFunc)start_next_frame, b);
}

static void frame_transform(void *d, struct ext_image_copy_capture_frame_v1 *f, uint32_t transform) {}
static void frame_damage(void *d, struct ext_image_copy_capture_frame_v1 *f,
    int32_t x, int32_t y, int32_t w, int32_t h) {}
static void frame_presentation_time(void *d, struct ext_image_copy_capture_frame_v1 *f,
    uint32_t tv_sec_hi, uint32_t tv_sec_lo, uint32_t tv_nsec) {}

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
    b->frame_w = w;
    b->frame_h = h;
}

static void session_shm_format(void *data, struct ext_image_copy_capture_session_v1 *session,
    uint32_t format) {
    ScreencastBackend *b = data;
    /* We prefer ARGB8888 or XRGB8888 */
    if (format == WL_SHM_FORMAT_ARGB8888 || format == WL_SHM_FORMAT_XRGB8888) {
        b->frame_fmt = format;
    } else if (b->frame_fmt == 0) {
        b->frame_fmt = format;
    }
}

static void session_dmabuf_device(void *data, struct ext_image_copy_capture_session_v1 *session,
    struct wl_array *device) {}
static void session_dmabuf_format(void *data, struct ext_image_copy_capture_session_v1 *session,
    uint32_t format, struct wl_array *modifiers) {}

static void session_done(void *data, struct ext_image_copy_capture_session_v1 *session) {
    ScreencastBackend *b = data;
    if (!b->constraints_received) {
        b->constraints_received = true;
        uint32_t stride = b->frame_w * 4;
        if (alloc_shm_buffer(b, b->frame_w, b->frame_h, stride, b->frame_fmt)) {
            if (!b->pw_setup_done) setup_pw_stream(b, b->frame_w, b->frame_h, b->frame_fmt);
            if (b->running) start_next_frame(b);
        }
    }
}

static void session_stopped(void *data, struct ext_image_copy_capture_session_v1 *session) {
    ScreencastBackend *b = data;
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
    if (!b->current_session || !b->shm_buffer || !b->running) return;
    b->current_frame = ext_image_copy_capture_session_v1_create_frame(b->current_session);
    ext_image_copy_capture_frame_v1_add_listener(b->current_frame, &frame_listener, b);
    ext_image_copy_capture_frame_v1_attach_buffer(b->current_frame, b->shm_buffer);
    ext_image_copy_capture_frame_v1_damage_buffer(b->current_frame, 0, 0, (int32_t)b->frame_w, (int32_t)b->frame_h);
    ext_image_copy_capture_frame_v1_capture(b->current_frame);
    wl_display_flush(b->display);
}

/* ─── PipeWire stream callbacks ─────────────────────────────────────────────── */

static void pw_state_changed(void *data, enum pw_stream_state old,
    enum pw_stream_state state, const char *error) {
    ScreencastBackend *b = data;
    if ((state == PW_STREAM_STATE_PAUSED || state == PW_STREAM_STATE_STREAMING)
        && b->node_id == SPA_ID_INVALID) {
        uint32_t nid = pw_stream_get_node_id(b->pw_stream);
        if (nid != SPA_ID_INVALID) b->node_id = nid;
    }
}

static void pw_param_changed(void *data, uint32_t id,
    const struct spa_pod *param) {
    ScreencastBackend *b = data;
    if (!param || id != SPA_PARAM_Format) return;

    struct spa_video_info_raw vi;
    if (spa_format_video_raw_parse(param, &vi) < 0) return;

    uint32_t stride = SPA_ROUND_UP_N(vi.size.width * 4, 4);
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
        SPA_PARAM_BUFFERS_dataType, SPA_POD_Int(1 << SPA_DATA_MemPtr));

    params[1] = spa_pod_builder_add_object(&pod,
        SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));

    pw_stream_update_params(b->pw_stream, params, 2);
}

static void pw_process(void *data) {
    ScreencastBackend *b = data;

    struct pw_buffer *pwb = pw_stream_dequeue_buffer(b->pw_stream);
    if (!pwb) return;

    struct spa_data *d = &pwb->buffer->datas[0];

    if (d->data && pthread_mutex_trylock(&b->frame_mutex) == 0) {
        if (b->frame_ready) {
            size_t copy_sz = (size_t)b->latest_stride * b->latest_h;
            if (copy_sz <= d->maxsize) {
                memcpy(d->data, b->latest_data, copy_sz);
                d->chunk->offset = 0;
                d->chunk->stride = (int32_t)b->latest_stride;
                d->chunk->size   = (uint32_t)copy_sz;
            }
        }
        pthread_mutex_unlock(&b->frame_mutex);
    }

    pw_stream_queue_buffer(b->pw_stream, pwb);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = pw_state_changed,
    .param_changed = pw_param_changed,
    .process       = pw_process,
};

/* ─── PipeWire stream setup ──────────────── */

static enum spa_video_format wl_fmt_to_spa(uint32_t wl_fmt) {
    switch (wl_fmt) {
    case WL_SHM_FORMAT_ARGB8888: return SPA_VIDEO_FORMAT_BGRA;
    case WL_SHM_FORMAT_XRGB8888: return SPA_VIDEO_FORMAT_BGRx;
    case WL_SHM_FORMAT_ABGR8888: return SPA_VIDEO_FORMAT_RGBA;
    case WL_SHM_FORMAT_XBGR8888: return SPA_VIDEO_FORMAT_RGBx;
    default:                     return SPA_VIDEO_FORMAT_BGRx;
    }
}

static void setup_pw_stream(ScreencastBackend *b,
    uint32_t w, uint32_t h, uint32_t fmt) {
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
    struct spa_fraction  fps = { 30, 1 };
    enum spa_video_format spa_fmt = wl_fmt_to_spa(fmt);
    const struct spa_pod *params[1];

    params[0] = spa_pod_builder_add_object(&pod,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType,       SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype,    SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format,    SPA_POD_Id(spa_fmt),
        SPA_FORMAT_VIDEO_size,      SPA_POD_Rectangle(&sz),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&fps));

    pw_stream_connect(b->pw_stream,
        PW_DIRECTION_OUTPUT,
        PW_ID_ANY,
        PW_STREAM_FLAG_DRIVER | PW_STREAM_FLAG_MAP_BUFFERS,
        params, 1);
}

/* ─── GLib IO callback ─────────────────────────────────── */

static gboolean on_wl_io(int fd, GIOCondition cond, gpointer data) {
    ScreencastBackend *b = data;
    if (cond & (G_IO_ERR | G_IO_HUP)) {
        b->running = false;
        return G_SOURCE_REMOVE;
    }
    if (wl_display_prepare_read(b->display) == 0) {
        wl_display_read_events(b->display);
    }
    wl_display_dispatch_pending(b->display);
    wl_display_flush(b->display);
    return G_SOURCE_CONTINUE;
}

/* ─── PipeWire thread ───────────────────────────────────────────────────────── */

static gpointer pw_thread_func(gpointer data) {
    ScreencastBackend *b = data;
    pw_main_loop_run(b->pw_loop);
    return NULL;
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
    wl_display_roundtrip(b->display);
    wl_display_roundtrip(b->display);

    if (!b->shm || !b->source_manager || !b->capture_manager) {
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

    b->pw_thread = g_thread_new("pw-screencast", pw_thread_func, b);
    return b;

fail:
    screencast_backend_free(b);
    return NULL;
}

void screencast_backend_free(ScreencastBackend *b) {
    if (!b) return;
    b->running = false;

    if (b->wl_source_id) {
        g_source_remove(b->wl_source_id);
        b->wl_source_id = 0;
    }

    if (b->current_frame) {
        ext_image_copy_capture_frame_v1_destroy(b->current_frame);
        b->current_frame = NULL;
    }
    if (b->current_session) {
        ext_image_copy_capture_session_v1_destroy(b->current_session);
        b->current_session = NULL;
    }
    if (b->current_source) {
        ext_image_capture_source_v1_destroy(b->current_source);
        b->current_source = NULL;
    }

    if (b->pw_stream) {
        pw_stream_disconnect(b->pw_stream);
        pw_stream_destroy(b->pw_stream);
        b->pw_stream = NULL;
    }

    if (b->pw_loop)   pw_main_loop_quit(b->pw_loop);
    if (b->pw_thread) { g_thread_join(b->pw_thread); b->pw_thread = NULL; }

    if (b->remote_core) { pw_core_disconnect(b->remote_core); b->remote_core = NULL; }
    if (b->pw_core)     { pw_core_disconnect(b->pw_core);     b->pw_core     = NULL; }
    if (b->pw_context)  { pw_context_destroy(b->pw_context);  b->pw_context  = NULL; }
    if (b->pw_loop)     { pw_main_loop_destroy(b->pw_loop);   b->pw_loop     = NULL; }

    if (b->shm_buffer) wl_buffer_destroy(b->shm_buffer);
    if (b->shm_pool)   wl_shm_pool_destroy(b->shm_pool);
    if (b->shm_data)   munmap(b->shm_data, b->shm_size);
    if (b->shm_fd >= 0) close(b->shm_fd);
    free(b->latest_data);

    pthread_mutex_lock(&b->outputs_mutex);
    OutputEntry *e = b->outputs;
    while (e) {
        OutputEntry *next = e->next;
        wl_output_destroy(e->output);
        free(e->name);
        free(e);
        e = next;
    }
    pthread_mutex_unlock(&b->outputs_mutex);
    pthread_mutex_destroy(&b->outputs_mutex);
    pthread_mutex_destroy(&b->frame_mutex);

    if (b->shm)               wl_shm_destroy(b->shm);
    if (b->source_manager)    ext_output_image_capture_source_manager_v1_destroy(b->source_manager);
    if (b->capture_manager)   ext_image_copy_capture_manager_v1_destroy(b->capture_manager);
    if (b->registry)          wl_registry_destroy(b->registry);
    if (b->display)           wl_display_disconnect(b->display);

    pw_deinit();
    free(b);
}

char **screencast_backend_list_outputs(ScreencastBackend *b) {
    if (!b) return NULL;
    int count = 0;

    pthread_mutex_lock(&b->outputs_mutex);
    for (OutputEntry *e = b->outputs; e; e = e->next) count++;

    char **list = g_new0(char *, count + 1);
    if (list) {
        int i = 0;
        for (OutputEntry *e = b->outputs; e; e = e->next)
            list[i++] = g_strdup(e->name ? e->name : "output");
    }
    pthread_mutex_unlock(&b->outputs_mutex);
    return list;
}

int screencast_backend_start(ScreencastBackend *b, const char *output_name) {
    if (!b || !output_name || !b->source_manager || !b->capture_manager) return -1;

    pthread_mutex_lock(&b->outputs_mutex);
    OutputEntry *found = NULL;
    for (OutputEntry *e = b->outputs; e; e = e->next) {
        if (e->name && strcmp(e->name, output_name) == 0) { found = e; break; }
    }
    pthread_mutex_unlock(&b->outputs_mutex);

    if (!found) return -1;

    b->capture_output = found->output;
    b->running        = true;
    b->pw_setup_done  = false;
    b->node_id        = SPA_ID_INVALID;
    b->frame_ready    = false;
    b->constraints_received = false;

    b->current_source = ext_output_image_capture_source_manager_v1_create_source(
        b->source_manager, b->capture_output);
    b->current_session = ext_image_copy_capture_manager_v1_create_session(
        b->capture_manager, b->current_source, 0);
    ext_image_copy_capture_session_v1_add_listener(b->current_session, &session_listener, b);

    return 0;
}

void screencast_backend_stop(ScreencastBackend *b) {
    if (!b) return;
    b->running = false;

    if (b->current_frame) {
        ext_image_copy_capture_frame_v1_destroy(b->current_frame);
        b->current_frame = NULL;
    }
    if (b->current_session) {
        ext_image_copy_capture_session_v1_destroy(b->current_session);
        b->current_session = NULL;
    }
    if (b->current_source) {
        ext_image_capture_source_v1_destroy(b->current_source);
        b->current_source = NULL;
    }
    if (b->pw_stream) {
        pw_stream_disconnect(b->pw_stream);
        pw_stream_destroy(b->pw_stream);
        b->pw_stream = NULL;
    }
    b->pw_setup_done  = false;
    b->node_id        = SPA_ID_INVALID;
    b->capture_output = NULL;
    b->constraints_received = false;
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
