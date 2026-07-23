import VulkanC
import Vulkan
import NucleusCompositorDrmC
import NucleusRenderModel
@_spi(NucleusPlatform) public import NucleusRenderer
import Glibc

@MainActor
extension RendererRuntime {
    /// Attach one globally allocated KMS pipeline. A replacement is retired before
    /// its new scanout owners become visible, so no framebuffer is destroyed while
    /// the kernel can still reference it.
    @discardableResult
    public func attachOutput(
        outputId: UInt64,
        logicalX: Double, logicalY: Double,
        logicalWidth: Double, logicalHeight: Double,
        pixelWidth: UInt32, pixelHeight: UInt32,
        fractionalScale: Double,
        connectorId: UInt32, crtcId: UInt32,
        planeId: UInt32, cursorPlaneId: UInt32,
        modeBlobId: UInt32, vrrCapable: Bool,
        drmFourcc: UInt32 = DrmFourcc.xrgb8888,
        ringDepth: Int = 2
    ) -> Bool {
        let generation = nextBindingGeneration
        nextBindingGeneration &+= 1
        guard let drm = DrmOutput.discover(
            device: drmDevice,
            connectorId: connectorId,
            crtcId: crtcId,
            planeId: planeId,
            cursorPlaneId: cursorPlaneId,
            modeBlobId: modeBlobId,
            width: pixelWidth,
            height: pixelHeight,
            vrrCapable: vrrCapable,
            presentPolicy: presentPolicy,
            onPageFlip: { [weak self] event in
                self?.notePageFlipComplete(
                    outputId, generation, event)
            }
        ) else {
            logRendererDrm(
                "connector \(connectorId): required atomic properties unavailable")
            if modeBlobId != 0 {
                _ = drmModeDestroyPropertyBlob(
                    drmDeviceFd, modeBlobId)
            }
            return false
        }
        guard drm.supportsInFence else {
            logRendererDrm(
                "connector \(connectorId): primary plane lacks required IN_FENCE_FD")
            return false
        }

        var slots: [ScanoutSlot] = []
        slots.reserveCapacity(ringDepth)
        for slotIndex in 0..<ringDepth {
            guard let slot = makeScanoutSlot(
                width: pixelWidth,
                height: pixelHeight,
                drmFormat: drmFourcc)
            else {
                logRendererDrm(
                    "connector \(connectorId): scanout slot \(slotIndex) allocation failed")
                return false
            }
            slots.append(slot)
        }

        if bindings[outputId] != nil {
            guard retireOutputs(Set([outputId])) == .complete else {
                logRendererDrm(
                    "output \(outputId): replacement deferred; prior flip did not retire")
                return false
            }
        }
        scanoutSurfaces.removeOutput(outputId)
        let cursorPlane = DrmCursorPlane.create(
            gbmDevice: gbmHandle,
            device: drmDevice,
            planeId: cursorPlaneId,
            crtcId: crtcId,
            props: drm.cursorProps,
            width: cursorPlaneSize.width,
            height: cursorPlaneSize.height)
        if let cursorPlane, !cursorPixels.isEmpty {
            cursorPlane.upload(
                pixels: cursorPixels,
                srcWidth: Int(cursorImageWidth),
                srcHeight: Int(cursorImageHeight))
        }
        bindings[outputId] = RenderOutputBinding(
            outputId: outputId,
            generation: generation,
            drm: drm,
            slots: slots,
            format: vulkanFormatForDrm(drmFourcc),
            queueFamily: core.graphicsFamily,
            width: Int32(pixelWidth),
            height: Int32(pixelHeight),
            logicalRect: OutputRect(
                x: logicalX, y: logicalY,
                width: logicalWidth, height: logicalHeight),
            fractionalScale: fractionalScale,
            cursorPlane: cursorPlane)
        primaryPlaneFormats[outputId] = collectPlaneFormats(
            fd: drmDeviceFd, planeId: planeId)
        core.attachOutputGeometry(
            outputID: outputId,
            logicalX: logicalX,
            logicalY: logicalY,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            fractionalScale: fractionalScale)
        logRendererDrm(
            "connector \(connectorId): attached \(pixelWidth)x\(pixelHeight) crtc=\(crtcId) " +
            "primary_plane=\(planeId) explicit_render_fence=\(drm.supportsInFence)")
        return true
    }

