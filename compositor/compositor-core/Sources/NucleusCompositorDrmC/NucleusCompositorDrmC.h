/*
 * NucleusDrmC — the Swift-facing importer façade over system libdrm + Mesa GBM.
 * It moves DRM device enumeration, modesetting, atomic KMS, page-flip handling,
 * session/VT, scanout policy, and physical presentation from Zig into
 * Swift on top of real libdrm and GBM. Swift consumes the upstream `drmMode*`
 * resource/property/atomic/framebuffer/event APIs, the `drm*` device/cap/syncobj
 * helpers, and the GBM device/BO API directly through the headers imported here;
 * it replaces the hand-rolled pure-Zig `drmMode*` reimplementation in
 * `valence/drm/mode_*.zig` (which issues ioctls directly and links no libdrm).
 *
 * Per Rule 7 this exposes the upstream libdrm + GBM headers unchanged. Per Rule 8
 * it adds first-party `static inline` façades only for the importer-hostile bits:
 * the DMA-BUF sync-file ioctls whose `_IOWR`/`_IOW` request numbers the Swift
 * clang importer cannot evaluate as constants, plus a link probe. It reproduces
 * no libdrm or GBM state machine.
 *
 * libdrm and GBM ship clang-importable C headers (both carry their own
 * `extern "C"` guards), so — unlike NucleusWaylandC — this needs no code
 * generator: the module is this façade header plus a module map over the system
 * (`drm`).
 */
#ifndef NUCLEUS_DRM_C_H
#define NUCLEUS_DRM_C_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <sys/ioctl.h>

/* Upstream libdrm: the generic helpers (device enumeration, caps, syncobj,
 * version, PRIME) and the KMS resource/property/atomic/framebuffer/event API. */
#include <xf86drm.h>
#include <xf86drmMode.h>
/* FourCC format + modifier tokens (DRM_FORMAT_*, DRM_FORMAT_MOD_*). */
#include <drm_fourcc.h>

/* Mesa GBM: scanout/buffer-object allocation and DMA-BUF plane export. */
#include <gbm.h>

/* Kernel DMA-BUF implicit-sync ioctls. Provides the `struct
 * dma_buf_{export,import}_sync_file` records and the `DMA_BUF_IOCTL_*` request
 * macros the façades below evaluate. */
#include <linux/dma-buf.h>
#include <linux/sync_file.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Open a DRM device node read/write + close-on-exec. The render-node open the
 * Swift DRM owner does itself (the primary node still routes through libseat for
 * DRM-master negotiation). `open` is variadic, which the Swift importer won't
 * call directly — same reason NucleusXcbC wraps it.
 */
static inline int nucleus_drm_open_device(const char *path) {
    return open(path, O_RDWR | O_CLOEXEC);
}

/*
 * Page-flip / vblank completion callback, fed by `nucleus_drm_handle_event`.
 * `user_data` is whatever was set on the atomic commit (the per-output token);
 * `timestamp_ns` is the kernel event time folded to nanoseconds.
 */
typedef void (*nucleus_drm_page_flip_cb)(void *user_data, uint64_t timestamp_ns,
                                         uint32_t sequence, uint32_t crtc_id);

/*
 * Swift-compatible façade over libdrm's `drmHandleEvent`. The libdrm
 * `drmEventContext` dispatches through bare C function pointers that cannot
 * capture context, so this builds the context with a file-static trampoline and
 * routes every page-flip completion to the single `cb` (a Swift @convention(c)
 * function) with the event's `user_data`. Synchronous and single-threaded: the
 * current callback is stashed only for the duration of the drmHandleEvent call.
 * Returns drmHandleEvent's result (0 on success). Caller must ensure the fd is
 * readable first (see nucleus_drm_fd_poll_readable) — drmHandleEvent reads the
 * fd and would block on an empty blocking fd.
 */
static nucleus_drm_page_flip_cb g_nucleus_drm_page_flip_cb;

static void nucleus_drm__page_flip2(int fd, unsigned int sequence,
                                    unsigned int tv_sec, unsigned int tv_usec,
                                    unsigned int crtc_id, void *user_data) {
    (void)fd;
    if (g_nucleus_drm_page_flip_cb) {
        uint64_t ts = (uint64_t)tv_sec * 1000000000ull + (uint64_t)tv_usec * 1000ull;
        g_nucleus_drm_page_flip_cb(user_data, ts, (uint32_t)sequence, (uint32_t)crtc_id);
    }
}

static inline int nucleus_drm_handle_event(int fd, nucleus_drm_page_flip_cb cb) {
    g_nucleus_drm_page_flip_cb = cb;
    drmEventContext ctx;
    memset(&ctx, 0, sizeof ctx);
    // page_flip_handler2 (carries crtc_id) requires context version >= 3.
    ctx.version = 3;
    ctx.page_flip_handler2 = nucleus_drm__page_flip2;
    int rc = drmHandleEvent(fd, &ctx);
    g_nucleus_drm_page_flip_cb = (nucleus_drm_page_flip_cb)0;
    return rc;
}

