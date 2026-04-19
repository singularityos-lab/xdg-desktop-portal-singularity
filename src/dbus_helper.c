#include "dbus_helper.h"

guint portal_register_object(
    GDBusConnection *connection,
    const gchar *path,
    GDBusInterfaceInfo *info,
    GDBusInterfaceMethodCallFunc method_call,
    GDBusInterfaceGetPropertyFunc get_property,
    gpointer user_data,
    GError **error)
{
    static GDBusInterfaceVTable vtable = { NULL, NULL, NULL };
    vtable.method_call = method_call;
    vtable.get_property = get_property;
    return g_dbus_connection_register_object(
        connection, path, info, &vtable, user_data, NULL, error);
}
