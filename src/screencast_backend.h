#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct ScreencastBackend ScreencastBackend;

#define SCREENCAST_SOURCE_MONITOR 1u
#define SCREENCAST_SOURCE_WINDOW  2u

/* Create a backend: connects to Wayland display and PipeWire.
 * Returns NULL on failure (no compositor / no PipeWire daemon). */
ScreencastBackend *screencast_backend_new(void);

/* Destroy the backend, stopping any active capture. */
void screencast_backend_free(ScreencastBackend *backend);

/* Return a bitmask of SCREENCAST_SOURCE_* values backed by compositor globals. */
uint32_t screencast_backend_get_available_source_types(ScreencastBackend *backend);

/* Returns false after a fatal Wayland connection/protocol error. */
bool screencast_backend_is_healthy(ScreencastBackend *backend);

/* Returns true when an asynchronous start attempt failed before producing a node. */
bool screencast_backend_has_failed(ScreencastBackend *backend);

/* Return a JSON document with available sources:
 * { "sources": [{ "type": u, "id": s, "label": s, "app_id": s }] }
 * Caller must free with g_free(). */
char *screencast_backend_list_sources_json(ScreencastBackend *backend,
    uint32_t requested_types);

/* Start capturing the typed source and exporting via a PipeWire stream.
 * The node_id becomes available asynchronously; poll screencast_backend_get_node_id().
 * Returns 0 on success, -1 if the source is not found. */
int screencast_backend_start(ScreencastBackend *backend, uint32_t source_type,
    const char *source_id, bool paint_cursors);

/* Stop the active capture and disconnect the PipeWire stream. */
void screencast_backend_stop(ScreencastBackend *backend);

/* Returns the PipeWire node id for the stream, or SPA_ID_INVALID (0xffffffff)
 * if not yet available. */
uint32_t screencast_backend_get_node_id(ScreencastBackend *backend);

/* Open a new PipeWire remote connection and return a dup'd socket fd.
 * The caller (portal client) uses this fd with pw_context_connect_fd().
 * Returns -1 on failure. Caller must close() the fd when done. */
int screencast_backend_get_pw_fd(ScreencastBackend *backend);
