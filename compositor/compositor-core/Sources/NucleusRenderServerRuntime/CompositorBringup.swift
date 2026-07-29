import NucleusCompositorServer // private framework implementation
import NucleusCompositorServerTypes
import NucleusCompositorPolicy
import NucleusAppHostBundle
import NucleusCompositorRenderRuntime
import NucleusCompositorRenderSession
import NucleusConfig
import NucleusRenderer
import NucleusRenderHost
import NucleusCompositorRendererLinux
import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowScene
import NucleusSessionProtocol
import Glibc

// Compositor bring-up + teardown, Swift-owned.
// `runNucleusCompositor` calls `bringUp` on the main actor, awaits the reactor loop,
// then calls `teardown`. Every platform step is a direct Swift call into the owner
// module (the input/router/xwm hosts in NucleusCompositorWaylandRuntime, the render runtime +
// DRM session in NucleusCompositorRenderRuntime and DRM discovery in
// NucleusRenderer); the display model + router seed + first frame go through
// the runtime-owned server and frame-demand coordinator directly.

extension CompositorRuntime {
    /// Bring the compositor up. Discovers the DRM device (Swift, over libdrm), opens
    /// the seat + DRM primary node, brings up the render runtime, and starts the
    /// router/shell/input. Returns false on a fatal bring-up failure (the caller
    /// tears down + exits non-zero).
    func bringUp() -> Bool {
        // ── Session configuration ─────────────────────────────────────────
        // The supervisor does not launch the render server until the
        // configuration service has resolved and delivered this projection.
        // Adopt it before opening the seat so XKB and libinput see the initial
        // policy rather than a temporary default.
        let sessionConfiguration = liveConfiguration

        // ── DRM device discovery (Swift-owned, over libdrm) ───────────────
        guard let drmDevice = discoverDrmDevice(
            preferredRenderPath: configuration.drmDevicePath)
        else {
            logRuntime("DRM device discovery failed")
            return false
        }

        // ── libseat session + DRM primary node (Swift-owned) ──────────────
        guard waylandRuntime.openSeat(
            configuration: sessionConfiguration.input)
        else {
            logRuntime("session: failed to open Swift-owned seat")
            return false
        }

        // Install the inverted session seams. The render service installs itself
        // only after successful GPU bring-up below.
        server.sessionControl = self
        unsafe drmSession.installDeviceSeat(
            open: { [weak waylandRuntime] in
                unsafe waylandRuntime?.openDevice($0) ?? -1
            },
            close: { [weak waylandRuntime] in waylandRuntime?.closeDevice($0) })

        let primaryFd = drmDevice.primaryPath.withCString {
            unsafe drmSession.open(path: $0)
        }
        guard primaryFd >= 0 else {
            logRuntime("session: failed to open DRM primary node through the seat")
            return false
        }

        server.policy = policyServices.policy
        installShellPolicyPublication()

        // ── Swift render runtime ──────────────────────────────────────────
        var renderNodeStat = stat()
        let renderMainDevice = drmDevice.renderPath.withCString {
            unsafe stat($0, &renderNodeStat) == 0
                ? UInt64(renderNodeStat.st_rdev)
                : 0
        }
        guard renderMainDevice != 0 else {
            logRuntime("render runtime: failed to stat selected render node")
            return false
        }
        guard renderRuntime.bringUp(
            drmDeviceFd: primaryFd,
            dmabufMainDevice: renderMainDevice,
            enableValidation: configuration.enableVulkanValidation,
            presentPolicy: configuration.presentMode == .mailboxLatestWins
                ? .mailboxLatestWins
                : .vsync,
            store: retainedStore,
            resourceHost: resourceHost,
            asyncRenderWakeSink: renderWake)
        else {
            logRuntime("render runtime: Swift bring-up failed")
            return false
        }
        renderRuntime.installSurfaceRetirement {
            self.waylandRuntime.noteSurfaceBufferRetired($0)
        }
        guard outputTopology.reconcile() else {
            logRuntime("render runtime: initial output topology discovery failed")
            return false
        }
        guard !server.layout.displays.isEmpty else {
            logRuntime("render runtime: no physical DRM outputs attached")
            return false
        }
        logRuntime(
            "render runtime: Swift render path active for " +
            "\(server.layout.displays.count) output(s)")

        // Present-report seam: fold each output's scanout submit / page-flip into its
        // DisplayLink present-id ack, and ack the session-lock gate on flip completion.
        // The `locked` security invariant is confirmed by a real present here (the
        // author-time blank filter, applied in the scene author, is the other half).
        renderRuntime.installPresentReport(
            submitted: { [weak self]
                outputID, outputGeneration, submissionID, sampledIOSurfaceIDs in
                guard let self,
                      let display = self.server.layout.display(id: outputID)
                else { return }
                display.redrawSubmitted(submissionID: submissionID)
                self.frameDemand.willSubmit(display)
                display.noteFrameSubmitted()
                self.frameDemand.didSubmit(display)
                self.waylandRuntime.noteSubmitted(
                    outputID: outputID,
                    outputGeneration: outputGeneration,
                    submissionID: submissionID,
                    targetPresentationNs:
                        display.displayLink.predictedPresentNs(0),
                    sampledIOSurfaceIDs: sampledIOSurfaceIDs)
            },
            presented: { [weak self]
                outputID, outputGeneration, submissionID,
                presentationNs, sequence in
                guard let self else { return }
                // The kernel's real flip timestamp/sequence (from the page-flip event) — not a
                // re-sampled wall clock — drives the DisplayLink ack, the session-lock ack, AND the
                // client-facing tick: wl_surface.frame + wp_presentation_feedback for this output.
                let display = self.server.layout.display(id: outputID)
                let predicted = display?.displayLink.predictedPresentNs(0) ?? presentationNs
                display?.noteFramePresented(presentationNs: presentationNs)
                display?.redrawPresented(submissionID: submissionID)
                if let display {
                    self.frameDemand.didPresent(
                        display, presentationNs: presentationNs,
                        predictedPresentNs: predicted)
                }
                self.waylandRuntime.noteSessionLockPresented(outputID)
                let refreshNs = UInt32(truncatingIfNeeded: display?.displayLink.refreshIntervalNs ?? 16_666_666)
                self.waylandRuntime.notePresented(
                    outputID, outputGeneration, submissionID,
                    presentationNs, refreshNs, sequence)
                self.reportCompositorReadyAfterPresentation()
            },
            discarded: { [weak self]
                outputID, outputGeneration, submissionID in
                guard let self else { return }
                if let display =
                    self.server.layout.display(id: outputID)
                {
                    display.redrawPresented(submissionID: submissionID)
                    // The flip itself completed, but its timestamp was unusable.
                    // Close scheduler bookkeeping without advancing the presentation
                    // timeline from an invalid clock sample.
                    display.inFlightPresentID = 0
                    self.frameDemand.requestFrame(
                        outputID: outputID, reason: .surfaceDamage)
                }
                self.waylandRuntime.discardSubmitted(
                    outputID: outputID,
                    outputGeneration: outputGeneration,
                    submissionID: submissionID)
            })

        // XDG_RUNTIME_DIR (set by the isolated session) is required for the router's
        // wl_display_add_socket_auto.
        let hasRuntimeDirectory = unsafe getenv("XDG_RUNTIME_DIR") != nil
        guard hasRuntimeDirectory else {
            logRuntime("XDG_RUNTIME_DIR is required for the Wayland listen socket")
            return false
        }

        // ── Wayland router: the sole live transport ───────────────────────
        waylandRuntime.activateRouter(author: windowSceneAuthor)
        seedRouter()
        waylandRuntime.publishKeymap()

        // Build and drain the initial libinput inventory before publishing the
        // Wayland socket. Otherwise an autostart client can bind wl_seat while it
        // still advertises zero capabilities and trigger missing_capability before
        // the first reactor turn processes DEVICE_ADDED.
        guard waylandRuntime.startLibinput() else {
            logRuntime("session: failed to start Swift-owned libinput")
            return false
        }
        waylandRuntime.drainLibinput()

        guard waylandRuntime.addSocket() else {
            logRuntime("router add_socket failed; no Wayland socket available")
            return false
        }
        logRuntime("Wayland compositor listening on the libwayland router")
        policyServices.adoptConfiguration(
            binds: sessionConfiguration.binds,
            epoch: configurationEpoch,
            generation: configurationGeneration)
        outputTopology.outputOverrides = sessionConfiguration.outputs
        waylandRuntime.installOutputManagementDelegate(self)

        publishControlReadiness()

        // ── XWayland (lazy spawn) ─────────────────────────────────────────
        if let xwaylandExecutablePath =
                configuration.xwaylandExecutablePath
        {
            let traceEnabled: Bool
            if let traceValue = unsafe getenv("NUCLEUS_XWAYLAND_TRACE") {
                traceEnabled = unsafe String(cString: traceValue) == "1"
            } else {
                traceEnabled = false
            }
            if !waylandRuntime.bringUpXwayland(
                executablePath: xwaylandExecutablePath,
                traceEnabled: traceEnabled)
            {
                logRuntime(
                    "[xwayland] init failed — continuing without X11 support")
            }
        } else {
            logRuntime("[xwayland] init failed — continuing without X11 support")
        }

        // ── Hardware cursor + first frame ─────────────────────────────────
        policyServices.cursorTheme.applyDefault()
        frameDemand.requestFrame(reason: .outputChange)
        return true
    }

