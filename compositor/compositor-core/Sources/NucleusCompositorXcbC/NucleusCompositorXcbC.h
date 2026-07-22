/*
 * NucleusXcbC — the Swift-facing importer façade over system libxcb + xcb-util.
 * It moves the X window manager, including the XCB connection, X event loop,
 * atoms, ICCCM/EWMH property parsing, selections, cursors, and Xwayland process
 * supervision) from Zig into Swift. Swift drives XCB directly through the
 * upstream C headers imported by this module; it replaces the generated Zig
 * `xcb` binding and the hand-written `valence/xcb_extras.zig`.
 *
 * Per Rule 7 this exposes the upstream XCB headers unchanged — Swift consumes
 * `xcb_connect`, the `xcb_*_reply`/cookie machinery, and the xcb-util ICCCM/EWMH
 * structs directly. Per Rule 8 it adds first-party `static inline` façades only
 * for the importer-hostile bits XCB exposes through macros (iterator walks,
 * fixed-array property accessors) plus a link probe. It reproduces no XCB state
 * machine.
 *
 * XCB ships clang-importable C headers, so — unlike NucleusWaylandC — this needs
 * no code generator: the module is this façade header plus a module map over the
 * system libraries the compositor already links.
 */
#ifndef NUCLEUS_XCB_C_H
#define NUCLEUS_XCB_C_H

#include <stdint.h>
#include <fcntl.h>

#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>
#include <xcb/xcb_ewmh.h>
#include <xcb/xcbext.h>
#include <xcb/composite.h>
#include <xcb/xfixes.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * XFixes extension data. The `xcb_extension_t xcb_xfixes_id` symbol has an
 * incomplete type from <xcb/xfixes.h> alone, so Swift can't take its address
 * (the Zig XWM used @extern for the same reason). This façade resolves the
 * extension on the C side and hands back the presence flag + event base.
 */
static inline uint8_t nucleus_xcb_xfixes_event_base(xcb_connection_t *c, uint8_t *out_present) {
    const xcb_query_extension_reply_t *ext = xcb_get_extension_data(c, &xcb_xfixes_id);
    if (!ext) {
        *out_present = 0;
        return 0;
    }
    *out_present = ext->present;
    return ext->first_event;
}

/*
 * fd / open façades over the variadic libc primitives (open, fcntl) Swift's Glibc
 * overlay doesn't import cleanly, used by the Xwayland process supervisor.
 */
static inline int nucleus_open2(const char *path, int flags) {
    return open(path, flags);
}
static inline int nucleus_open3(const char *path, int flags, unsigned int mode) {
    return open(path, flags, (mode_t)mode);
}
static inline int nucleus_fd_clear_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFD, flags & ~FD_CLOEXEC);
}
static inline int nucleus_fd_clear_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NUCLEUS_XCB_C_H */
