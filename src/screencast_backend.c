#include "screencast_backend.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <glib.h>
#include <glib-unix.h>
#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/video/format-utils.h>
#include <spa/utils/defs.h>
#include <wayland-client.h>

#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

typedef struct OutputEntry {
    struct wl_output *output;
    uint32_t global_id;
    char *name;
    int width;
    int height;
    struct OutputEntry *next;
} OutputEntry;

struct ScreencastBackend {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_shm *shm;
    struct ext_output_image_capture_source_manager_v1 *source_manager;
    struct ext_image_copy_capture_manager_v1 *capture_manager;
    guint wayland_source_id;

    OutputEntry *outputs;
    pthread_mutex_t outputs_mutex;

    struct pw_main_loop *pipewire_loop;
    struct pw_context *pipewire_context;
    struct pw_core *pipewire_core;
    struct spa_hook pipewire_core_hook;
    bool pipewire_core_hook_added;
    guint pipewire_source_id;

    GList *captures;
    bool healthy;
    bool wayland_healthy;
};

struct ScreencastCapture {
    ScreencastBackend *backend;
    struct ext_image_capture_source_v1 *source;
    struct ext_image_copy_capture_session_v1 *session;
    struct ext_image_copy_capture_frame_v1 *frame;
    guint retry_source_id;
    uint64_t generation;
    struct wl_output *selected_output;

    struct wl_buffer *shm_buffer;
    struct wl_shm_pool *shm_pool;
    void *shm_data;
    int shm_fd;
    size_t shm_size;

    uint32_t width;
    uint32_t height;
    uint32_t capture_format;
    uint32_t capture_stride;
    uint32_t pipewire_stride;
    size_t pipewire_size;

    uint32_t pending_width;
    uint32_t pending_height;
    uint32_t pending_format;
    bool pending_size_set;
    bool pending_format_set;
    bool constraints_received;

    pthread_mutex_t frame_mutex;
    void *latest_data;
    size_t latest_size;
    uint32_t latest_width;
    uint32_t latest_height;
    uint32_t latest_stride;
    bool frame_ready;

    struct pw_stream *pipewire_stream;
    struct spa_hook stream_hook;
    uint32_t node_id;
    uint64_t sequence;

    bool running;
    bool failed;
    bool stopped;
};

typedef struct {
    ScreencastCapture *capture;
    uint64_t generation;
} FrameRetry;

static void screencast_capture_start_next_frame(ScreencastCapture *capture);
static void screencast_capture_destroy_stream(ScreencastCapture *capture);
static void fail_all_captures(ScreencastBackend *backend, const char *reason);

static void
destroy_proxy_locally(void *proxy)
{
    if (proxy != NULL)
        wl_proxy_destroy((struct wl_proxy *) proxy);
}

static void
output_geometry(void *data,
                struct wl_output *output,
                int32_t x,
                int32_t y,
                int32_t physical_width,
                int32_t physical_height,
                int32_t subpixel,
                const char *make,
                const char *model,
                int32_t transform)
{
    (void) data;
    (void) output;
    (void) x;
    (void) y;
    (void) physical_width;
    (void) physical_height;
    (void) subpixel;
    (void) make;
    (void) model;
    (void) transform;
}

static void
output_mode(void *data,
            struct wl_output *output,
            uint32_t flags,
            int32_t width,
            int32_t height,
            int32_t refresh)
{
    OutputEntry *entry = data;
    (void) output;
    (void) refresh;

    if (flags & WL_OUTPUT_MODE_CURRENT) {
        entry->width = width;
        entry->height = height;
    }
}

static void output_done(void *data, struct wl_output *output)
{
    (void) data;
    (void) output;
}

static void output_scale(void *data, struct wl_output *output, int32_t scale)
{
    (void) data;
    (void) output;
    (void) scale;
}

static void
output_name(void *data, struct wl_output *output, const char *name)
{
    OutputEntry *entry = data;
    (void) output;
    free(entry->name);
    entry->name = strdup(name);
}

