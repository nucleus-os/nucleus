#ifndef NUCLEUS_LINUX_DBUS_C_H
#define NUCLEUS_LINUX_DBUS_C_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <systemd/sd-bus.h>

// Keep macro/opaque-layout knowledge and the variadic calls that Swift cannot
// import in this one façade. Non-variadic sd-bus entry points remain directly
// visible to the NucleusLinuxDBus implementation.
static inline void nucleus_dbus_error_init(sd_bus_error *error) {
    if (error != NULL) { memset(error, 0, sizeof(*error)); }
}

static inline int nucleus_dbus_error_is_set(const sd_bus_error *error) {
    return error != NULL && error->name != NULL;
}

static inline const char *nucleus_dbus_error_name(const sd_bus_error *error) {
    return (error != NULL && error->name != NULL) ? error->name : "";
}

static inline const char *nucleus_dbus_error_message(const sd_bus_error *error) {
    return (error != NULL && error->message != NULL) ? error->message : "";
}

static inline const char *nucleus_dbus_message_error_name(sd_bus_message *message) {
    const sd_bus_error *error = sd_bus_message_get_error(message);
    return (error != NULL && error->name != NULL) ? error->name : "";
}

static inline const char *nucleus_dbus_message_error_message(sd_bus_message *message) {
    const sd_bus_error *error = sd_bus_message_get_error(message);
    return (error != NULL && error->message != NULL) ? error->message : "";
}

static inline int nucleus_dbus_message_is_error(sd_bus_message *message) {
    return sd_bus_message_is_method_error(message, NULL) > 0;
}

static inline int nucleus_dbus_reply_error(sd_bus_message *call,
                                           const char *name,
                                           const char *message) {
    return sd_bus_reply_method_errorf(call, name, "%s",
                                      message != NULL ? message : "");
}

#endif
