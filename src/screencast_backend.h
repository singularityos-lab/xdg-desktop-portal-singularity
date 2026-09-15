#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct ScreencastBackend ScreencastBackend;
typedef struct ScreencastCapture ScreencastCapture;

#define SCREENCAST_SOURCE_MONITOR 1u
#define SCREENCAST_SOURCE_WINDOW 2u

/* Create a backend: connects to Wayland display and PipeWire.
 * Returns NULL on failure (no compositor / no PipeWire daemon). */
ScreencastBackend *screencast_backend_new(void);

/* Destroy the shared manager and any captures that remain. */
void screencast_backend_free(ScreencastBackend *backend);

uint32_t screencast_backend_get_available_source_types(
    ScreencastBackend *backend);

/* Returns versioned chooser JSON. Caller frees the result with g_free(). */
char *screencast_backend_list_sources_json(ScreencastBackend *backend,
                                           uint32_t requested_types);

/* Create an independently owned capture for the named output. */
ScreencastCapture *screencast_backend_create_capture(
    ScreencastBackend *backend,
    uint32_t source_type,
    const char *source_id,
    bool paint_cursors);

/* Stop and free one capture. Both operations are idempotent. */
void screencast_capture_stop(ScreencastCapture *capture);
void screencast_capture_free(ScreencastCapture *capture);

/* Returns the PipeWire node id for the stream, or SPA_ID_INVALID (0xffffffff)
 * if not yet available. */
uint32_t screencast_capture_get_node_id(ScreencastCapture *capture);

/* True after a terminal Wayland, PipeWire, constraint, or allocation error. */
bool screencast_capture_has_failed(ScreencastCapture *capture);
