#pragma once
#include <gio/gio.h>

guint portal_register_object(
    GDBusConnection *connection,
    const gchar *path,
    GDBusInterfaceInfo *info,
    GDBusInterfaceMethodCallFunc method_call,
    GDBusInterfaceGetPropertyFunc get_property,
    gpointer user_data,
    GError **error);
