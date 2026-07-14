// NucleusSystemdC — importer façade over system libsystemd sd-bus (platform-host
// Stage 7). Swift owns the bus connections, vtables, messages, and dispatch; this
// façade exists only for the parts the Swift clang importer cannot express against
// <systemd/sd-bus.h> directly (Rule 8), provided as first-party `static inline`
// wrappers:
//
//   - the `sd_bus_vtable` array, which upstream builds with the SD_BUS_VTABLE_*
//     designated-initializer macros (unusable from Swift), and
//   - the variadic message ops (`sd_bus_message_read`/`_append`/
//     `_reply_method_return`/`_emit_signal`), which Swift cannot call — one
//     typed wrapper per concrete signature the shell uses.
//
// Every non-variadic sd-bus entry (open/unref/get_fd/process/send/match_signal/
// add_object_vtable/request_name/message new/unref/container open-close/enter-exit/
// read_basic/skip/peek_type/error_free) is consumed directly from the upstream
// header by Swift and is intentionally NOT re-wrapped here.

#ifndef NUCLEUS_SYSTEMD_C_H
#define NUCLEUS_SYSTEMD_C_H

#include <systemd/sd-bus.h>
#include <stddef.h>
#include <stdint.h>

// ── Object vtable construction ──────────────────────────────────────────────
// Swift allocates an `sd_bus_vtable[]` of `nucleus_sdbus_vtable_bytes` bytes and
// fills it one entry at a time: start, then a method/signal per member, then end.
// Each entry is produced by the upstream macro into a one-element array and copied
// into the caller's table at `index`.

// Byte size for a vtable with `method_count` methods + `signal_count` signals
// (plus the mandatory START and END entries).
static inline size_t nucleus_sdbus_vtable_bytes(unsigned method_count, unsigned signal_count) {
    return (size_t)(2u + method_count + signal_count) * sizeof(sd_bus_vtable);
}

static inline void nucleus_sdbus_vtable_start(sd_bus_vtable *table, size_t index) {
    const sd_bus_vtable e[] = { SD_BUS_VTABLE_START(0) };
    table[index] = e[0];
}

static inline void nucleus_sdbus_vtable_method(sd_bus_vtable *table, size_t index,
                                               const char *member, const char *signature,
                                               const char *result, sd_bus_message_handler_t handler) {
    const sd_bus_vtable e[] = { SD_BUS_METHOD(member, signature, result, handler, 0) };
    table[index] = e[0];
}

static inline void nucleus_sdbus_vtable_signal(sd_bus_vtable *table, size_t index,
                                               const char *member, const char *signature) {
    const sd_bus_vtable e[] = { SD_BUS_SIGNAL(member, signature, 0) };
    table[index] = e[0];
}

static inline void nucleus_sdbus_vtable_end(sd_bus_vtable *table, size_t index) {
    const sd_bus_vtable e[] = { SD_BUS_VTABLE_END };
    table[index] = e[0];
}

// ── Typed message reads (variadic sd_bus_message_read) ──────────────────────
// Each returns the sd_bus_message_read result (>=0 ok). Out string pointers
// borrow message-owned storage valid until the message is unref'd.

static inline int nucleus_sdbus_read_sus(sd_bus_message *m, const char **s0, uint32_t *u, const char **s1) {
    return sd_bus_message_read(m, "sus", s0, u, s1);
}
static inline int nucleus_sdbus_read_ss(sd_bus_message *m, const char **s0, const char **s1) {
    return sd_bus_message_read(m, "ss", s0, s1);
}
static inline int nucleus_sdbus_read_u(sd_bus_message *m, uint32_t *u) {
    return sd_bus_message_read(m, "u", u);
}
static inline int nucleus_sdbus_read_i(sd_bus_message *m, int32_t *i) {
    return sd_bus_message_read(m, "i", i);
}
static inline int nucleus_sdbus_read_variant_u(sd_bus_message *m, uint32_t *u) {
    return sd_bus_message_read(m, "v", "u", u);
}

// ── Typed replies (variadic sd_bus_reply_method_return) ─────────────────────
static inline int nucleus_sdbus_reply_u(sd_bus_message *call, uint32_t u) {
    return sd_bus_reply_method_return(call, "u", u);
}
static inline int nucleus_sdbus_reply_empty(sd_bus_message *call) {
    return sd_bus_reply_method_return(call, "");
}
static inline int nucleus_sdbus_reply_ssss(sd_bus_message *call, const char *a, const char *b,
                                           const char *c, const char *d) {
    return sd_bus_reply_method_return(call, "ssss", a, b, c, d);
}

// ── Typed appends (variadic sd_bus_message_append) ──────────────────────────
static inline int nucleus_sdbus_append_s(sd_bus_message *m, const char *s) {
    return sd_bus_message_append(m, "s", s);
}

// ── Typed signal emit (variadic sd_bus_emit_signal) ─────────────────────────
static inline int nucleus_sdbus_emit_uu(sd_bus *bus, const char *path, const char *iface,
                                        const char *member, uint32_t a, uint32_t b) {
    return sd_bus_emit_signal(bus, path, iface, member, "uu", a, b);
}

#endif // NUCLEUS_SYSTEMD_C_H
