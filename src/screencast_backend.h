#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct ScreencastBackend ScreencastBackend;
typedef struct ScreencastCapture ScreencastCapture;

/* Create the shared Wayland/PipeWire manager. */
ScreencastBackend *screencast_backend_new(void);

/* Destroy the manager and any captures that remain. */
void screencast_backend_free(ScreencastBackend *backend);

/* False after a terminal shared Wayland or PipeWire failure. */
bool screencast_backend_is_healthy(ScreencastBackend *backend);

/* Return a NULL-terminated list of output names. Caller uses g_strfreev(). */
char **screencast_backend_list_outputs(ScreencastBackend *backend);

/* Create an independently owned, hidden-cursor monitor capture. */
ScreencastCapture *screencast_backend_create_capture(
    ScreencastBackend *backend,
    const char *output_name);

/* Stop and free one capture. Both operations are safe after partial setup. */
void screencast_capture_stop(ScreencastCapture *capture);
void screencast_capture_free(ScreencastCapture *capture);

/* Returns SPA_ID_INVALID until the PipeWire stream is ready. */
uint32_t screencast_capture_get_node_id(ScreencastCapture *capture);

/* True after a terminal Wayland, PipeWire, constraint, or allocation error. */
bool screencast_capture_has_failed(ScreencastCapture *capture);
