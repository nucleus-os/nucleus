// The live GBM scanout-buffer allocator: create a scanout-capable
// GBM buffer object, export it as a DMA-BUF, import that as a Vulkan image (with
// the scanout usage Graphite render-target wrapping requires), and package the
// coupled GBM ↔ Vulkan ↔ KMS lifetimes into `OutputBufferOwner`. The renderer
// composites into this buffer before DrmOutput submits it for scanout.
//
// LIFETIME CONTRACT (mirrors `OutputBufferOwner`'s reverse-order teardown):
//   - The GBM BO owns the physical scanout memory. It outlives the Vulkan image
//     (which only imports the BO's exported dmabuf fd as dedicated memory) and the
//     KMS framebuffer (which references the BO's plane handles).
//   - Teardown order is fb → image → BO: remove the KMS fb first (it borrows the
//     BO planes), then drop the Vulkan image+memory, then destroy the BO.
//   - The entire owner is destroyed BEFORE the Graphite context — a Skia surface
//     wrapping the imported image must not outlive its backing, and the image must
//     not outlive the context that wraps it.
//
// The allocator hands back the imported `VkOwned<VkImage>` (moved out) plus the
// raw BO pointer and the plane layout. The caller packages them into an
// `OutputBufferOwner` via `makeOwner`, which captures the three destroy verbs.

import NucleusCompositorDrmC
import NucleusRenderer
package import Vulkan
package import VulkanC

/// One plane's GBM-reported layout, as needed for both the Vulkan import
/// (offset/stride) and a KMS `drmModeAddFB2WithModifiers` (handle/offset/stride).
package struct GbmPlaneLayout: Equatable, Sendable {
    package var offset: UInt32
    package var stride: UInt32
    package var handle: UInt32
    package init(offset: UInt32, stride: UInt32, handle: UInt32) {
        self.offset = offset
        self.stride = stride
        self.handle = handle
    }
}

/// The product of a successful GBM scanout allocation + Vulkan import. Carries the
/// imported Vulkan image (noncopyable — moved into the owner), the raw BO, the
/// chosen format/modifier, and the per-plane layout. The BO is owned here until
/// `makeOwner` packages it; on the failure paths inside `allocate` the BO is
/// destroyed before returning nil.
///
/// This is an internal allocation detail of `DRMScanoutPresenter`, not a
/// presentation backend or cross-module ownership surface.
@unsafe struct DRMScanoutBufferAllocation: ~Copyable {
    /// The imported scanout image. `consuming`-moved into the `OutputBufferOwner`.
    package var image: VkOwned<VkImage>
    /// The raw `gbm_bo*`. Owned here; destroyed by the owner's `destroyBuffer`.
    package let bo: OpaquePointer
    package let width: UInt32
    package let height: UInt32
    package let drmFormat: UInt32
    package let modifier: UInt64
    package let planes: [GbmPlaneLayout]
    /// A dup'd dmabuf fd kept for a possible KMS import path, or -1 when none was
    /// retained (the import consumed the original fd). The owner closes it if >= 0.
    package let keptDmaBufFd: Int32

    package init(
        image: consuming VkOwned<VkImage>,
        bo: OpaquePointer,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [GbmPlaneLayout],
        keptDmaBufFd: Int32
    ) {
        unsafe self.image = image
        unsafe self.bo = bo
        unsafe self.width = width
        unsafe self.height = height
        unsafe self.drmFormat = drmFormat
        unsafe self.modifier = modifier
        unsafe self.planes = planes
        unsafe self.keptDmaBufFd = keptDmaBufFd
    }

    /// Which GBM allocation path to take. Scanout-capable buffers need
    /// `GBM_BO_USE_SCANOUT` and a primary node with DRM master; a render node has
    /// neither, so the fixture (and any GPU-only consumer) falls back to
    /// `renderableOnly`, which the GBM/Vulkan round-trip can still exercise.
    package enum Usage {
        /// `GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING` — the live presentation buffer.
        case scanout
        /// `GBM_BO_USE_RENDERING` (+ linear) — GPU-only, no KMS master needed.
        case renderableOnly
    }