    /// Tear down in reverse acquisition order. Retained Wayland scene resources
    /// retire first while their renderer owner is live; GPU/scanout state then
    /// drops before the borrowed DRM master fd, followed by Xwayland, app hosts,
    /// and seat/libinput.
    func teardown() async {
        await stopReactor()
        revokeShellSession()
        logRuntime("shutdown: Wayland scene")
        waylandRuntime.prepareShutdown()
        switch shutdownDisposition {
        case .outputsDisabled:
            logRuntime("shutdown: render runtime")
            renderRuntime.shutdown()
            logRuntime("shutdown: DRM session")
            drmSession.close()
        case .drmDeviceCloseRequired:
            // Closing the primary device is the terminal kernel lifetime barrier
            // when an atomic disable failed or exceeded its bounded grace period.
            // Only then release framebuffer/GBM/Vulkan owners.
            logRuntime("shutdown: revoking DRM session")
            renderRuntime.revokeDrmDevice()
            drmSession.close()
            logRuntime("shutdown: render runtime after DRM device loss")
            renderRuntime.shutdownAfterDrmDeviceLoss()
        }
        logRuntime("shutdown: Xwayland")
        waylandRuntime.shutdownXwayland()
        logRuntime("shutdown: app hosts")
        hostBundle.invalidate()
        logRuntime("shutdown: input seat")
        waylandRuntime.shutdownInput()
        logRuntime("shutdown: complete")
    }

    /// Seed the router's `wl_output` set from the Swift display layout (Swift→Swift).
    private func seedRouter() {
        for display in server.layout.displays {
            display.name.withCString { namePtr in
                display.description.withCString { descPtr in
                    unsafe waylandRuntime.addOutput(
                        display.id,
                        Int32(display.logicalRect.x.rounded()),
                        Int32(display.logicalRect.y.rounded()),
                        display.physicalWidthMM, display.physicalHeightMM,
                        Int32(bitPattern: display.pixelSize.width),
                        Int32(bitPattern: display.pixelSize.height),
                        display.refreshMHz, Int32(bitPattern: display.scale),
                        Int32(display.logicalRect.width.rounded()),
                        Int32(display.logicalRect.height.rounded()),
                        display.fractionalScale,
                        namePtr, descPtr)
                }
            }
        }
    }

}
