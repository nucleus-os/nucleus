/*
 * NucleusCompositorLoop — the compositor loop's token-encoding contract.
 *
 * The compositor event loop is Swift-owned (`CompositorRuntime`, a
 * `SystemPackage.IORing`); bring-up, teardown, completion dispatch, and the
 * platform-fd handlers are all Swift now. This header carries the one thing the
 * loop still needs in C: the reactor-token encoding (`NucleusLoopKind` + the
 * high-byte layout). Swift registers each multishot poll under a kind-tagged token
 * and decodes the kind with `nucleus_loop_kind_of` to route each completion.
 */
#ifndef NUCLEUS_COMPOSITOR_LOOP_H
#define NUCLEUS_COMPOSITOR_LOOP_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Loop event-source kind. The reactor token's high byte carries one of these;
 * the low 56 bits carry an instance key (an fd for per-fd sources, the DRM
 * session generation for `drm`, or 0 for singletons). Swift decodes the kind to
 * route a completion.
 */
typedef enum NucleusLoopKind {
    NUCLEUS_LOOP_KIND_DRM              = 1,
    NUCLEUS_LOOP_KIND_SEAT            = 3,
    NUCLEUS_LOOP_KIND_INPUT          = 4,
    NUCLEUS_LOOP_KIND_DBUS           = 7,
    NUCLEUS_LOOP_KIND_UDEV           = 9,
    NUCLEUS_LOOP_KIND_XWAYLAND_LISTEN = 14,
    NUCLEUS_LOOP_KIND_XWAYLAND_READY = 15,
    NUCLEUS_LOOP_KIND_XWAYLAND_XWM   = 16,
    NUCLEUS_LOOP_KIND_APPEARANCE_PORTAL = 18,
    NUCLEUS_LOOP_KIND_WAYLAND_LOOP   = 21,
    NUCLEUS_LOOP_KIND_EXIT_SIGNAL    = 22,
} NucleusLoopKind;

#define NUCLEUS_LOOP_KIND_SHIFT 56

/* Decode the event-source kind from a reactor token's high byte. */
static inline uint8_t nucleus_loop_kind_of(uint64_t token) {
    return (uint8_t)(token >> NUCLEUS_LOOP_KIND_SHIFT);
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NUCLEUS_COMPOSITOR_LOOP_H */
