// NucleusShellDBusC — importer façade over libsystemd sd-bus, client side.
//
// The compositor's equivalent façade wraps the parts a *service* needs and Swift
// cannot express: the SD_BUS_VTABLE_* designated-initializer macros and the
// variadic message ops. A client needs almost none of that. Every entry point
// used here — open_user/open_system, get_fd/get_events/get_timeout, process,
// flush, add_match, message_new_method_call, message_append_basic, call,
// message_read_basic, enter/exit_container, get_property_trivial/string,
// error_free, unref — is non-variadic and is consumed directly from the upstream
// header by Swift.
//
// What remains are the two things the importer genuinely cannot see: a macro,
// and the size of an opaque error struct at rest.

#ifndef NUCLEUS_SHELL_DBUS_C_H
#define NUCLEUS_SHELL_DBUS_C_H

#include <systemd/sd-bus.h>
#include <string.h>

// SD_BUS_ERROR_NULL is a designated-initializer macro. Zero-initializing the
// struct is equivalent, but doing it behind a function keeps the equivalence in
// one place rather than asserted at each call site.
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

#endif
