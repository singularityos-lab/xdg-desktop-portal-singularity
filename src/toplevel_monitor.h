#pragma once
#include <glib.h>

typedef struct ToplevelMonitor ToplevelMonitor;
typedef void (*ToplevelMonitorChanged)(gpointer user_data);

ToplevelMonitor *toplevel_monitor_new(ToplevelMonitorChanged changed, gpointer user_data);
void toplevel_monitor_free(ToplevelMonitor *monitor);
gboolean toplevel_monitor_is_connected(ToplevelMonitor *monitor);
gboolean toplevel_monitor_connect(ToplevelMonitor *monitor);
gchar **toplevel_monitor_list_app_ids(ToplevelMonitor *monitor);