    private func makeScanoutSlot(
        width: UInt32,
        height: UInt32,
        drmFormat: UInt32
    ) -> ScanoutSlot? {
        guard let buffer = GbmScanoutBuffer.allocate(
            gbmDevice: gbmHandle,
            drmFormat: drmFormat,
            width: width,
            height: height,
            modifiers: [],
            usage: .scanout,
            device: core.deviceHandle,
            dispatch: core.deviceDispatch
        ) else {
            logRendererDrm(
                "GBM scanout buffer/Vulkan DMA-BUF import failed")
            return nil
        }

        let imageHandle = buffer.image.handle
        let handles = buffer.planes.map(\.handle)
        let pitches = buffer.planes.map(\.stride)
        let offsets = buffer.planes.map(\.offset)
        let modifiers = buffer.planes.map { _ in buffer.modifier }
        guard let framebuffer = DrmFramebuffer(
            deviceFd: drmDeviceFd,
            width: width,
            height: height,
            pixelFormat: drmFormat,
            handles: handles,
            pitches: pitches,
            offsets: offsets,
            modifiers: modifiers
        ) else {
            logRendererDrm(
                "drmModeAddFB2WithModifiers failed errno=\(rendererErrno()) modifier=\(buffer.modifier)")
            _ = buffer.makeOwner()
            return nil
        }
        let framebufferID = framebuffer.fbId
        let owner = buffer.makeOwner(
            framebufferDevice: drmDevice,
            framebufferId: framebuffer.release())
        return ScanoutSlot(
            imageHandle: imageHandle,
            fbId: framebufferID,
            owner: consume owner)
    }

    /// Discover and globally allocate the connected outputs without mutating live
    /// KMS bindings. The composition root applies this immutable proposal.
    public func proposeConnectedOutputTopology()
        -> RendererTopologyProposal?
    {
        switch backendState {
        case .active, .resuming:
            break
        case .pausing, .inactive, .failed:
            return nil
        }
        guard DrmCapabilities.enableAtomicModesetting(
            fd: drmDeviceFd)
        else {
            logRendererDrm(
                "failed to enable universal planes/atomic modesetting errno=\(rendererErrno())")
            return nil
        }
        let generation = nextTopologyGeneration
        nextTopologyGeneration &+= 1
        if nextTopologyGeneration == 0 {
            nextTopologyGeneration = 1
        }
        guard let inventory = DrmTopologyDiscovery.scan(
            fd: drmDeviceFd, generation: generation)
        else {
            logRendererDrm(
                "whole-device topology discovery failed errno=\(rendererErrno())")
            return nil
        }
        let plan = DrmTopologyPlanner.plan(
            inventory, preserving: appliedTopologySnapshot)
        for diagnostic in plan.diagnostics {
            logRendererDrm(diagnostic)
        }
        pendingTopology = (inventory, plan)

        var proposed: [RendererOutputInfo] = []
        for assignment in plan.snapshot.assignments {
            let connectorID = assignment.connectorID.rawValue
            guard let connector = inventory.connectors.first(
                where: {
                    $0.connectorID == assignment.connectorID
                })
            else { continue }
            logRendererDrm(
                "connector \(connectorID): proposed mode " +
                "\(assignment.mode.hdisplay)x\(assignment.mode.vdisplay)@" +
                "\(Double(assignment.mode.refreshMilliHz) / 1_000.0)Hz")
            proposed.append(RendererOutputInfo(
                topologyGeneration: generation,
                id: UInt64(connectorID),
                pixelWidth: UInt32(assignment.mode.hdisplay),
                pixelHeight: UInt32(assignment.mode.vdisplay),
                refreshMhz: assignment.mode.refreshMilliHz,
                physicalWidthMM:
                    connector.physicalSizeMM.widthMM,
                physicalHeightMM:
                    connector.physicalSizeMM.heightMM,
                crtcID: assignment.crtcID.rawValue,
                primaryPlaneID:
                    assignment.primaryPlaneID.rawValue,
                cursorPlaneID:
                    assignment.cursorPlaneID?.rawValue ?? 0))
        }
        return RendererTopologyProposal(
            generation: generation, outputs: proposed)
    }

    public func applyProposedOutput(
        _ proposed: RendererOutputInfo,
        logicalX: Double,
        logicalY: Double,
        logicalWidth: Double,
        logicalHeight: Double,
        fractionalScale: Double
    ) -> Bool {
        switch backendState {
        case .active, .resuming:
            break
        case .pausing, .inactive, .failed:
            return false
        }
        guard let pendingTopology,
            pendingTopology.result.snapshot.generation
                == proposed.topologyGeneration,
            let assignment =
                pendingTopology.result.snapshot.assignments.first(
                    where: {
                        UInt64($0.connectorID.rawValue)
                            == proposed.id
                            && $0.crtcID.rawValue
                                == proposed.crtcID
                            && $0.primaryPlaneID.rawValue
                                == proposed.primaryPlaneID
                            && ($0.cursorPlaneID?.rawValue ?? 0)
                                == proposed.cursorPlaneID
                    }),
            let connector =
                pendingTopology.inventory.connectors.first(
                    where: {
                        $0.connectorID
                            == assignment.connectorID
                    }),
            let modeBlobID = assignment.mode.createModeBlob(
                fd: drmDeviceFd)
        else {
            logRendererDrm(
                "output \(proposed.id): rejected stale or invalid topology proposal")
            return false
        }
        return attachOutput(
            outputId: proposed.id,
            logicalX: logicalX,
            logicalY: logicalY,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: proposed.pixelWidth,
            pixelHeight: proposed.pixelHeight,
            fractionalScale: fractionalScale,
            connectorId: assignment.connectorID.rawValue,
            crtcId: assignment.crtcID.rawValue,
            planeId: assignment.primaryPlaneID.rawValue,
            cursorPlaneId:
                assignment.cursorPlaneID?.rawValue ?? 0,
            modeBlobId: modeBlobID,
            vrrCapable: connector.vrrCapable)
    }

