import NucleusCompositorServer
import NucleusCompositorShell
import NucleusCompositorOverlayScene
import NucleusCompositorOverlayTypes
import NucleusAppHostBundle
import NucleusCompositorRenderRuntime
import NucleusCompositorRenderSession
import NucleusRenderer
import NucleusRenderHost
import NucleusUI
import NucleusTextBackend
import NucleusCompositorRendererLinux
import NucleusCompositorWaylandRuntime
import NucleusCompositorWindowScene
import Glibc

// Compositor bring-up + teardown, Swift-owned.
// `runNucleusCompositor` calls `bringUp` on the main actor, awaits the reactor loop,
// then calls `teardown`. Every platform step is a direct Swift call into the owner
// module (the input/router/xwm hosts in NucleusCompositorWaylandRuntime, the render runtime +
// DRM session in NucleusCompositorRenderRuntime, DRM discovery in NucleusRenderer, the shell
// services in NucleusCompositorShell); the display model + router seed + first frame go
// through the runtime-owned server, frame-demand coordinator, and overlay scene directly.

extension CompositorRuntime {
    /// Bring the compositor up. Discovers the DRM device (Swift, over libdrm), opens
    /// the seat + DRM primary node, brings up the render runtime, and starts the
    /// router/shell/input. Returns false on a fatal bring-up failure (the caller
    /// tears down + exits non-zero).
    func bringUp() -> Bool {
        // ── DRM device discovery (Swift-owned, over libdrm) ───────────────
        var primaryPathBuf = [CChar](repeating: 0, count: 256)
        var renderPathBuf = [CChar](repeating: 0, count: 256)
        let discovered = primaryPathBuf.withUnsafeMutableBufferPointer { primary in
            renderPathBuf.withUnsafeMutableBufferPointer { render in
                nucleus_drm_discover(
                    primary.baseAddress!, primary.count,
                    render.baseAddress!, render.count)
            }
        }
        guard discovered else {
            logRuntime("DRM device discovery failed")
            return false
        }

        // ── libseat session + DRM primary node (Swift-owned) ──────────────
        guard waylandRuntime.openSeat() else {
            logRuntime("session: failed to open Swift-owned seat")
            return false
        }

        // Install the inverted session seams. The render service installs itself
        // only after successful GPU bring-up below.
        server.sessionControl = self
        drmSession.installDeviceSeat(
            open: { [weak waylandRuntime] in waylandRuntime?.openDevice($0) ?? -1 },
            close: { [weak waylandRuntime] in waylandRuntime?.closeDevice($0) })

        let primaryFd = primaryPathBuf.withUnsafeBufferPointer {
            drmSession.open(path: $0.baseAddress!)
        }
        guard primaryFd >= 0 else {
            logRuntime("session: failed to open DRM primary node through the seat")
            return false
        }

        let scale = outputScale

        // ── Runtime-owned host bundle + overlay controller ────────────────
        let textSystem = TextSystem()
        SkiaTextLayoutBackend.install(in: textSystem)
        let overlayServices = UIHostServices(
            textSystem: textSystem,
            pasteboard: Pasteboard(adapter: UnavailablePasteboardAdapter()),
            imageSourceResolver: .directResourcesOnly,
            diagnosticSink: { diagnostic in
                logRuntime("UI service failure: \(diagnostic)")
            })
        guard textSystem.hasInstalledBackend,
              shellServices.installOverlay(
                commitSink: makeRenderCommitSink(),
                services: overlayServices)
        else {
            logRuntime("overlay runtime host install failed")
            return false
        }
        // Install the shell's conformer to the inverted input→shell seam so the
        // input dispatch reaches cursor/bezel/overlay policy + keybinds.
        server.shellPolicy =
            shellServices.shellPolicy

        // ── Swift render runtime ──────────────────────────────────────────
        var renderNodeStat = stat()
        let renderMainDevice = renderPathBuf.withUnsafeBufferPointer {
            stat($0.baseAddress!, &renderNodeStat) == 0
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

        // Seed the overlay scene's initial output geometry.
        if let primary = server.layout.displays.first {
            shellServices.overlayScene.frameUpdated(FrameInfo(
                outputWidth: UInt32(primary.logicalRect.width),
                outputHeight: UInt32(primary.logicalRect.height),
                devicePixelRatio: Float(scale),
                overlayRegionX: 0, overlayRegionY: 0,
                overlayRegionW: Float(primary.logicalRect.width),
                overlayRegionH: Float(primary.logicalRect.height)))
        }

        // XDG_RUNTIME_DIR (set by the isolated session) is required for the router's
        // wl_display_add_socket_auto.
        guard getenv("XDG_RUNTIME_DIR") != nil else {
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
        shellServices.activateEnvironment()

        // ── Shell D-Bus services + desktop shell ──────────────────────────
        spawnShellClient()

        // ── XWayland (lazy spawn) ─────────────────────────────────────────
        if !waylandRuntime.bringUpXwayland() {
            logRuntime("[xwayland] init failed — continuing without X11 support")
        }

        // ── Hardware cursor + first frame ─────────────────────────────────
        shellServices.cursorTheme.applyDefault()
        frameDemand.requestFrame(reason: .outputChange)
        return true
    }

    /// Tear down in reverse acquisition order. Retained Wayland scene resources
    /// retire first while their renderer owner is live; GPU/scanout state then
    /// drops before the borrowed DRM master fd, followed by Xwayland, app hosts,
    /// and seat/libinput.
    func teardown() async {
        await stopReactor()
        await stopShellClient()
        logRuntime("shutdown: Wayland scene")
        waylandRuntime.prepareShutdown()
        logRuntime("shutdown: render runtime")
        renderRuntime.shutdown()
        // Release DRM master and return the primary fd to libseat immediately
        // after scanout teardown. Xwayland/D-Bus/client cleanup must not be able to
        // delay restoring the VT if one of those services blocks during shutdown.
        logRuntime("shutdown: DRM session")
        drmSession.close()
        logRuntime("shutdown: Xwayland")
        waylandRuntime.shutdownXwayland()
        logRuntime("shutdown: app hosts")
        shellServices.shutdown()
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
                    waylandRuntime.addOutput(
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

    /// Spawn the Nucleus desktop shell as a supervised Wayland client on the
    /// compositor's WAYLAND_DISPLAY. The command (NUCLEUS_SHELL_CMD, default
    /// "nucleus-shell") is whitespace-split into argv; empty disables spawning.
    /// `posix_spawn` is required here: the compositor is already multithreaded,
    /// so running Swift between `fork` and `exec` can deadlock on inherited
    /// runtime locks.
    private func spawnShellClient() {
        let command: String
        if let raw = getenv("NUCLEUS_SHELL_CMD") {
            command = String(cString: raw)
        } else {
            command = "nucleus-shell"
        }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else {
            logRuntime("shell: NUCLEUS_SHELL_CMD is empty; not spawning a desktop shell")
            return
        }

        var attributes = posix_spawnattr_t()
        guard posix_spawnattr_init(&attributes) == 0 else {
            logRuntime("shell: failed to initialize spawn attributes")
            return
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigemptyset(&emptyMask)
        for signal in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] {
            sigaddset(&defaultSignals, signal)
        }
        guard posix_spawnattr_setsigdefault(
            &attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
              posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0
        else {
            logRuntime("shell: failed to configure spawn signal state")
            return
        }

        let argv: [UnsafeMutablePointer<CChar>?] =
            (["/usr/bin/env"] + tokens).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child = pid_t()
        let result = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(
                &child,
                "/usr/bin/env",
                nil,
                &attributes,
                UnsafeMutablePointer(mutating: buffer.baseAddress!),
                environ)
        }
        guard result == 0 else {
            logRuntime(
                "shell: posix_spawn failed (\(result)); not spawning '\(command)'")
            return
        }
        shellProcessID = child
        logRuntime(
            "shell: spawned '\(command)' pid=\(child) on the compositor display")
    }

    private func stopShellClient() async {
        let child = shellProcessID
        guard child > 0 else { return }
        shellProcessID = 0

        if waitpid(child, nil, WNOHANG) == child { return }
        _ = kill(child, SIGTERM)
        for _ in 0..<50 {
            if waitpid(child, nil, WNOHANG) == child { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = kill(child, SIGKILL)
        while waitpid(child, nil, 0) == -1, errno == EINTR {}
    }
}
