import NucleusCompositorServer
import NucleusCompositorShell
import NucleusCompositorOverlayScene
import NucleusCompositorOverlayTypes
import NucleusAppHostBundle
import NucleusCompositorRenderRuntime
import NucleusCompositorRenderSession
import NucleusRenderer
import NucleusRenderHost
import NucleusCompositorRendererLinux
import NucleusCompositorWaylandRuntime
import Glibc

// Compositor bring-up + teardown, Swift-owned.
// `nucleus_runtime_main` (Runtime.swift) calls `bringUp` on the main actor, runs the
// loop, then `teardown`. Every platform step is a direct Swift call into the owner
// module (the input/router/xwm hosts in NucleusCompositorWaylandRuntime, the render runtime +
// DRM session in NucleusCompositorRenderRuntime, DRM discovery in NucleusRenderer, the shell
// services in NucleusCompositorShell); the display model + router seed + first frame go
// through the Swift owners (`NucleusCompositorServer.shared.layout`, `DisplayFrameDemand`,
// `OverlaySceneRuntime.shared`) directly.

extension CompositorRuntime {
    /// Bring the compositor up. Discovers the DRM device (Swift, over libdrm), opens
    /// the seat + DRM primary node, brings up the render runtime, and starts the
    /// router/shell/input. Returns false on a fatal bring-up failure (the caller
    /// tears down + exits non-zero).
    func bringUp() -> Bool {
        SceneCommitFrameDemand.install {
            DisplayFrameDemand.requestFrame()
        }
        // ── DRM device discovery (Swift-owned, over libdrm) ───────────────
        var primaryPathBuf = [CChar](repeating: 0, count: 256)
        var renderFd: Int32 = -1
        let discovered = primaryPathBuf.withUnsafeMutableBufferPointer { buf in
            nucleus_drm_discover(buf.baseAddress!, buf.count, &renderFd)
        }
        guard discovered else {
            logRuntime("DRM device discovery failed")
            return false
        }

        // ── libseat session + DRM primary node (Swift-owned) ──────────────
        guard nucleus_input_host_open_seat() else {
            logRuntime("session: failed to open Swift-owned seat")
            return false
        }

        // Install the inverted seams the substrate/render modules reach up through:
        // session lifecycle (input host → root), the render runtime's device-seat
        // opener (render → input host), and the wayland surface-commit upload sink
        // (router → render runtime). The DRM-session open below uses the device seat,
        // so it is installed first.
        NucleusCompositorServer.shared.sessionControl = self
        DrmSession.installDeviceSeat(
            open: { nucleus_input_host_open_device($0) },
            close: { nucleus_input_host_close_device($0) })
        NucleusCompositorServer.shared.renderUpload = RenderUploadSink(
            uploadShm: { RenderRuntime.uploadShm($0, $1, $2, $3, $4, $5) },
            uploadDmabuf: { (prev, w, h, fmt, mod, n, fds, offs, strides, fence, ah, ap, rh, rp) in
                RenderRuntime.uploadDmabuf(prev, w, h, fmt, mod, n, fds, offs, strides, fence, ah, ap, rh, rp)
            },
            iosurfaceRelease: { RenderRuntime.releaseIOSurface($0) },
            dmabufFormats: { RenderRuntime.dmabufFormats($0, $1, $2) },
            dmabufMainDevice: { RenderRuntime.dmabufMainDevice },
            syncobjImportTimeline: { RenderRuntime.importSyncobjTimeline(fd: $0) },
            syncobjDestroyTimeline: { RenderRuntime.destroySyncobjTimeline(handle: $0) },
            screencopyCapture: { RenderRuntime.screencopyCapture(outputId: $0) },
            surfaceReadback: { RenderRuntime.surfaceReadback(iosurfaceId: $0) },
            screencopyCaptureDmabuf: { outputId, w, h, fmt, mod, n, fds, offs, strides, sx, sy, sw, sh, cursor in
                RenderRuntime.screencopyCaptureDmabuf(
                    outputId: outputId, width: w, height: h, drmFormat: fmt, modifier: mod,
                    nPlanes: n, fds: fds, offsets: offs, strides: strides,
                    sourceX: sx, sourceY: sy, sourceWidth: sw, sourceHeight: sh,
                    overlayCursor: cursor)
            })

        let primaryFd = primaryPathBuf.withUnsafeBufferPointer { DrmSession.open(path: $0.baseAddress!) }
        guard primaryFd >= 0 else {
            logRuntime("session: failed to open DRM primary node through the seat")
            return false
        }

        let scale = outputScale
        let intScale = UInt32(max(1.0, scale.rounded(.up)))

        // ── Render host bundle + overlay controller ───────────────────────
        // The render runtime queries the host bundle conformers, and the overlay
        // controller must exist before the first frame, so install both before
        // render bring-up.
        guard nucleus_app_host_bundle_install_production() != 0 else {
            logRuntime("render host bundle install failed")
            return false
        }
        guard nucleus_shell_overlay_publication_install() != 0 else {
            logRuntime("overlay runtime host install failed")
            return false
        }
        // Install the shell's conformer to the inverted input→shell seam so the
        // input dispatch reaches cursor/bezel/overlay policy + keybinds.
        NucleusCompositorServer.shared.shellPolicy = ShellPolicyService.shared

        // ── Swift render runtime ──────────────────────────────────────────
        guard RenderRuntime.bringUp(drmDeviceFd: primaryFd) else {
            logRuntime("render runtime: Swift bring-up failed")
            return false
        }
        RenderRuntime.captureMainDevice(renderNodeFd: renderFd)
        RenderRuntime.installSurfaceRetirement {
            WaylandRuntime.noteSurfaceBufferRetired($0)
        }
        let attached = RenderRuntime.enumerateOutputs(fractionalScale: scale)
        guard !attached.isEmpty else {
            logRuntime("render runtime: no physical DRM outputs attached")
            return false
        }
        for (index, output) in attached.enumerated() {
            let mode = DisplayMode(
                pixelWidth: output.pixelWidth,
                pixelHeight: output.pixelHeight,
                refreshMhz: output.refreshMhz)
            let config = DisplayConfiguration(
                enabled: true, primary: index == 0,
                logicalX: 0, logicalY: 0,
                logicalWidth: Double(output.pixelWidth) / scale,
                logicalHeight: Double(output.pixelHeight) / scale,
                scale: intScale, fractionalScale: scale, mode: mode)
            NucleusCompositorServer.shared.layout.addDisplay(
                id: output.id, configuration: config,
                name: "DRM-\(output.id)", description: "Nucleus DRM output",
                physicalWidthMM: output.physicalWidthMM,
                physicalHeightMM: output.physicalHeightMM)
        }
        logRuntime("render runtime: Swift render path active for \(attached.count) output(s)")

        // Present-report seam: fold each output's scanout submit / page-flip into its
        // DisplayLink present-id ack, and ack the session-lock gate on flip completion.
        // The `locked` security invariant is confirmed by a real present here (the
        // author-time blank filter, applied in the scene author, is the other half).
        RenderRuntime.installPresentReport(
            submitted: { outputID in
                guard let display = NucleusCompositorServer.shared.layout.display(id: outputID) else { return }
                DisplayFrameDemand.willSubmit(display)
                display.noteFrameSubmitted()
                DisplayFrameDemand.didSubmit(display)
            },
            presented: { outputID, presentationNs, sequence in
                // The kernel's real flip timestamp/sequence (from the page-flip event) — not a
                // re-sampled wall clock — drives the DisplayLink ack, the session-lock ack, AND the
                // client-facing tick: wl_surface.frame + wp_presentation_feedback for this output.
                let display = NucleusCompositorServer.shared.layout.display(id: outputID)
                let predicted = display?.displayLink.predictedPresentNs(0) ?? presentationNs
                display?.noteFramePresented(presentationNs: presentationNs)
                if let display {
                    DisplayFrameDemand.didPresent(
                        display, presentationNs: presentationNs,
                        predictedPresentNs: predicted)
                }
                WaylandRuntime.noteSessionLockPresented(outputID)
                let refreshNs = UInt32(truncatingIfNeeded: display?.displayLink.refreshIntervalNs ?? 16_666_666)
                WaylandRuntime.notePresented(outputID, presentationNs, refreshNs, sequence)
            })

        // Seed the overlay scene's initial output geometry.
        if let primary = NucleusCompositorServer.shared.layout.displays.first {
            OverlaySceneRuntime.shared.frameUpdated(FrameInfo(
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
        WaylandRuntime.activateRouter()
        seedRouter()
        nucleus_input_host_publish_keymap()
        guard WaylandRuntime.addSocket() else {
            logRuntime("router add_socket failed; no Wayland socket available")
            return false
        }
        logRuntime("Wayland compositor listening on the libwayland router")

        // ── Shell D-Bus services + desktop shell ──────────────────────────
        nucleus_shell_dbus_start()
        spawnShellClient()

        // ── XWayland (lazy spawn) ─────────────────────────────────────────
        if !nucleus_xwm_host_init() {
            logRuntime("[xwayland] init failed — continuing without X11 support")
        }

        // ── libinput + DRM connector-hotplug monitor (Swift-owned) ────────
        guard nucleus_input_host_start_libinput() else {
            logRuntime("session: failed to start Swift-owned libinput")
            return false
        }

        // ── Hardware cursor + first frame ─────────────────────────────────
        nucleus_compositor_cursor_apply_default()
        DisplayFrameDemand.requestFrame()
        return true
    }

    /// Tear down in reverse acquisition order: render runtime (holds GPU state over
    /// the borrowed DRM master fd) first, then xwm, the host bundle, the overlay
    /// host, the DRM session, and the seat/libinput.
    func teardown() {
        SceneCommitFrameDemand.clear()
        logRuntime("shutdown: render runtime")
        RenderRuntime.shutdown()
        // Release DRM master and return the primary fd to libseat immediately
        // after scanout teardown. Xwayland/D-Bus/client cleanup must not be able to
        // delay restoring the VT if one of those services blocks during shutdown.
        logRuntime("shutdown: DRM session")
        DrmSession.close()
        logRuntime("shutdown: Xwayland")
        nucleus_xwm_host_shutdown()
        logRuntime("shutdown: app hosts")
        nucleus_app_host_bundle_clear_production()
        nucleus_shell_overlay_publication_clear()
        logRuntime("shutdown: input seat")
        nucleus_input_host_shutdown()
        logRuntime("shutdown: complete")
    }

    /// Seed the router's `wl_output` set from the Swift display layout (Swift→Swift).
    private func seedRouter() {
        for display in NucleusCompositorServer.shared.layout.displays {
            display.name.withCString { namePtr in
                display.description.withCString { descPtr in
                    WaylandRuntime.addOutput(
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

    /// Spawn the desktop shell (Noctalia) as a detached Wayland client on the
    /// compositor's WAYLAND_DISPLAY. The command (NUCLEUS_SHELL_CMD, default
    /// "noctalia -d") is whitespace-split into argv; empty disables spawning. We
    /// double-fork so the shell reparents to init: the compositor neither blocks on
    /// it nor leaks a zombie.
    private func spawnShellClient() {
        let command: String
        if let raw = getenv("NUCLEUS_SHELL_CMD") {
            command = String(cString: raw)
        } else {
            command = "noctalia -d"
        }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else {
            logRuntime("shell: NUCLEUS_SHELL_CMD is empty; not spawning a desktop shell")
            return
        }

        let child = fork()
        if child < 0 {
            logRuntime("shell: fork failed; not spawning '\(command)'")
            return
        }
        if child == 0 {
            // Middle process: detach into a new session, then fork the shell so it
            // reparents to init when this process exits immediately below.
            _ = setsid()
            let grandchild = fork()
            if grandchild == 0 {
                let cArgs: [UnsafeMutablePointer<CChar>?] = tokens.map { strdup($0) } + [nil]
                if let file = cArgs[0] { _ = execvp(file, cArgs) }
                _exit(127)
            }
            _exit(0)
        }

        // Parent: reap the short-lived middle process so it never lingers as a
        // zombie. The shell itself is now a child of init.
        var status: Int32 = 0
        _ = waitpid(child, &status, 0)
        logRuntime("shell: spawned '\(command)' on the compositor display")
    }
}
