#include <glib.h>

#include "screencast_backend.h"

struct ScreencastBackend {
    guint unused;
};

struct ScreencastCapture {
    uint32_t node_id;
    gboolean stopped;
};

ScreencastBackend *
screencast_backend_new(void)
{
    return g_new0(ScreencastBackend, 1);
}

void
screencast_backend_free(ScreencastBackend *backend)
{
    g_free(backend);
}

uint32_t
screencast_backend_get_available_source_types(ScreencastBackend *backend)
{
    (void) backend;
    return SCREENCAST_SOURCE_MONITOR;
}

char *
screencast_backend_list_sources_json(ScreencastBackend *backend,
                                     uint32_t requested_types)
{
    (void) backend;
    (void) requested_types;
    return g_strdup("{\"version\":1,\"sources\":[]}");
}

ScreencastCapture *
screencast_backend_create_capture(ScreencastBackend *backend,
                                  uint32_t source_type,
                                  const char *source_id,
                                  bool paint_cursors)
{
    (void) backend;
    (void) source_type;
    (void) source_id;
    (void) paint_cursors;
    ScreencastCapture *capture = g_new0(ScreencastCapture, 1);
    capture->node_id = 42;
    return capture;
}

void
screencast_capture_stop(ScreencastCapture *capture)
{
    if (capture != NULL)
        capture->stopped = TRUE;
}

uint32_t
screencast_capture_get_node_id(ScreencastCapture *capture)
{
    return capture != NULL ? capture->node_id : UINT32_MAX;
}

bool
screencast_capture_has_failed(ScreencastCapture *capture)
{
    return capture == NULL;
}

void
screencast_capture_free(ScreencastCapture *capture)
{
    g_free(capture);
}
