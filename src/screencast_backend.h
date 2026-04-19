#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct ScreencastBackend ScreencastBackend;

/* Create a backend: connects to Wayland display and PipeWire.
 * Returns NULL on failure (no compositor / no PipeWire daemon). */
ScreencastBackend *screencast_backend_new(void);

/* Destroy the backend, stopping any active capture. */
void screencast_backend_free(ScreencastBackend *backend);

/* Return a NULL-terminated GStrv of available output names.
 * Caller must free with g_strfreev(). */
char **screencast_backend_list_outputs(ScreencastBackend *backend);

/* Start capturing the named output and exporting via a PipeWire stream.
 * The node_id becomes available asynchronously; poll screencast_backend_get_node_id().
 * Returns 0 on success, -1 if the output is not found. */
int screencast_backend_start(ScreencastBackend *backend, const char *output_name);

/* Stop the active capture and disconnect the PipeWire stream. */
void screencast_backend_stop(ScreencastBackend *backend);

/* Returns the PipeWire node id for the stream, or SPA_ID_INVALID (0xffffffff)
 * if not yet available. */
uint32_t screencast_backend_get_node_id(ScreencastBackend *backend);

/* Open a new PipeWire remote connection and return a dup'd socket fd.
 * The caller (portal client) uses this fd with pw_context_connect_fd().
 * Returns -1 on failure. Caller must close() the fd when done. */
int screencast_backend_get_pw_fd(ScreencastBackend *backend);