    /// Allocate a scanout-capable BO on `gbmDevice`, export it as a dmabuf, and
    /// import it as a Vulkan image with `DmaBufImageDescriptor.scanoutUsage`. When
    /// `modifiers` is non-empty, allocate modifier-explicitly; otherwise use the
    /// usage-flag path. Returns nil (after destroying any allocated BO) on failure.
    ///
    /// SINGLE-FD ASSUMPTION: `gbm_bo_get_fd` exports one fd covering the whole BO;
    /// for the single-plane XRGB8888 scanout buffer every plane shares it. A
    /// multi-plane BO whose planes live in distinct dmabufs is out of scope here
    /// (the scanout format is single-plane).
    ///
    /// `keepDmaBufFdForKms`: when true, `dup()` the exported fd before the import
    /// consumes it, so a KMS `drmModeAddFB2WithModifiers` import remains possible.
    package static func allocate(
        gbmDevice: OpaquePointer,
        drmFormat: UInt32,
        width: UInt32,
        height: UInt32,
        modifiers: [UInt64],
        usage: Usage,
        device: VkDevice,
        dispatch: VK.DeviceDispatch,
        keepDmaBufFdForKms: Bool = false
    ) -> DRMScanoutBufferAllocation? {
        guard width > 0,
            height > 0,
            let modifierCount = UInt32(exactly: modifiers.count)
        else { return nil }
        // a. Allocate the BO. Prefer the modifier-explicit path when modifiers are
        // supplied; else the usage-flag path.
        let bo: OpaquePointer?
        if !modifiers.isEmpty {
            unsafe bo = modifiers.withUnsafeBufferPointer { mods in
                unsafe gbm_bo_create_with_modifiers(
                    gbmDevice, width, height, drmFormat,
                    mods.baseAddress, modifierCount)
            }
        } else {
            let flags: UInt32
            switch usage {
            case .scanout:
                flags = GBM_BO_USE_SCANOUT.rawValue | GBM_BO_USE_RENDERING.rawValue
            case .renderableOnly:
                flags = GBM_BO_USE_RENDERING.rawValue
            }
            unsafe bo = gbm_bo_create(
                gbmDevice, width, height, drmFormat, flags)
        }
        guard let bo = unsafe bo else {
            logRendererDrm("gbm_bo_create failed errno=\(rendererErrno())")
            return nil
        }

        // b. Read the plane layout + modifier, then export the dmabuf fd.
        let planeCount = unsafe Int(gbm_bo_get_plane_count(bo))
        guard (1...3).contains(planeCount) else {
            logRendererDrm("GBM BO reported unsupported plane count=\(planeCount)")
            unsafe gbm_bo_destroy(bo)
            return nil
        }
        var planes: [GbmPlaneLayout] = []
        planes.reserveCapacity(planeCount)
        for plane in 0..<planeCount {
            let p = Int32(plane)
            planes.append(
                unsafe GbmPlaneLayout(
                    offset: gbm_bo_get_offset(bo, p),
                    stride: gbm_bo_get_stride_for_plane(bo, p),
                    handle: gbm_bo_get_handle_for_plane(bo, p).u32))
            // (the GEM handle is the union's 32-bit field)
        }

        // Import the exact modifier GBM chose. Forcing LINEAR in the
        // renderable-only path is invalid on drivers that expose only tiled
        // render targets.
        let reportedModifier = unsafe gbm_bo_get_modifier(bo)
        let importModifier = reportedModifier

        // Single-fd export covering the whole BO (single-plane XRGB assumption).
        let exportedFd = unsafe gbm_bo_get_fd(bo)
        guard exportedFd >= 0 else {
            logRendererDrm("gbm_bo_get_fd failed errno=\(rendererErrno())")
            unsafe gbm_bo_destroy(bo)
            return nil
        }

        // Optionally retain a dup for KMS before the import consumes the original.
        let keptFd: Int32
        if keepDmaBufFdForKms {
            keptFd = dup(exportedFd)
            guard keptFd >= 0 else {
                logRendererDrm("dup of GBM DMA-BUF failed errno=\(rendererErrno())")
                close(exportedFd)
                unsafe gbm_bo_destroy(bo)
                return nil
            }
        } else {
            keptFd = -1
        }

        // c. Build the descriptor and import. `importDmaBufImage` consumes ownership
        // of `exportedFd` on success AND on failure (its cleanup `defer` closes every
        // fd it did not hand to Vulkan), so we must NOT close `exportedFd` ourselves —
        // only the KMS dup (`keptFd`), which the importer never sees.
        let descriptor = DmaBufImageDescriptor(
            fd: exportedFd,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: importModifier,
            planes: planes.map {
                DmaBufPlane(offset: UInt64($0.offset), rowPitch: UInt64($0.stride))
            },
            usage: DmaBufImageDescriptor.scanoutUsage)

        guard
            let image = unsafe importDmaBufImage(
                device: device, dispatch: dispatch, descriptor: descriptor)
        else {
            logRendererDrm(
                "Vulkan DMA-BUF import failed modifier=\(importModifier) planes=\(planeCount)")
            // `exportedFd` is already closed by the importer's cleanup; only the KMS dup is ours.
            if keptFd >= 0 { close(keptFd) }
            unsafe gbm_bo_destroy(bo)
            return nil
        }

        // d. Hand back the result; the BO is owned by the caller until packaged.
        return unsafe DRMScanoutBufferAllocation(
            image: image,
            bo: bo,
            width: width,
            height: height,
            drmFormat: drmFormat,
            modifier: importModifier,
            planes: planes,
            keptDmaBufFd: keptFd)
    }

    /// Package the three coupled lifetimes into an `OutputBufferOwner`. Consumes
    /// `self`: the BO, the imported image, and the optional KMS fb move into the
    /// owner's destroy closures, run in reverse order (fb → image → BO) on deinit.
    ///
    /// The `~Copyable` `VkOwned<VkImage>` cannot be captured by an `@escaping`
    /// closure directly, so it is boxed in a reference type whose deinit (or an
    /// explicit nil-out) drops the image. The KMS framebuffer (also `~Copyable`)
    /// is taken by raw fb id + device fd so its removal is a plain `drmModeRmFB`
    /// closure rather than moving the noncopyable owner in.
    consuming func makeOwner(
        framebufferDevice: DrmDeviceLifetime? = nil,
        framebufferId: UInt32 = 0
    ) -> OutputBufferOwner {
        let bo = unsafe self.bo
        let keptFd = unsafe self.keptDmaBufFd
        let w = unsafe self.width
        let h = unsafe self.height
        // Move the noncopyable image into a class box the closure can capture and
        // release. `VkOwned.deinit` frees the image + its imported memory.
        let imageBox = unsafe VkOwnedImageBox(consuming: self.image)

        let fbId = framebufferId

        return OutputBufferOwner(
            width: w,
            height: h,
            destroyFramebuffer: {
                // No-op when no fb was created (render node has no DRM master).
                if fbId != 0,
                    let fd = framebufferDevice?.availableFileDescriptor
                {
                    _ = drmModeRmFB(fd, fbId)
                }
            },
            destroyImage: {
                // Dropping the box runs `VkOwned.deinit` → destroys image + memory.
                imageBox.release()
            },
            destroyBuffer: {
                if keptFd >= 0 { close(keptFd) }
                unsafe gbm_bo_destroy(bo)
            })
    }
}