    @discardableResult
    public func retireOutput(
        _ outputID: UInt64
    ) -> RendererRetirementResult {
        retireOutputs(Set([outputID]))
    }

    /// Retire a topology change set with one device-wide atomic disable. This
    /// method never waits: accepted page flips and kernel-busy disables remain
    /// owned by the normal DRM reactor path, and callers retry without allowing
    /// another present into the retiring topology generation.
    @discardableResult
    public func retireOutputs(
        _ outputIDs: Set<UInt64>
    ) -> RendererRetirementResult {
        let retiring = outputIDs.sorted().compactMap {
            bindings[$0]
        }
        guard !retiring.isEmpty else { return .complete }
        var commitErrno: Int32 = 0
        var diagnosticLines: [String] = []
        let result = retireDrmOutputs(retiring.map(\.drm)) { disabling in
            guard var builder = AtomicRequestBuilder() else {
                commitErrno = ENOMEM
                return .rejected(errno: commitErrno)
            }
            for output in disabling {
                guard output.addAtomicState(.disabled, into: &builder) else {
                    commitErrno = EINVAL
                    return .rejected(errno: commitErrno)
                }
            }
            guard builder.validates(
                fd: drmDeviceFd,
                flags: drmModeAtomicAllowModeset)
            else {
                let code = rendererErrno()
                commitErrno = code == 0 ? EINVAL : code
                diagnosticLines = builder.diagnosticLines()
                return .rejected(errno: commitErrno)
            }
            let rc = builder.commit(
                fd: drmDeviceFd,
                flags: drmModeAtomicAllowModeset)
            diagnosticLines = builder.diagnosticLines()
            guard rc == 0 else {
                let code = rendererErrno()
                commitErrno = code == 0 ? EINVAL : code
                return .rejected(errno: commitErrno)
            }
            return .accepted
        }
        switch result {
        case .draining:
            logRendererDrm(
                "outputs \(retiring.map(\.outputId)): retirement draining" +
                    (commitErrno == EBUSY
                        ? " after kernel EBUSY"
                        : " pending page flip"))
            return .draining
        case .failed:
            logRendererDrm(
                "outputs \(retiring.map(\.outputId)): atomic retirement failed errno=\(commitErrno)")
            for line in diagnosticLines { logRendererDrm(line) }
            return .failed
        case .complete:
            break
        }
        for binding in retiring {
            binding.releaseAfterScanoutDisabled()
            retiredFlipTokens.append(binding.drm.flipToken)
            removeRetiredBinding(binding)
        }
        return .complete
    }

    private func removeRetiredBinding(
        _ binding: RenderOutputBinding
    ) {
        let outputID = binding.outputId
        bindings[outputID] = nil
        primaryPlaneFormats[outputID] = nil
        scanoutCandidates[outputID] = nil
        lastScanoutDecision[outputID] = nil
        cursorPresentDirty.remove(outputID)
        forcedPresentOutputIDs.remove(outputID)
        scanoutSurfaces.removeOutput(outputID)
        core.detachOutputGeometry(outputID: outputID)
    }

    /// End every binding after the primary DRM device has been revoked by the
    /// session owner. Closing the device is the kernel-side lifetime barrier:
    /// no CRTC can retain a framebuffer after it. Userspace owners can therefore
    /// be released without requiring another atomic request on the lost fd.
    func releaseBindingsAfterDrmDeviceLoss() {
        let lost = bindings.values.sorted { $0.outputId < $1.outputId }
        for binding in lost {
            binding.drm.noteDeviceLost()
            binding.releaseAfterScanoutDisabled()
            retiredFlipTokens.append(binding.drm.flipToken)
            removeRetiredBinding(binding)
        }
        pendingTopology = nil
        appliedTopologySnapshot = nil
        backendState = .failed("DRM device revoked during shutdown")
    }

    public func commitProposedTopology(
        generation: UInt64,
        appliedOutputIDs: Set<UInt64>
    ) {
        guard let pendingTopology,
            pendingTopology.result.snapshot.generation == generation
        else { return }
        appliedTopologySnapshot = OutputTopologySnapshot(
            generation: generation,
            assignments:
                pendingTopology.result.snapshot.assignments.filter {
                    appliedOutputIDs.contains(
                        UInt64($0.connectorID.rawValue))
                })
        if let appliedTopologySnapshot {
            backendState = .active(appliedTopologySnapshot)
        }
        self.pendingTopology = nil
        logRendererDrm(
            "applied outputs=\(appliedOutputIDs.count)")
    }
}