/*
 * Non-blocking readability probe for the DRM event fd. Returns 1 when a read
 * would not block (events pending), 0 otherwise. Lets the Swift event pump avoid
 * blocking inside drmHandleEvent when there is nothing to drain.
 */
static inline int nucleus_drm_fd_poll_readable(int fd) {
    struct pollfd p;
    p.fd = fd;
    p.events = POLLIN;
    p.revents = 0;
    int rc = poll(&p, 1, 0);
    return (rc > 0 && (p.revents & POLLIN)) ? 1 : 0;
}

/*
 * Probe whether `fd` is still an open descriptor (F_GETFD succeeds). `fcntl` is
 * variadic, which the Swift importer won't call directly; used by ownership
 * tests to assert close/release semantics. Returns 1 if open, 0 otherwise.
 */
static inline int nucleus_drm_fd_is_open(int fd) {
    return fcntl(fd, F_GETFD) != -1 ? 1 : 0;
}

/*
 * A stable Swift-facing snapshot of a Linux sync_file. `latest_timestamp_ns` is
 * the latest status-change timestamp across every constituent fence, in
 * CLOCK_MONOTONIC nanoseconds. It is zero while the sync_file is active or when
 * the kernel reports no constituent fences. Returns 0 on success, -1 for an
 * invalid fd, a non-sync_file fd, allocation failure, or ioctl failure.
 */
struct nucleus_drm_sync_file_snapshot {
    int32_t status;
    uint32_t fence_count;
    uint64_t latest_timestamp_ns;
};

static inline int nucleus_drm_get_sync_file_snapshot(
    int fd, struct nucleus_drm_sync_file_snapshot *out
) {
    if (fd < 0 || out == NULL) return -1;
    memset(out, 0, sizeof(*out));

    struct sync_file_info file_info;
    memset(&file_info, 0, sizeof(file_info));
    if (ioctl(fd, SYNC_IOC_FILE_INFO, &file_info) != 0) return -1;

    out->status = file_info.status;
    out->fence_count = file_info.num_fences;
    if (file_info.num_fences == 0) return 0;

    struct sync_fence_info *fences = (struct sync_fence_info *)calloc(
        file_info.num_fences, sizeof(struct sync_fence_info));
    if (fences == NULL) return -1;
    file_info.sync_fence_info = (uint64_t)(uintptr_t)fences;
    int rc = ioctl(fd, SYNC_IOC_FILE_INFO, &file_info);
    if (rc == 0) {
        uint64_t latest = 0;
        for (uint32_t index = 0; index < file_info.num_fences; ++index) {
            if (fences[index].timestamp_ns > latest) {
                latest = fences[index].timestamp_ns;
            }
        }
        out->status = file_info.status;
        out->fence_count = file_info.num_fences;
        out->latest_timestamp_ns = latest;
    }
    free(fences);
    return rc == 0 ? 0 : -1;
}

/*
 * Export a sync_file fd from a DMA-BUF's implicit reservation (the kernel's
 * DMA_BUF_IOCTL_EXPORT_SYNC_FILE). `flags` selects the access direction
 * (DMA_BUF_SYNC_READ / DMA_BUF_SYNC_WRITE / DMA_BUF_SYNC_RW). Returns the
 * exported sync_file fd (caller owns it) or -1 on failure. The `_IOWR` request
 * number is a macro the Swift importer cannot fold to a constant, so the ioctl
 * is issued here.
 */
static inline int nucleus_drm_dmabuf_export_sync_file(int dmabuf_fd, uint32_t flags) {
    if (dmabuf_fd < 0) return -1;
    struct dma_buf_export_sync_file req = { .flags = flags, .fd = -1 };
    if (ioctl(dmabuf_fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &req) != 0) return -1;
    return req.fd;
}

/*
 * Attach a sync_file fence to a DMA-BUF's implicit reservation (the kernel's
 * DMA_BUF_IOCTL_IMPORT_SYNC_FILE). `flags` selects the access direction as
 * above. The kernel dups `sync_fd`; the caller still owns it on return.
 * Returns 0 on success, -1 on failure.
 */
static inline int nucleus_drm_dmabuf_import_sync_file(int dmabuf_fd, uint32_t flags, int sync_fd) {
    if (dmabuf_fd < 0) return -1;
    struct dma_buf_import_sync_file req = { .flags = flags, .fd = sync_fd };
    if (ioctl(dmabuf_fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &req) != 0) return -1;
    return 0;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NUCLEUS_DRM_C_H */
