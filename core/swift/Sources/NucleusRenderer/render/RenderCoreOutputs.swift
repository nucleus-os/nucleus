import NucleusSkiaGraphiteBridge
import VulkanC
import Vulkan
import Tracy
import NucleusRenderModel
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@MainActor
extension RenderCore {
    /// Publish the session-lock composition. A change forces a redraw; while locked,
    /// `renderReady` also redraws every ready output each pass so the blank appears
    /// immediately and stays up regardless of tree damage.
    public func setLockComposition(_ value: [UInt64: Set<ContextID>]?) {
        if value != lockComposition {
            lockComposition = value
            lockCompositionGeneration &+= 1
            if lockCompositionGeneration == 0 { lockCompositionGeneration = 1 }
        }
    }

    public func attachOutputGeometry(
        outputID: UInt64,
        logicalX: Double, logicalY: Double, logicalWidth: Double, logicalHeight: Double,
        pixelWidth: UInt32, pixelHeight: UInt32, fractionalScale: Double
    ) {
        let metadata = OutputTargetMetadata(
            outputId: outputID,
            logicalRect: LogicalRect(x: logicalX, y: logicalY, width: logicalWidth, height: logicalHeight),
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            fractionalScale: fractionalScale)
        outputTargets[outputID] = RenderTargetAssembly.make(metadata)
        outputsNeedingInitialFrame.insert(outputID)
        outputPresentationLedger.attach(outputID)
    }

    /// Associate a presentation surface with the retained scene contexts it
    /// presents. Context order is visual back-to-front order.
    ///
    /// Passing an empty list intentionally presents no retained roots. Callers
    /// that do not install an association retain compositor-output behavior.
    public func setOutputRootContexts(
        outputID: UInt64,
        contextIDs: [UInt32]
    ) {
        var seen = Set<ContextID>()
        outputRootContexts[outputID] = contextIDs.compactMap { rawValue in
            let id = ContextID(raw: rawValue)
            return rawValue != 0 && seen.insert(id).inserted ? id : nil
        }
        outputsNeedingInitialFrame.insert(outputID)
    }

    /// Drop an output's geometry (the backend detached it) and its persistent GPU
    /// accumulator, so a removed output leaks neither.
    public func detachOutputGeometry(outputID: UInt64) {
        outputTargets[outputID] = nil
        outputRootContexts[outputID] = nil
        outputsNeedingInitialFrame.remove(outputID)
        outputPresentationLedger.detach(outputID)
        frameDriver?.dropAccumulator(output: outputID)
    }

    // MARK: - The render loop

    /// Vulkan image usage flags for the borrowed frame target, by kind. Both kinds
    /// expose `VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT` so the Graphite render-target
    /// wrap succeeds.
    func usageFlags(for kind: FrameTargetKind) -> VK.ImageUsageFlags {
        switch kind {
        case .drmScanout: return DmaBufImageDescriptor.scanoutUsage
        case .swapchainColor: return [.colorAttachmentBit, .transferDstBit]
        }
    }

    /// Record one frame for `outputID` into the backend-acquired `target` image:
    /// wrap a transient Graphite surface over it, composite the retained tree, and
    /// submit. Returns true when a frame was presented (the backend then scans it
    /// out). Does not flip/present — that is the backend's `present`.
}