static void
output_description(void *data,
                   struct wl_output *output,
                   const char *description)
{
    (void) data;
    (void) output;
    (void) description;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void
registry_global(void *data,
                struct wl_registry *registry,
                uint32_t id,
                const char *interface,
                uint32_t version)
{
    ScreencastBackend *backend = data;

    if (strcmp(interface, wl_shm_interface.name) == 0) {
        backend->shm = wl_registry_bind(
            registry, id, &wl_shm_interface, 1);
    } else if (strcmp(
                   interface,
                   ext_output_image_capture_source_manager_v1_interface.name) == 0) {
        backend->source_manager = wl_registry_bind(
            registry,
            id,
            &ext_output_image_capture_source_manager_v1_interface,
            1);
    } else if (strcmp(
                   interface,
                   ext_image_copy_capture_manager_v1_interface.name) == 0) {
        backend->capture_manager = wl_registry_bind(
            registry,
            id,
            &ext_image_copy_capture_manager_v1_interface,
            1);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        uint32_t bound_version = version >= 4 ? 4 : version;
        OutputEntry *entry = calloc(1, sizeof(*entry));
        if (entry == NULL)
            return;

        entry->output = wl_registry_bind(
            registry, id, &wl_output_interface, bound_version);
        entry->global_id = id;
        wl_output_add_listener(entry->output, &output_listener, entry);

        pthread_mutex_lock(&backend->outputs_mutex);
        entry->next = backend->outputs;
        backend->outputs = entry;
        pthread_mutex_unlock(&backend->outputs_mutex);
    }
}

static void
registry_global_remove(void *data,
                       struct wl_registry *registry,
                       uint32_t id)
{
    ScreencastBackend *backend = data;
    (void) registry;

    pthread_mutex_lock(&backend->outputs_mutex);
    for (OutputEntry **link = &backend->outputs; *link != NULL;
         link = &(*link)->next) {
        if ((*link)->global_id != id)
            continue;

        OutputEntry *entry = *link;
        *link = entry->next;
        for (GList *capture_link = backend->captures;
             capture_link != NULL;
             capture_link = capture_link->next) {
            ScreencastCapture *capture = capture_link->data;
            if (capture->selected_output == entry->output) {
                capture->failed = true;
                screencast_capture_stop(capture);
            }
        }
        if (backend->wayland_healthy)
            wl_output_destroy(entry->output);
        else
            destroy_proxy_locally(entry->output);
        free(entry->name);
        free(entry);
        break;
    }
    pthread_mutex_unlock(&backend->outputs_mutex);
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static int
create_shm_fd(size_t size)
{
    int fd = memfd_create("singularity-screencast", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0)
        return -1;
    if (ftruncate(fd, (off_t) size) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void
screencast_capture_destroy_shm(ScreencastCapture *capture)
{
    bool send_wayland_requests = capture->backend != NULL &&
        capture->backend->wayland_healthy;
    if (capture->shm_buffer != NULL) {
        if (send_wayland_requests)
            wl_buffer_destroy(capture->shm_buffer);
        else
            destroy_proxy_locally(capture->shm_buffer);
        capture->shm_buffer = NULL;
    }
    if (capture->shm_pool != NULL) {
        if (send_wayland_requests)
            wl_shm_pool_destroy(capture->shm_pool);
        else
            destroy_proxy_locally(capture->shm_pool);
        capture->shm_pool = NULL;
    }
    if (capture->shm_data != NULL) {
        munmap(capture->shm_data, capture->shm_size);
        capture->shm_data = NULL;
    }
    if (capture->shm_fd >= 0) {
        close(capture->shm_fd);
        capture->shm_fd = -1;
    }
    capture->shm_size = 0;
}

static bool
screencast_capture_allocate_shm(ScreencastCapture *capture)
{
    screencast_capture_destroy_shm(capture);

    capture->shm_size =
        (size_t) capture->capture_stride * capture->height;
    capture->shm_fd = create_shm_fd(capture->shm_size);
    if (capture->shm_fd < 0)
        return false;

    capture->shm_data = mmap(NULL,
                             capture->shm_size,
                             PROT_READ | PROT_WRITE,
                             MAP_SHARED,
                             capture->shm_fd,
                             0);
    if (capture->shm_data == MAP_FAILED) {
        capture->shm_data = NULL;
        screencast_capture_destroy_shm(capture);
        return false;
    }

    capture->shm_pool = wl_shm_create_pool(
        capture->backend->shm,
        capture->shm_fd,
        (int32_t) capture->shm_size);
    if (capture->shm_pool == NULL) {
        screencast_capture_destroy_shm(capture);
        return false;
    }

    capture->shm_buffer = wl_shm_pool_create_buffer(
        capture->shm_pool,
        0,
        (int32_t) capture->width,
        (int32_t) capture->height,
        (int32_t) capture->capture_stride,
        capture->capture_format);
    if (capture->shm_buffer == NULL) {
        screencast_capture_destroy_shm(capture);
        return false;
    }
    return true;
}

static int
format_rank(uint32_t format)
{
    switch (format) {
    case WL_SHM_FORMAT_XRGB8888:
        return 4;
    case WL_SHM_FORMAT_ARGB8888:
        return 3;
    case WL_SHM_FORMAT_XBGR8888:
        return 2;
    case WL_SHM_FORMAT_ABGR8888:
        return 1;
    default:
        return 0;
    }
}

static void
frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *frame)
{
    ScreencastCapture *capture = data;
    if (frame != capture->frame)
        return;

    pthread_mutex_lock(&capture->frame_mutex);
    if (capture->latest_size < capture->shm_size) {
        void *resized = realloc(capture->latest_data, capture->shm_size);
        if (resized != NULL) {
            capture->latest_data = resized;
            capture->latest_size = capture->shm_size;
        } else {
            capture->failed = true;
            capture->running = false;
        }
    }
    if (capture->latest_size >= capture->shm_size &&
        capture->latest_data != NULL && capture->shm_data != NULL) {
        memcpy(capture->latest_data, capture->shm_data, capture->shm_size);
        capture->latest_width = capture->width;
        capture->latest_height = capture->height;
        capture->latest_stride = capture->capture_stride;
        capture->frame_ready = true;
    }
    pthread_mutex_unlock(&capture->frame_mutex);

    if (capture->pipewire_stream != NULL)
        pw_stream_trigger_process(capture->pipewire_stream);

    ext_image_copy_capture_frame_v1_destroy(capture->frame);
    capture->frame = NULL;
    screencast_capture_start_next_frame(capture);
}

static gboolean
retry_frame(gpointer data)
{
    FrameRetry *retry = data;
    ScreencastCapture *capture = retry->capture;
    capture->retry_source_id = 0;

    if (capture->running && !capture->stopped &&
        retry->generation == capture->generation)
        screencast_capture_start_next_frame(capture);
    return G_SOURCE_REMOVE;
}

static void
frame_failed(void *data,
             struct ext_image_copy_capture_frame_v1 *frame,
             uint32_t reason)
{
    ScreencastCapture *capture = data;
    (void) reason;
    if (frame != capture->frame)
        return;

    ext_image_copy_capture_frame_v1_destroy(capture->frame);
    capture->frame = NULL;

    if (capture->running && capture->retry_source_id == 0) {
        FrameRetry *retry = g_new0(FrameRetry, 1);
        retry->capture = capture;
        retry->generation = capture->generation;
        capture->retry_source_id = g_timeout_add_full(
            G_PRIORITY_DEFAULT, 100, retry_frame, retry, g_free);
    }
}

static void
frame_transform(void *data,
                struct ext_image_copy_capture_frame_v1 *frame,
                uint32_t transform)
{
    (void) data;
    (void) frame;
    (void) transform;
}

static void
frame_damage(void *data,
             struct ext_image_copy_capture_frame_v1 *frame,
             int32_t x,
             int32_t y,
             int32_t width,
             int32_t height)
{
    (void) data;
    (void) frame;
    (void) x;
    (void) y;
    (void) width;
    (void) height;
}

static void
frame_presentation_time(void *data,
                        struct ext_image_copy_capture_frame_v1 *frame,
                        uint32_t seconds_high,
                        uint32_t seconds_low,
                        uint32_t nanoseconds)
{
    (void) data;
    (void) frame;
    (void) seconds_high;
    (void) seconds_low;
    (void) nanoseconds;
}

static const struct ext_image_copy_capture_frame_v1_listener frame_listener = {
    .ready = frame_ready,
    .failed = frame_failed,
    .transform = frame_transform,
    .damage = frame_damage,
    .presentation_time = frame_presentation_time,
};

static void
pipewire_state_changed(void *data,
                       enum pw_stream_state old_state,
                       enum pw_stream_state state,
                       const char *error)
{
    ScreencastCapture *capture = data;
    (void) old_state;

    if (state == PW_STREAM_STATE_ERROR) {
        g_warning("screencast: PipeWire stream failed: %s",
                  error != NULL ? error : "unknown error");
        capture->failed = true;
        capture->running = false;
        return;
    }

    if ((state == PW_STREAM_STATE_PAUSED ||
         state == PW_STREAM_STATE_STREAMING) &&
        capture->node_id == SPA_ID_INVALID &&
        capture->pipewire_stream != NULL) {
        capture->node_id = pw_stream_get_node_id(capture->pipewire_stream);
    }
}

static void
pipewire_param_changed(void *data,
                       uint32_t id,
                       const struct spa_pod *parameter)
{
    ScreencastCapture *capture = data;
    if (parameter == NULL || id != SPA_PARAM_Format ||
        capture->pipewire_stream == NULL)
        return;

    struct spa_video_info_raw video_info;
    if (spa_format_video_raw_parse(parameter, &video_info) < 0)
        return;

    uint8_t buffer[768];
    struct spa_pod_builder builder =
        SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *parameters[2];
    parameters[0] = spa_pod_builder_add_object(
        &builder,
        SPA_TYPE_OBJECT_ParamBuffers,
        SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers,
        SPA_POD_CHOICE_RANGE_Int(2, 1, 8),
        SPA_PARAM_BUFFERS_blocks,
        SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_size,
        SPA_POD_Int((int) capture->pipewire_size),
        SPA_PARAM_BUFFERS_stride,
        SPA_POD_Int((int) capture->pipewire_stride),
        SPA_PARAM_BUFFERS_align,
        SPA_POD_Int(16),
        SPA_PARAM_BUFFERS_dataType,
        SPA_POD_CHOICE_FLAGS_Int(1 << SPA_DATA_MemFd));
    parameters[1] = spa_pod_builder_add_object(
        &builder,
        SPA_TYPE_OBJECT_ParamMeta,
        SPA_PARAM_Meta,
        SPA_PARAM_META_type,
        SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size,
        SPA_POD_Int(sizeof(struct spa_meta_header)));
    pw_stream_update_params(capture->pipewire_stream, parameters, 2);
}

static void
pipewire_process(void *data)
{
    ScreencastCapture *capture = data;
    if (capture->pipewire_stream == NULL)
        return;

    struct pw_buffer *pipewire_buffer =
        pw_stream_dequeue_buffer(capture->pipewire_stream);
    if (pipewire_buffer == NULL)
        return;

    struct spa_data *destination = &pipewire_buffer->buffer->datas[0];
    destination->chunk->offset = 0;
    destination->chunk->size = 0;
    destination->chunk->stride = (int32_t) capture->pipewire_stride;

    pthread_mutex_lock(&capture->frame_mutex);
    if (capture->frame_ready && destination->data != NULL &&
        destination->maxsize >= capture->pipewire_size &&
        capture->latest_stride == capture->pipewire_stride) {
        memcpy(destination->data,
               capture->latest_data,
               capture->pipewire_size);
        destination->chunk->size = (uint32_t) capture->pipewire_size;
    }
    pthread_mutex_unlock(&capture->frame_mutex);

    struct spa_meta_header *header = spa_buffer_find_meta_data(
        pipewire_buffer->buffer, SPA_META_Header, sizeof(*header));
    if (header != NULL) {
        struct timespec timestamp;
        clock_gettime(CLOCK_MONOTONIC, &timestamp);
        header->pts = SPA_TIMESPEC_TO_NSEC(&timestamp);
        header->flags = 0;
        header->seq = capture->sequence++;
        header->dts_offset = 0;
    }

    pw_stream_queue_buffer(capture->pipewire_stream, pipewire_buffer);
}

static void
pipewire_add_buffer(void *data, struct pw_buffer *pipewire_buffer)
{
    ScreencastCapture *capture = data;
    struct spa_data *destination = &pipewire_buffer->buffer->datas[0];
    destination->data = NULL;
    destination->fd = -1;
    destination->maxsize = 0;
    int fd = create_shm_fd(capture->pipewire_size);
    if (fd < 0) {
        capture->failed = true;
        return;
    }

    void *mapped = mmap(NULL,
                        capture->pipewire_size,
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED,
                        fd,
                        0);
    if (mapped == MAP_FAILED) {
        close(fd);
        capture->failed = true;
        return;
    }

    destination->type = SPA_DATA_MemFd;
    destination->flags = SPA_DATA_FLAG_READABLE;
    destination->fd = fd;
    destination->mapoffset = 0;
    destination->maxsize = (uint32_t) capture->pipewire_size;
    destination->data = mapped;
    destination->chunk->offset = 0;
    destination->chunk->stride = (int32_t) capture->pipewire_stride;
    destination->chunk->size = 0;
}

static void
pipewire_remove_buffer(void *data, struct pw_buffer *pipewire_buffer)
{
    (void) data;
    struct spa_data *destination = &pipewire_buffer->buffer->datas[0];
    if (destination->data != NULL && destination->maxsize != 0)
        munmap(destination->data, destination->maxsize);
    if ((int) destination->fd >= 0)
        close((int) destination->fd);
    destination->data = NULL;
    destination->fd = -1;
}

static const struct pw_stream_events pipewire_stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = pipewire_state_changed,
    .param_changed = pipewire_param_changed,
    .add_buffer = pipewire_add_buffer,
    .remove_buffer = pipewire_remove_buffer,
    .process = pipewire_process,
};

static const struct spa_pod *
build_pipewire_format(ScreencastCapture *capture,
                      struct spa_pod_builder *builder)
{
    struct spa_rectangle size = { capture->width, capture->height };
    struct spa_fraction framerate = { 0, 1 };
    struct spa_fraction minimum_framerate = { 1, 1 };
    struct spa_fraction maximum_framerate = { 60, 1 };

    enum spa_video_format pipewire_format;
    switch (capture->capture_format) {
    case WL_SHM_FORMAT_ARGB8888:
        pipewire_format = SPA_VIDEO_FORMAT_BGRA;
        break;
    case WL_SHM_FORMAT_ABGR8888:
        pipewire_format = SPA_VIDEO_FORMAT_RGBA;
        break;
    case WL_SHM_FORMAT_XBGR8888:
        pipewire_format = SPA_VIDEO_FORMAT_RGBx;
        break;
    case WL_SHM_FORMAT_XRGB8888:
    default:
        pipewire_format = SPA_VIDEO_FORMAT_BGRx;
        break;
    }

    return spa_pod_builder_add_object(
        builder,
        SPA_TYPE_OBJECT_Format,
        SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType,
        SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype,
        SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format,
        SPA_POD_Id(pipewire_format),
        SPA_FORMAT_VIDEO_size,
        SPA_POD_Rectangle(&size),
        SPA_FORMAT_VIDEO_framerate,
        SPA_POD_Fraction(&framerate),
        SPA_FORMAT_VIDEO_maxFramerate,
        SPA_POD_CHOICE_RANGE_Fraction(
            &maximum_framerate,
            &minimum_framerate,
            &maximum_framerate));
}

static bool
screencast_capture_configure_stream(ScreencastCapture *capture)
{
    uint8_t buffer[256];
    struct spa_pod_builder builder =
        SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *parameters[] = {
        build_pipewire_format(capture, &builder),
    };

    if (capture->pipewire_stream != NULL) {
        return pw_stream_update_params(
                   capture->pipewire_stream, parameters, 1) >= 0;
    }

    struct pw_properties *properties = pw_properties_new(
        PW_KEY_MEDIA_CLASS,
        "Video/Source",
        PW_KEY_NODE_NAME,
        "singularity-screencast",
        PW_KEY_NODE_DESCRIPTION,
        "Singularity Desktop ScreenCast",
        NULL);
    capture->pipewire_stream = pw_stream_new(
        capture->backend->pipewire_core,
        "Singularity ScreenCast",
        properties);
    if (capture->pipewire_stream == NULL)
        return false;

    pw_stream_add_listener(capture->pipewire_stream,
                           &capture->stream_hook,
                           &pipewire_stream_events,
                           capture);
    if (pw_stream_connect(capture->pipewire_stream,
                          PW_DIRECTION_OUTPUT,
                          PW_ID_ANY,
                          PW_STREAM_FLAG_DRIVER |
                              PW_STREAM_FLAG_ALLOC_BUFFERS,
                          parameters,
                          1) < 0) {
        screencast_capture_destroy_stream(capture);
        return false;
    }
    return true;
}

static void
session_buffer_size(void *data,
                    struct ext_image_copy_capture_session_v1 *session,
                    uint32_t width,
                    uint32_t height)
{
    ScreencastCapture *capture = data;
    if (session != capture->session)
        return;
    if (capture->constraints_received)
        return;
    capture->pending_width = width;
    capture->pending_height = height;
    capture->pending_size_set = true;
}

static void
session_shm_format(void *data,
                   struct ext_image_copy_capture_session_v1 *session,
                   uint32_t format)
{
    ScreencastCapture *capture = data;
    if (session != capture->session || format_rank(format) == 0)
        return;
    if (!capture->pending_format_set ||
        format_rank(format) > format_rank(capture->pending_format)) {
        capture->pending_format = format;
        capture->pending_format_set = true;
    }
}

static void
session_dmabuf_device(void *data,
                      struct ext_image_copy_capture_session_v1 *session,
                      struct wl_array *device)
{
    (void) data;
    (void) session;
    (void) device;
}

static void
session_dmabuf_format(void *data,
                      struct ext_image_copy_capture_session_v1 *session,
                      uint32_t format,
                      struct wl_array *modifiers)
{
    (void) data;
    (void) session;
    (void) format;
    (void) modifiers;
}

static void
session_done(void *data,
             struct ext_image_copy_capture_session_v1 *session)
{
    ScreencastCapture *capture = data;
    if (session != capture->session)
        return;

    if (!capture->pending_size_set || !capture->pending_format_set ||
        capture->pending_width == 0 || capture->pending_height == 0 ||
        capture->pending_width > UINT32_MAX / 4) {
        g_warning("screencast: compositor supplied unusable buffer constraints");
        capture->failed = true;
        capture->running = false;
        return;
    }
    uint32_t capture_stride = capture->pending_width * 4;
    if (capture->pending_height > SIZE_MAX / capture_stride ||
        (size_t) capture_stride * capture->pending_height > UINT32_MAX) {
        g_warning("screencast: compositor supplied oversized buffer constraints");
        capture->failed = true;
        capture->running = false;
        return;
    }
    size_t pipewire_size =
        (size_t) capture_stride * capture->pending_height;
    capture->constraints_received = true;

    capture->generation++;
    if (capture->retry_source_id != 0) {
        g_source_remove(capture->retry_source_id);
        capture->retry_source_id = 0;
    }
    if (capture->frame != NULL) {
        ext_image_copy_capture_frame_v1_destroy(capture->frame);
        capture->frame = NULL;
    }

    capture->width = capture->pending_width;
    capture->height = capture->pending_height;
    capture->capture_format = capture->pending_format;
    capture->capture_stride = capture_stride;
    capture->pipewire_stride = capture_stride;
    capture->pipewire_size = pipewire_size;
    capture->pending_size_set = false;
    capture->pending_format_set = false;

    pthread_mutex_lock(&capture->frame_mutex);
    capture->frame_ready = false;
    pthread_mutex_unlock(&capture->frame_mutex);

    if (!screencast_capture_allocate_shm(capture) ||
        !screencast_capture_configure_stream(capture)) {
        g_warning("screencast: failed to allocate or publish capture buffers");
        capture->failed = true;
        capture->running = false;
        return;
    }

    screencast_capture_start_next_frame(capture);
}

static void
session_stopped(void *data,
                struct ext_image_copy_capture_session_v1 *session)
{
    ScreencastCapture *capture = data;
    if (session != capture->session)
        return;
    capture->failed = true;
    capture->running = false;
}

static const struct ext_image_copy_capture_session_v1_listener session_listener = {
    .buffer_size = session_buffer_size,
    .shm_format = session_shm_format,
    .dmabuf_device = session_dmabuf_device,
    .dmabuf_format = session_dmabuf_format,
    .done = session_done,
    .stopped = session_stopped,
};

static void
screencast_capture_start_next_frame(ScreencastCapture *capture)
{
    if (capture == NULL || !capture->running || capture->stopped ||
        capture->failed || capture->session == NULL ||
        capture->shm_buffer == NULL || capture->frame != NULL)
        return;

    capture->frame = ext_image_copy_capture_session_v1_create_frame(
        capture->session);
    if (capture->frame == NULL) {
        capture->failed = true;
        capture->running = false;
        return;
    }
    ext_image_copy_capture_frame_v1_add_listener(
        capture->frame, &frame_listener, capture);
    ext_image_copy_capture_frame_v1_attach_buffer(
        capture->frame, capture->shm_buffer);
    ext_image_copy_capture_frame_v1_damage_buffer(
        capture->frame,
        0,
        0,
        (int32_t) capture->width,
        (int32_t) capture->height);
    ext_image_copy_capture_frame_v1_capture(capture->frame);

    if (wl_display_flush(capture->backend->display) < 0 && errno != EAGAIN) {
        capture->backend->wayland_healthy = false;
        fail_all_captures(capture->backend, "flushing capture request");
    }
}

static void
fail_all_captures(ScreencastBackend *backend, const char *reason)
{
    if (!backend->healthy)
        return;
    backend->healthy = false;
    g_warning("screencast: shared backend failed: %s", reason);
    for (GList *link = backend->captures; link != NULL; link = link->next) {
        ScreencastCapture *capture = link->data;
        capture->failed = true;
        capture->running = false;
    }
}

static gboolean
wayland_io_ready(int fd, GIOCondition condition, gpointer data)
{
    ScreencastBackend *backend = data;
    (void) fd;

    if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL)) {
        backend->wayland_source_id = 0;
        backend->wayland_healthy = false;
        fail_all_captures(backend, "Wayland connection closed");
        return G_SOURCE_REMOVE;
    }

    while (wl_display_prepare_read(backend->display) != 0) {
        if (wl_display_dispatch_pending(backend->display) < 0) {
            backend->wayland_source_id = 0;
            backend->wayland_healthy = false;
            fail_all_captures(backend, "dispatching pending Wayland events");
            return G_SOURCE_REMOVE;
        }
    }
    if (wl_display_read_events(backend->display) < 0 ||
        wl_display_dispatch_pending(backend->display) < 0) {
        backend->wayland_source_id = 0;
        backend->wayland_healthy = false;
        fail_all_captures(backend, "reading Wayland events");
        return G_SOURCE_REMOVE;
    }
    if (wl_display_flush(backend->display) < 0 && errno != EAGAIN) {
        backend->wayland_source_id = 0;
        backend->wayland_healthy = false;
        fail_all_captures(backend, "flushing Wayland requests");
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean
pipewire_io_ready(int fd, GIOCondition condition, gpointer data)
{
    ScreencastBackend *backend = data;
    (void) fd;

    if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL)) {
        backend->pipewire_source_id = 0;
        fail_all_captures(backend, "PipeWire loop closed");
        return G_SOURCE_REMOVE;
    }

    struct pw_loop *loop = pw_main_loop_get_loop(backend->pipewire_loop);
    pw_loop_enter(loop);
    int result = pw_loop_iterate(loop, 0);
    pw_loop_leave(loop);
    if (result < 0 || !backend->healthy) {
        backend->pipewire_source_id = 0;
        if (result < 0)
            fail_all_captures(backend, "iterating PipeWire loop");
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static void
pipewire_core_error(void *data,
                    uint32_t id,
                    int sequence,
                    int result,
                    const char *message)
{
    ScreencastBackend *backend = data;
    (void) sequence;

    if (id == PW_ID_CORE && result < 0)
        fail_all_captures(
            backend, message != NULL ? message : "PipeWire core error");
}

static const struct pw_core_events pipewire_core_events = {
    PW_VERSION_CORE_EVENTS,
    .error = pipewire_core_error,
};

ScreencastBackend *
screencast_backend_new(void)
{
    pw_init(NULL, NULL);

    ScreencastBackend *backend = calloc(1, sizeof(*backend));
    if (backend == NULL)
        return NULL;
    pthread_mutex_init(&backend->outputs_mutex, NULL);
    backend->healthy = true;

    backend->display = wl_display_connect(NULL);
    if (backend->display == NULL) {
        fprintf(stderr, "screencast: failed to connect to Wayland\n");
        goto fail;
    }
    backend->wayland_healthy = true;

    backend->registry = wl_display_get_registry(backend->display);
    wl_registry_add_listener(backend->registry, &registry_listener, backend);
    if (wl_display_roundtrip(backend->display) < 0 ||
        wl_display_roundtrip(backend->display) < 0) {
        backend->wayland_healthy = false;
        backend->healthy = false;
        goto fail;
    }

    if (backend->shm == NULL || backend->source_manager == NULL ||
        backend->capture_manager == NULL) {
        fprintf(stderr,
                "screencast: compositor is missing image capture protocols\n");
        goto fail;
    }

    backend->wayland_source_id = g_unix_fd_add(
        wl_display_get_fd(backend->display),
        G_IO_IN | G_IO_ERR | G_IO_HUP | G_IO_NVAL,
        wayland_io_ready,
        backend);

    backend->pipewire_loop = pw_main_loop_new(NULL);
    if (backend->pipewire_loop == NULL)
        goto fail;
    backend->pipewire_context = pw_context_new(
        pw_main_loop_get_loop(backend->pipewire_loop), NULL, 0);
    if (backend->pipewire_context == NULL)
        goto fail;
    backend->pipewire_core = pw_context_connect(
        backend->pipewire_context, NULL, 0);
    if (backend->pipewire_core == NULL)
        goto fail;
    pw_core_add_listener(backend->pipewire_core,
                         &backend->pipewire_core_hook,
                         &pipewire_core_events,
                         backend);
    backend->pipewire_core_hook_added = true;

    struct pw_loop *loop = pw_main_loop_get_loop(backend->pipewire_loop);
    backend->pipewire_source_id = g_unix_fd_add(
        pw_loop_get_fd(loop),
        G_IO_IN | G_IO_ERR | G_IO_HUP | G_IO_NVAL,
        pipewire_io_ready,
        backend);
    return backend;

fail:
    screencast_backend_free(backend);
    return NULL;
}

static void
screencast_capture_destroy_stream(ScreencastCapture *capture)
{
    if (capture->pipewire_stream == NULL)
        return;
    spa_hook_remove(&capture->stream_hook);
    pw_stream_disconnect(capture->pipewire_stream);
    pw_stream_destroy(capture->pipewire_stream);
    capture->pipewire_stream = NULL;
    capture->node_id = SPA_ID_INVALID;
}

void
screencast_capture_stop(ScreencastCapture *capture)
{
    if (capture == NULL || capture->stopped)
        return;

    capture->stopped = true;
    capture->running = false;
    capture->generation++;
    if (capture->retry_source_id != 0) {
        g_source_remove(capture->retry_source_id);
        capture->retry_source_id = 0;
    }
    bool send_wayland_requests = capture->backend != NULL &&
        capture->backend->wayland_healthy;
    if (capture->frame != NULL) {
        if (send_wayland_requests)
            ext_image_copy_capture_frame_v1_destroy(capture->frame);
        else
            destroy_proxy_locally(capture->frame);
        capture->frame = NULL;
    }
    if (capture->session != NULL) {
        if (send_wayland_requests)
            ext_image_copy_capture_session_v1_destroy(capture->session);
        else
            destroy_proxy_locally(capture->session);
        capture->session = NULL;
    }
    if (capture->source != NULL) {
        if (send_wayland_requests)
            ext_image_capture_source_v1_destroy(capture->source);
        else
            destroy_proxy_locally(capture->source);
        capture->source = NULL;
    }
    screencast_capture_destroy_stream(capture);
    screencast_capture_destroy_shm(capture);
}

void
screencast_capture_free(ScreencastCapture *capture)
{
    if (capture == NULL)
        return;
    screencast_capture_stop(capture);
    if (capture->backend != NULL)
        capture->backend->captures = g_list_remove(
            capture->backend->captures, capture);
    free(capture->latest_data);
    pthread_mutex_destroy(&capture->frame_mutex);
    free(capture);
}

void
screencast_backend_free(ScreencastBackend *backend)
{
    if (backend == NULL)
        return;

    while (backend->captures != NULL)
        screencast_capture_free(backend->captures->data);

    if (backend->wayland_source_id != 0)
        g_source_remove(backend->wayland_source_id);
    if (backend->pipewire_source_id != 0)
        g_source_remove(backend->pipewire_source_id);

    if (backend->pipewire_core_hook_added)
        spa_hook_remove(&backend->pipewire_core_hook);
    if (backend->pipewire_core != NULL)
        pw_core_disconnect(backend->pipewire_core);
    if (backend->pipewire_context != NULL)
        pw_context_destroy(backend->pipewire_context);
    if (backend->pipewire_loop != NULL)
        pw_main_loop_destroy(backend->pipewire_loop);

    pthread_mutex_lock(&backend->outputs_mutex);
    OutputEntry *entry = backend->outputs;
    while (entry != NULL) {
        OutputEntry *next = entry->next;
        if (backend->wayland_healthy)
            wl_output_destroy(entry->output);
        else
            destroy_proxy_locally(entry->output);
        free(entry->name);
        free(entry);
        entry = next;
    }
    pthread_mutex_unlock(&backend->outputs_mutex);
    pthread_mutex_destroy(&backend->outputs_mutex);

    if (backend->wayland_healthy) {
        if (backend->shm != NULL)
            wl_shm_destroy(backend->shm);
        if (backend->source_manager != NULL)
            ext_output_image_capture_source_manager_v1_destroy(
                backend->source_manager);
        if (backend->capture_manager != NULL)
            ext_image_copy_capture_manager_v1_destroy(
                backend->capture_manager);
        if (backend->registry != NULL)
            wl_registry_destroy(backend->registry);
    } else {
        destroy_proxy_locally(backend->shm);
        destroy_proxy_locally(backend->source_manager);
        destroy_proxy_locally(backend->capture_manager);
        destroy_proxy_locally(backend->registry);
    }
    if (backend->display != NULL)
        wl_display_disconnect(backend->display);

    pw_deinit();
    free(backend);
}

bool
screencast_backend_is_healthy(ScreencastBackend *backend)
{
    return backend != NULL && backend->healthy;
}

char **
screencast_backend_list_outputs(ScreencastBackend *backend)
{
    if (backend == NULL || !backend->healthy)
        return NULL;

    pthread_mutex_lock(&backend->outputs_mutex);
    size_t count = 0;
    for (OutputEntry *entry = backend->outputs; entry != NULL;
         entry = entry->next)
        count++;

    char **outputs = g_new0(char *, count + 1);
    if (outputs != NULL) {
        size_t index = 0;
        for (OutputEntry *entry = backend->outputs; entry != NULL;
             entry = entry->next)
            outputs[index++] = g_strdup(
                entry->name != NULL ? entry->name : "output");
    }
    pthread_mutex_unlock(&backend->outputs_mutex);
    return outputs;
}

ScreencastCapture *
screencast_backend_create_capture(ScreencastBackend *backend,
                                  const char *output_name)
{
    if (backend == NULL || !backend->healthy || output_name == NULL)
        return NULL;

    struct wl_output *output = NULL;
    pthread_mutex_lock(&backend->outputs_mutex);
    for (OutputEntry *entry = backend->outputs; entry != NULL;
         entry = entry->next) {
        if (entry->name != NULL && strcmp(entry->name, output_name) == 0) {
            output = entry->output;
            break;
        }
    }
    pthread_mutex_unlock(&backend->outputs_mutex);
    if (output == NULL)
        return NULL;

    ScreencastCapture *capture = calloc(1, sizeof(*capture));
    if (capture == NULL)
        return NULL;
    capture->backend = backend;
    capture->shm_fd = -1;
    capture->node_id = SPA_ID_INVALID;
    capture->running = true;
    capture->generation = 1;
    capture->selected_output = output;
    pthread_mutex_init(&capture->frame_mutex, NULL);

    capture->source =
        ext_output_image_capture_source_manager_v1_create_source(
            backend->source_manager, output);
    if (capture->source == NULL)
        goto fail;
    capture->session = ext_image_copy_capture_manager_v1_create_session(
        backend->capture_manager, capture->source, 0);
    if (capture->session == NULL)
        goto fail;
    ext_image_copy_capture_session_v1_add_listener(
        capture->session, &session_listener, capture);

    backend->captures = g_list_prepend(backend->captures, capture);
    if (wl_display_flush(backend->display) < 0 && errno != EAGAIN) {
        backend->wayland_healthy = false;
        fail_all_captures(backend, "flushing initial capture request");
        goto fail_registered;
    }
    return capture;

fail_registered:
    backend->captures = g_list_remove(backend->captures, capture);
fail:
    screencast_capture_free(capture);
    return NULL;
}

uint32_t
screencast_capture_get_node_id(ScreencastCapture *capture)
{
    return capture != NULL ? capture->node_id : SPA_ID_INVALID;
}

bool
screencast_capture_has_failed(ScreencastCapture *capture)
{
    return capture == NULL || capture->failed || capture->stopped ||
        capture->backend == NULL || !capture->backend->healthy;
}
