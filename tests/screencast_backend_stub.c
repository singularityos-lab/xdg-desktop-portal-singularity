#include "screencast_backend.h"

#include <glib.h>

struct ScreencastBackend {
    gboolean healthy;
};

struct ScreencastCapture {
    uint32_t node_id;
    gboolean failed;
};

ScreencastBackend *
screencast_backend_new(void)
{
    ScreencastBackend *backend = g_new0(ScreencastBackend, 1);
    backend->healthy = TRUE;
    return backend;
}
void
screencast_backend_free(ScreencastBackend *backend)
{
    g_free(backend);
}

bool
screencast_backend_is_healthy(ScreencastBackend *backend)
{
    return backend != NULL && backend->healthy;
}

char **
screencast_backend_list_outputs(ScreencastBackend *backend)
{
    (void) backend;
    char **outputs = g_new0(char *, 2);
    outputs[0] = g_strdup("WL-1");
    return outputs;
}

ScreencastCapture *
screencast_backend_create_capture(ScreencastBackend *backend,
                                  const char *output_name)
{
    if (backend == NULL || output_name == NULL)
        return NULL;
    ScreencastCapture *capture = g_new0(ScreencastCapture, 1);
    capture->node_id = 42;
    return capture;
}

void
screencast_capture_stop(ScreencastCapture *capture)
{
    (void) capture;
}

void
screencast_capture_free(ScreencastCapture *capture)
{
    g_free(capture);
}

uint32_t
screencast_capture_get_node_id(ScreencastCapture *capture)
{
    return capture != NULL ? capture->node_id : 0xffffffffu;
}

bool
screencast_capture_has_failed(ScreencastCapture *capture)
{
    return capture == NULL || capture->failed;
}
