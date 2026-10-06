#include "toplevel_monitor.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <glib-unix.h>
#include <wayland-client.h>

#include "ext-foreign-toplevel-list-v1-client-protocol.h"

typedef struct Toplevel {
    ToplevelMonitor *monitor;
    struct ext_foreign_toplevel_handle_v1 *handle;
    char *app_id;
    char *pending_app_id;
} Toplevel;

struct ToplevelMonitor {
    struct wl_display *display;
    struct wl_registry *registry;
    struct ext_foreign_toplevel_list_v1 *list;
    GPtrArray *toplevels;
    guint source_id;
    ToplevelMonitorChanged changed;
    gpointer user_data;
};

static void
toplevel_free(gpointer data)
{
    Toplevel *toplevel = data;
    if (toplevel->handle != NULL)
        ext_foreign_toplevel_handle_v1_destroy(toplevel->handle);
    g_free(toplevel->app_id);
    g_free(toplevel->pending_app_id);
    g_free(toplevel);
}

static void
notify_changed(ToplevelMonitor *monitor)
{
    if (monitor->changed != NULL)
        monitor->changed(monitor->user_data);
}

static void
handle_closed(void *data, struct ext_foreign_toplevel_handle_v1 *handle)
{
    Toplevel *toplevel = data;
    ToplevelMonitor *monitor = toplevel->monitor;
    (void) handle;
    g_ptr_array_remove(monitor->toplevels, toplevel);
    notify_changed(monitor);
}

static void
handle_done(void *data, struct ext_foreign_toplevel_handle_v1 *handle)
{
    Toplevel *toplevel = data;
    (void) handle;
    if (toplevel->pending_app_id == NULL)
        return;
    if (g_strcmp0(toplevel->app_id, toplevel->pending_app_id) == 0) {
        g_clear_pointer(&toplevel->pending_app_id, g_free);
        return;
    }
    g_free(toplevel->app_id);
    toplevel->app_id = toplevel->pending_app_id;
    toplevel->pending_app_id = NULL;
    notify_changed(toplevel->monitor);
}

static void
handle_title(void *data, struct ext_foreign_toplevel_handle_v1 *handle, const char *title)
{
    (void) data;
    (void) handle;
    (void) title;
}

static void
handle_app_id(void *data, struct ext_foreign_toplevel_handle_v1 *handle, const char *app_id)
{
    Toplevel *toplevel = data;
    (void) handle;
    g_free(toplevel->pending_app_id);
    toplevel->pending_app_id = g_strdup(app_id);
}

static void
handle_identifier(void *data, struct ext_foreign_toplevel_handle_v1 *handle, const char *identifier)
{
    (void) data;
    (void) handle;
    (void) identifier;
}

static const struct ext_foreign_toplevel_handle_v1_listener handle_listener = {
    .closed = handle_closed,
    .done = handle_done,
    .title = handle_title,
    .app_id = handle_app_id,
    .identifier = handle_identifier,
};

static void
list_toplevel(void *data, struct ext_foreign_toplevel_list_v1 *list,
              struct ext_foreign_toplevel_handle_v1 *handle)
{
    ToplevelMonitor *monitor = data;
    (void) list;
    Toplevel *toplevel = g_new0(Toplevel, 1);
    toplevel->monitor = monitor;
    toplevel->handle = handle;
    g_ptr_array_add(monitor->toplevels, toplevel);
    ext_foreign_toplevel_handle_v1_add_listener(handle, &handle_listener, toplevel);
}

static void
list_finished(void *data, struct ext_foreign_toplevel_list_v1 *list)
{
    ToplevelMonitor *monitor = data;
    (void) list;
    g_clear_pointer(&monitor->list, ext_foreign_toplevel_list_v1_destroy);
}

static const struct ext_foreign_toplevel_list_v1_listener list_listener = {
    .toplevel = list_toplevel,
    .finished = list_finished,
};

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
                const char *interface, uint32_t version)
{
    ToplevelMonitor *monitor = data;
    if (strcmp(interface, ext_foreign_toplevel_list_v1_interface.name) != 0 || monitor->list != NULL)
        return;
    monitor->list = wl_registry_bind(registry, name, &ext_foreign_toplevel_list_v1_interface,
                                     version < 1 ? version : 1);
    ext_foreign_toplevel_list_v1_add_listener(monitor->list, &list_listener, monitor);
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void) data;
    (void) registry;
    (void) name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void
