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
import VulkanC
import Vulkan
import NucleusRenderer

/// One plane's GBM-reported layout, as needed for both the Vulkan import
/// (offset/stride) and a KMS `drmModeAddFB2WithModifiers` (handle/offset/stride).
public struct GbmPlaneLayout: Equatable, Sendable {
    public var offset: UInt32
    public var stride: UInt32
    public var handle: UInt32
    public init(offset: UInt32, stride: UInt32, handle: UInt32) {
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
public struct GbmScanoutBuffer: ~Copyable {
    /// The imported scanout image. `consuming`-moved into the `OutputBufferOwner`.
    public var image: VkOwned<VkImage>
    /// The raw `gbm_bo*`. Owned here; destroyed by the owner's `destroyBuffer`.
    public let bo: OpaquePointer
    public let width: UInt32
    public let height: UInt32
    public let drmFormat: UInt32
    public let modifier: UInt64
    public let planes: [GbmPlaneLayout]
    /// A dup'd dmabuf fd kept for a possible KMS import path, or -1 when none was
    /// retained (the import consumed the original fd). The owner closes it if >= 0.
    public let keptDmaBufFd: Int32

    public init(
        image: consuming VkOwned<VkImage>,
        bo: OpaquePointer,
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32,
        modifier: UInt64,
        planes: [GbmPlaneLayout],
        keptDmaBufFd: Int32
    ) {
        self.image = image
        self.bo = bo
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.modifier = modifier
        self.planes = planes
        self.keptDmaBufFd = keptDmaBufFd
    }

    /// Which GBM allocation path to take. Scanout-capable buffers need
    /// `GBM_BO_USE_SCANOUT` and a primary node with DRM master; a render node has
    /// neither, so the fixture (and any GPU-only consumer) falls back to
    /// `renderableOnly`, which the GBM/Vulkan round-trip can still exercise.
    public enum Usage {
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
    public static func allocate(
        gbmDevice: OpaquePointer,
        drmFormat: UInt32,
        width: UInt32,
        height: UInt32,
        modifiers: [UInt64],
        usage: Usage,
        device: VkDevice,
        dispatch: VK.DeviceDispatch,
        keepDmaBufFdForKms: Bool = false
    ) -> GbmScanoutBuffer? {
        guard width > 0,
              height > 0,
              let modifierCount = UInt32(exactly: modifiers.count)
        else { return nil }
        // a. Allocate the BO. Prefer the modifier-explicit path when modifiers are
        // supplied; else the usage-flag path.
        let bo: OpaquePointer?
        if !modifiers.isEmpty {
            bo = modifiers.withUnsafeBufferPointer { mods in
                gbm_bo_create_with_modifiers(
                    gbmDevice, width, height, drmFormat,
                    mods.baseAddress, modifierCount)
            }
        } else {
            let flags: UInt32
            switch usage {
            case .scanout:
                flags = GBM_BO_USE_SCANOUT.rawValue | GBM_BO_USE_RENDERING.rawValue
            case .renderableOnly:
                // Linear keeps the renderable-only fallback importable without a
                // negotiated modifier (the import below uses LINEAR for these).
                flags = GBM_BO_USE_RENDERING.rawValue | GBM_BO_USE_LINEAR.rawValue
            }
            bo = gbm_bo_create(gbmDevice, width, height, drmFormat, flags)
        }
        guard let bo else { logRendererDrm("gbm_bo_create failed errno=\(rendererErrno())"); return nil }

        // b. Read the plane layout + modifier, then export the dmabuf fd.
        let planeCount = Int(gbm_bo_get_plane_count(bo))
        guard (1...3).contains(planeCount) else {
            logRendererDrm("GBM BO reported unsupported plane count=\(planeCount)")
            gbm_bo_destroy(bo)
            return nil
        }
        var planes: [GbmPlaneLayout] = []
        planes.reserveCapacity(planeCount)
        for plane in 0..<planeCount {
            let p = Int32(plane)
            planes.append(GbmPlaneLayout(
                offset: gbm_bo_get_offset(bo, p),
                stride: gbm_bo_get_stride_for_plane(bo, p),
                handle: gbm_bo_get_handle_for_plane(bo, p).u32))
            // (the GEM handle is the union's 32-bit field)
        }

        // The modifier GBM chose. For the renderable-only/no-modifier path the
        // descriptor pins LINEAR so the modifier-explicit Vulkan import is valid.
        let reportedModifier = gbm_bo_get_modifier(bo)
        let importModifier: UInt64
        if !modifiers.isEmpty {
            importModifier = reportedModifier
        } else {
            switch usage {
            case .scanout: importModifier = reportedModifier
            // DRM_FORMAT_MOD_LINEAR is `fourcc_mod_code(NONE, 0)` == 0; the Swift
            // importer can't fold the macro, so the literal stands in for it.
            case .renderableOnly: importModifier = 0
            }
        }

        // Single-fd export covering the whole BO (single-plane XRGB assumption).
        let exportedFd = gbm_bo_get_fd(bo)
        guard exportedFd >= 0 else { logRendererDrm("gbm_bo_get_fd failed errno=\(rendererErrno())"); gbm_bo_destroy(bo); return nil }

        // Optionally retain a dup for KMS before the import consumes the original.
        let keptFd: Int32
        if keepDmaBufFdForKms {
            keptFd = dup(exportedFd)
            guard keptFd >= 0 else {
                logRendererDrm("dup of GBM DMA-BUF failed errno=\(rendererErrno())")
                close(exportedFd)
                gbm_bo_destroy(bo)
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
            planes: planes.map { DmaBufPlane(offset: UInt64($0.offset), rowPitch: UInt64($0.stride)) },
            usage: DmaBufImageDescriptor.scanoutUsage)

        guard let image = importDmaBufImage(device: device, dispatch: dispatch, descriptor: descriptor) else {
            logRendererDrm("Vulkan DMA-BUF import failed modifier=\(importModifier) planes=\(planeCount)")
            // `exportedFd` is already closed by the importer's cleanup; only the KMS dup is ours.
            if keptFd >= 0 { close(keptFd) }
            gbm_bo_destroy(bo)
            return nil
        }

        // d. Hand back the result; the BO is owned by the caller until packaged.
        return GbmScanoutBuffer(
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
    public consuming func makeOwner(
        framebufferFd: Int32 = -1,
        framebufferId: UInt32 = 0
    ) -> OutputBufferOwner {
        let bo = self.bo
        let keptFd = self.keptDmaBufFd
        let w = self.width
        let h = self.height
        // Move the noncopyable image into a class box the closure can capture and
        // release. `VkOwned.deinit` frees the image + its imported memory.
        let imageBox = VkOwnedImageBox(consuming: self.image)

        let fbFd = framebufferFd
        let fbId = framebufferId

        return OutputBufferOwner(
            width: w,
            height: h,
            destroyFramebuffer: {
                // No-op when no fb was created (render node has no DRM master).
                if fbId != 0 && fbFd >= 0 { _ = drmModeRmFB(fbFd, fbId) }
            },
            destroyImage: {
                // Dropping the box runs `VkOwned.deinit` → destroys image + memory.
                imageBox.release()
            },
            destroyBuffer: {
                if keptFd >= 0 { close(keptFd) }
                gbm_bo_destroy(bo)
            })
    }
}
