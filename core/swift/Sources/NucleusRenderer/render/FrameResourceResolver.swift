import NucleusSkiaGraphiteBridge
import VulkanC
internal import NucleusRenderModel

/// The single resource-resolution owner installed by `RenderCore`.
///
/// It borrows the core so the core remains the lifetime root. Every lookup runs
/// on the render actor before `FrameDriver` begins recording.
@MainActor
final class RenderCoreFrameResourceResolver: FrameResourceResolver {
    unowned let owner: RenderCore

    init(owner: RenderCore) {
        self.owner = owner
    }

    func acquireWaitSemaphore(
        forClientSurfaceID surfaceID: UInt64
    ) -> VkSemaphore? {
        unsafe owner.pendingClientAcquireSemaphores[surfaceID]?.semaphore
    }

    func paintContent(
        for handle: PaintContentHandle
    ) -> PaintContentStore.Content? {
        owner.resourceHost.paintContents.content(handle)
    }

    func paintImage(
        for handle: UInt64,
        outputID: UInt64
    ) -> nucleus.skia.Image? {
        guard let driver = owner.frameDriver,
              let source = owner.resourceHost.images.source(handle)
        else {
            return nil
        }
        return unsafe driver.decodedImage(
            handle: handle,
            source: source,
            outputID: outputID)
    }

    func texture(
        for reference: PlanTextureReference
    ) -> nucleus.skia.Image? {
        guard let driver = owner.frameDriver else { return nil }
        switch reference.role {
        case .snapshot:
            guard let entry = owner.snapshots.resolve(
                SnapshotHandle(raw: reference.handle.raw))
            else {
                return nil
            }
            return unsafe driver.registry.resolve(.renderer(entry.texture.raw))
        case .content:
            if let staged = owner.stagedShmUploads[reference.handle.raw] {
                return unsafe staged.image
            }
            return unsafe driver.registry.resolve(
                .clientSurface(reference.handle.raw))
        case .paint, .remoteHost, .shadow, .fill, .shell, .unknown:
            return unsafe driver.registry.resolve(.renderer(reference.handle.raw))
        }
    }
}