disconnect(ToplevelMonitor *monitor)
{
    if (monitor->source_id != 0) {
        g_source_remove(monitor->source_id);
        monitor->source_id = 0;
    }
    g_ptr_array_set_size(monitor->toplevels, 0);
    g_clear_pointer(&monitor->list, ext_foreign_toplevel_list_v1_destroy);
    g_clear_pointer(&monitor->registry, wl_registry_destroy);
    g_clear_pointer(&monitor->display, wl_display_disconnect);
}

static gboolean
wayland_ready(int fd, GIOCondition condition, gpointer data)
{
    ToplevelMonitor *monitor = data;
    (void) fd;
    if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL))
        goto lost;
    while (wl_display_prepare_read(monitor->display) != 0) {
        if (wl_display_dispatch_pending(monitor->display) < 0)
            goto lost;
    }
    if (wl_display_read_events(monitor->display) < 0 ||
        wl_display_dispatch_pending(monitor->display) < 0)
        goto lost;
    if (wl_display_flush(monitor->display) < 0 && errno != EAGAIN)
        goto lost;
    return G_SOURCE_CONTINUE;

lost:
    monitor->source_id = 0;
    disconnect(monitor);
    notify_changed(monitor);
    return G_SOURCE_REMOVE;
}

ToplevelMonitor *
toplevel_monitor_new(ToplevelMonitorChanged changed, gpointer user_data)
{
    ToplevelMonitor *monitor = g_new0(ToplevelMonitor, 1);
    monitor->toplevels = g_ptr_array_new_with_free_func(toplevel_free);
    monitor->changed = changed;
    monitor->user_data = user_data;
    return monitor;
}

void
toplevel_monitor_free(ToplevelMonitor *monitor)
{
    if (monitor == NULL)
        return;
    disconnect(monitor);
    g_ptr_array_unref(monitor->toplevels);
    g_free(monitor);
}

gboolean
toplevel_monitor_is_connected(ToplevelMonitor *monitor)
{
    return monitor->display != NULL && monitor->list != NULL;
}

gboolean
toplevel_monitor_connect(ToplevelMonitor *monitor)
{
    if (monitor->display != NULL)
        return monitor->list != NULL;
    monitor->display = wl_display_connect(NULL);
    if (monitor->display == NULL)
        return FALSE;
    monitor->registry = wl_display_get_registry(monitor->display);
    wl_registry_add_listener(monitor->registry, &registry_listener, monitor);
    if (wl_display_roundtrip(monitor->display) < 0 || monitor->list == NULL ||
        wl_display_roundtrip(monitor->display) < 0) {
        disconnect(monitor);
        return FALSE;
    }
    monitor->source_id = g_unix_fd_add(wl_display_get_fd(monitor->display),
                                       G_IO_IN | G_IO_ERR | G_IO_HUP | G_IO_NVAL,
                                       wayland_ready, monitor);
    return TRUE;
}

gchar **
toplevel_monitor_list_app_ids(ToplevelMonitor *monitor)
{
    GPtrArray *ids = g_ptr_array_new();
    for (guint i = 0; i < monitor->toplevels->len; i++) {
        Toplevel *toplevel = g_ptr_array_index(monitor->toplevels, i);
        if (toplevel->app_id == NULL || toplevel->app_id[0] == '\0')
            continue;
        gboolean seen = FALSE;
        for (guint j = 0; j < ids->len; j++) {
            if (strcmp(g_ptr_array_index(ids, j), toplevel->app_id) == 0)
                seen = TRUE;
        }
        if (!seen)
            g_ptr_array_add(ids, g_strdup(toplevel->app_id));
    }
    g_ptr_array_add(ids, NULL);
    return (gchar **) g_ptr_array_free(ids, FALSE);
}
