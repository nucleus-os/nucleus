// wlr-layer-shell-unstable-v1 on the router — the panel/bar/wallpaper protocols.
// zwlr_layer_shell_v1 is the global factory; zwlr_layer_surface_v1 is the per-
// surface role. The role accumulates the anchor/size/exclusive-zone/margin/layer
// state, applies it at the surface commit, arranges the anchored geometry against
// the output, and sends configure/closed.
//
// The compositor owns layer-surface geometry: configure carries the arranged size,
// and the client acknowledges that configure before mapping a buffer. The arrange
// math (anchor/margin/fill) is router-owned; output selection for a null output arg,
// exclusive-zone publication, and the layer Window model use LayerShellDelegate.

import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes
import Glibc

// MARK: - Delegate seam

@MainActor
protocol LayerShellDelegate: AnyObject {
    /// The compositor DisplayID to use when get_layer_surface's output arg was nil.
    func defaultLayerOutputID() -> UInt64
    /// The logical rect to arrange against when get_layer_surface's output arg was
    /// null (the compositor picks its current primary output). nil rejects.
    func defaultLayerOutputRect() -> WlRect?
    /// A layer surface mapped (committed a buffer) with its arranged geometry —
    /// the cue to recompute the output's exclusive zones.
    func layerSurfaceMapped(_ surface: ZwlrLayerSurface)
    /// A layer surface unmapped: its role object was destroyed (while the wl_surface
    /// persists) or it committed a null buffer. Tears down the model window and
    /// releases its reserved exclusive zone so toplevels reclaim the band.
    func layerSurfaceUnmapped(surfaceID: UInt32)
}

// MARK: - zwlr_layer_shell_v1 global

@MainActor
final class ZwlrLayerShellBinding {
    unowned let shell: ZwlrLayerShell
    init(_ shell: ZwlrLayerShell) { self.shell = shell }
}

@MainActor
@safe final class ZwlrLayerShell {
    weak var delegate: (any LayerShellDelegate)?
    private var display: OpaquePointer?

    func register(in router: NucleusWaylandRouter) {
        unsafe display = router.display.display
        router.addGlobal(
            ZwlrLayerShellV1Server.global(
                implementation: self,
                advertisedVersion: 4,
                owner: { shell, _ in ZwlrLayerShellBinding(shell) }))
    }

    func nextSerial() -> UInt32 {
        guard let display = unsafe display else { return 0 }
        return unsafe wl_display_next_serial(display)
    }

}

extension ZwlrLayerShellBinding: ZwlrLayerShellV1Requests {
    func getLayerSurface(
        _ request: WaylandRequest<ZwlrLayerShellV1Server>,
        id: WlNewId<ZwlrLayerSurfaceV1Server>,
        surface surfaceRes: WaylandBorrowedObject<WlSurfaceServer>,
        output outputRes: WaylandBorrowedObject<WlOutputServer>?, layer: ZwlrLayerShellV1Layer,
        namespace namespacePtr: String
    ) {
        let me = shell
        guard let surface = surfaceRes.owner(as: WlSurface.self) else { return }
        guard layer.rawValue <= 3 else {
            request.postError(.invalidLayer, message: "layer out of range")
            return
        }
        // A wl_surface that already has a buffer committed cannot become a layer
        // surface: already_constructed (value 2 on the zwlr_layer_shell_v1). A prior
        // bufferless commit (e.g. a frame callback) is permitted, so this gates on
        // buffer content, not on `committed`.
        guard !surface.hasCurrentBuffer else {
            request.postError(.alreadyConstructed, message: "surface already has buffer content")
            return
        }
        let output = outputRes?.output
        let outputID = output?.info.outputId ?? me.delegate?.defaultLayerOutputID() ?? 0
        let rect = output?.logicalRect ?? me.delegate?.defaultLayerOutputRect()
        guard let rect else {
            request.postError(.invalidLayer, message: "no output for layer surface")
            return
        }
        let ns = namespacePtr
        guard !surface.hasRole else {
            request.postError(.role, message: "surface already has a role")
            return
        }
        _ = unsafe id.create(
            owner: { handle in
                ZwlrLayerSurface(
                    resource: handle,
                    shell: me,
                    surface: surface,
                    outputID: outputID,
                    outputRect: rect,
                    layer: layer.rawValue,
                    namespace: ns)
            },
            installed: { layerSurface in
                precondition(surface.assignRole(layerSurface))
            })
    }
}

// MARK: - zwlr_layer_surface_v1

/// A layer surface role. Accumulates the anchored-geometry request state, applies
/// it at commit, arranges against the output, and sends configure/closed. Anchor
/// bits: top=1, bottom=2, left=4, right=8.
@MainActor
@safe final class ZwlrLayerSurface: WlSurfaceRole {
    unowned let shell: ZwlrLayerShell
    weak var surface: WlSurface?
    let namespace: String
    let outputID: UInt64
    private let resource: WaylandResourceHandle<ZwlrLayerSurfaceV1Server>
    private var outputRect: WlRect

    // Pending (request) state.
    private var pendingWidth: Int32 = 0
    private var pendingHeight: Int32 = 0
    private var pendingAnchor: UInt32 = 0
    private var pendingExclusiveZone: Int32 = 0
    private var pendingMarginTop: Int32 = 0
    private var pendingMarginRight: Int32 = 0
    private var pendingMarginBottom: Int32 = 0
    private var pendingMarginLeft: Int32 = 0
    private var pendingKeyboard: UInt32 = 0
    private var pendingLayer: UInt32

    // Applied (committed) state.
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var anchor: UInt32 = 0
    private(set) var exclusiveZone: Int32 = 0
    private var marginTop: Int32 = 0
    private var marginRight: Int32 = 0
    private var marginBottom: Int32 = 0
    private var marginLeft: Int32 = 0
    private(set) var keyboardInteractivity: UInt32 = 0
    private(set) var layer: UInt32

    // Arranged geometry.
    private(set) var arrangedX: Int32 = 0
    private(set) var arrangedY: Int32 = 0
    private(set) var configuredWidth: UInt32 = 1
    private(set) var configuredHeight: UInt32 = 1

    private var configured = false
    private var outstandingConfigureSerials: [UInt32] = []
    private var acknowledgedConfigureSerial: UInt32?
    private(set) var mapped = false
    private var reportedMap = false
    /// Set once the compositor sends `closed`; further client changes are ignored.
    private var closed = false
    /// Cached wl_surface id for teardown — `surface` is weak and may already be nil
    /// when the role object is destroyed.
    let surfaceObjectID: UInt32

    /// The exclusive-zone / layout-relevant arranged state used to build the layout
    /// policy's `LayerSurfaceRecord`.
    struct LayerArrangement: Sendable {
        let layer: UInt32
        let anchor: UInt32
        let exclusiveZone: Int32
        let marginTop: Int32
        let marginRight: Int32
        let marginBottom: Int32
        let marginLeft: Int32
        let outputID: UInt64
        let namespace: String
        let keyboardInteractivity: UInt32
    }

    var arrangement: LayerArrangement {
        LayerArrangement(
            layer: layer, anchor: anchor, exclusiveZone: exclusiveZone,
            marginTop: marginTop, marginRight: marginRight,
            marginBottom: marginBottom, marginLeft: marginLeft,
            outputID: outputID, namespace: namespace,
            keyboardInteractivity: keyboardInteractivity)
    }

    init(
        resource: WaylandResourceHandle<ZwlrLayerSurfaceV1Server>,
        shell: ZwlrLayerShell,
        surface: WlSurface,
        outputID: UInt64,
        outputRect: WlRect,
        layer: UInt32,
        namespace: String
    ) {
        self.resource = resource
        self.shell = shell
        self.surface = surface
        self.outputID = outputID
        self.outputRect = outputRect
        self.layer = layer
        self.pendingLayer = layer
        self.namespace = namespace
        self.surfaceObjectID = surface.objectId
    }

    // MARK: WlSurfaceRole

    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool {
        guard !closed else { return true }
        if !configured {
            guard !context.willHaveBuffer else {
                postSurfaceError(
                    .invalidSurfaceState,
                    "buffer attached before the initial configure")
                return false
            }
            return true
        }
        if context.willHaveBuffer,
            acknowledgedConfigureSerial == nil
        {
            postSurfaceError(
                .invalidSurfaceState,
                "buffer committed before acknowledging a configure")
            return false
        }
        if let error = sizeAnchorError() {
            postSurfaceError(.invalidSize, error)
            return false
        }
        return true
    }

    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool) {
        // After `closed`, "further changes to the surface will be ignored."
        guard !closed else { return }
        if isInitial {
            // A buffer attached before the first configure is a protocol error.
            guard !surface.hasCurrentBuffer else {
                postSurfaceError(
                    .invalidSurfaceState,
                    "buffer attached before first configure")
                return
            }
            if let err = sizeAnchorError() {
                postSurfaceError(.invalidSize, err)
                return
            }
            applyAndArrange()
            sendConfigure()
            diagnostic("configure surface=\(surfaceObjectID) output=\(outputID) layer=\(layer) size=\(configuredWidth)x\(configuredHeight) namespace=\(namespace)")
            configured = true
        } else if !surface.hasCurrentBuffer {
            // Committing a null buffer unmaps the layer surface.
            if mapped {
                mapped = false
                shell.delegate?.layerSurfaceUnmapped(surfaceID: surfaceObjectID)
            }
        } else {
            if let err = sizeAnchorError() {
                postSurfaceError(.invalidSize, err)
                return
            }
            mapped = true
            applyAndArrange()
            if !reportedMap {
                reportedMap = true
                diagnostic("commit-buffer surface=\(surfaceObjectID) output=\(outputID) layer=\(layer) size=\(configuredWidth)x\(configuredHeight) namespace=\(namespace)")
            }
            shell.delegate?.layerSurfaceMapped(self)
        }
    }

    func roleSurfaceDestroyed(_ surface: WlSurface) { self.surface = nil }

    /// zwlr_layer_surface_v1.destroy runs as the resource's semantic teardown (the
    /// owner is released when libwayland destroys the resource): unmap first —
    /// tearing down the model window + exclusive zone even when the client keeps the
    /// underlying wl_surface. Without the unmap the reserved exclusive band leaks.
    isolated deinit {
        if mapped { shell.delegate?.layerSurfaceUnmapped(surfaceID: surfaceObjectID) }
    }

    /// invalid_size guard: a 0 width/height requires the surface to be anchored to
    /// both opposing edges in that axis (the compositor fills the omitted span).
    /// Returns a diagnostic when the pending state violates it, else nil.
    private func sizeAnchorError() -> String? {
        let leftRight: UInt32 = 4 | 8
        let topBottom: UInt32 = 1 | 2
        if pendingWidth == 0, pendingAnchor & leftRight != leftRight {
            return "width 0 requires left+right anchors"
        }
        if pendingHeight == 0, pendingAnchor & topBottom != topBottom {
            return "height 0 requires top+bottom anchors"
        }
        return nil
    }

    private func postSurfaceError(
        _ code: ZwlrLayerSurfaceV1Error,
        _ message: String
    ) {
        resource.postError(code, message: message)
    }

    private func diagnostic(_ message: String) {
        let line = "layer-shell: \(message)\n"
        line.withCString {
            _ = unsafe write(STDERR_FILENO, $0, strlen($0))
        }
    }

    /// The pinned output disappeared. Close the role and release its shell-policy
    /// reservation immediately; the client destroys the role resource afterward.
    func outputRemoved() {
        guard !closed else { return }
        closed = true
        if mapped {
            mapped = false
            shell.delegate?.layerSurfaceUnmapped(surfaceID: surfaceObjectID)
        }
        resource.sendClosed()
    }

    /// Re-arrange a pinned layer surface against an updated logical output rect.
    /// A fresh configure creates a new ack boundary before the next mapped commit.
    func outputChanged(rect: WlRect) {
        guard !closed, outputRect != rect else { return }
        outputRect = rect
        guard configured else { return }
        arrange()
        acknowledgedConfigureSerial = nil
        sendConfigure()
        if mapped {
            shell.delegate?.layerSurfaceMapped(self)
        }
    }

    /// zwlr_layer_surface_v1.closed — the compositor asks the client to destroy the
    /// surface (its output vanished with no fallback).
    func sendClosed() {
        closed = true
        resource.sendClosed()
    }

    // MARK: arrange

    private func applyAndArrange() {
        width = pendingWidth
        height = pendingHeight
        anchor = pendingAnchor
        exclusiveZone = pendingExclusiveZone
        marginTop = pendingMarginTop
        marginRight = pendingMarginRight
        marginBottom = pendingMarginBottom
        marginLeft = pendingMarginLeft
        keyboardInteractivity = pendingKeyboard
        layer = pendingLayer
        arrange()
    }

    /// Anchor/margin/size → x/y + configured size against the output rect. Anchored
    /// to opposite edges with size 0 fills that axis (minus margins); else pinned to
    /// the anchored edge or centered.
    private func arrange() {
        let ow = max(1, outputRect.width)
        let oh = max(1, outputRect.height)
        let aTop = (anchor & 1) != 0
        let aBottom = (anchor & 2) != 0
        let aLeft = (anchor & 4) != 0
        let aRight = (anchor & 8) != 0

        var w = width
        var h = height
        if aLeft && aRight && width == 0 { w = ow - marginLeft - marginRight }
        if aTop && aBottom && height == 0 { h = oh - marginTop - marginBottom }
        w = max(1, w)
        h = max(1, h)

        var x: Int32
        if aLeft && aRight { x = marginLeft }
        else if aLeft { x = marginLeft }
        else if aRight { x = ow - w - marginRight }
        else { x = (ow - w) / 2 }

        var y: Int32
        if aTop && aBottom { y = marginTop }
        else if aTop { y = marginTop }
        else if aBottom { y = oh - h - marginBottom }
        else { y = (oh - h) / 2 }

        arrangedX = outputRect.x + x
        arrangedY = outputRect.y + y
        configuredWidth = UInt32(max(1, w))
        configuredHeight = UInt32(max(1, h))
    }

    private func sendConfigure() {
        let serial = shell.nextSerial()
        outstandingConfigureSerials.append(serial)
        resource.sendConfigure(
            serial: serial,
            width: configuredWidth,
            height: configuredHeight)
    }

}

// MARK: requests

extension ZwlrLayerSurface: ZwlrLayerSurfaceV1Requests {
    func setSize(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, width w: UInt32, height h: UInt32) {
        pendingWidth = Int32(bitPattern: w)
        pendingHeight = Int32(bitPattern: h)
    }

    func setAnchor(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, anchor a: ZwlrLayerSurfaceV1Anchor) {
        // anchor is a bitfield of top=1|bottom=2|left=4|right=8; any other bit is
        // invalid_anchor (value 2 on the layer_surface).
        guard a.rawValue & ~UInt32(0xF) == 0 else {
            request.postError(.invalidAnchor, message: "anchor bits out of range")
            return
        }
        pendingAnchor = a.rawValue
    }

    func setExclusiveZone(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, zone z: Int32) {
        pendingExclusiveZone = z
    }

    func setMargin(
        _ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, top: Int32, right: Int32, bottom: Int32, left: Int32
    ) {
        pendingMarginTop = top; pendingMarginRight = right
        pendingMarginBottom = bottom; pendingMarginLeft = left
    }

    func setKeyboardInteractivity(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, keyboard_interactivity ki: ZwlrLayerSurfaceV1KeyboardInteractivity) {
        guard ki.rawValue <= 2 else {
            request.postError(.invalidKeyboardInteractivity, message: "bad keyboard interactivity")
            return
        }
        pendingKeyboard = ki.rawValue
    }

    func setLayer(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, layer: ZwlrLayerShellV1Layer) {
        guard layer.rawValue <= 3 else {
            // invalid_layer belongs to the zwlr_layer_shell_v1 error enum (value 1);
            // wlroots posts it on the layer_surface resource, matching get_layer_surface.
            request.postError(.invalidSize, message: "layer out of range")
            return
        }
        pendingLayer = layer.rawValue
    }

    func setExclusiveEdge(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, edge: ZwlrLayerSurfaceV1Anchor) {
        // Unreachable while the global advertises v4. Restore v5 only with
        // validated, double-buffered exclusive-edge layout behavior.
    }

    func getPopup(
        _ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, popup popupRes: WaylandBorrowedObject<XdgPopupServer>
    ) {
        // Adopt a same-client xdg popup: re-drive its configure so it maps under the
        // layer surface. libwayland hands the popup as a live resource — the retired
        // cross-client XdgWmBaseTable lookup is gone.
        guard let popup = popupRes.owner(as: XdgPopup.self) else { return }
        popup.adoptLayerParent(surface)
    }

    func ackConfigure(_ request: WaylandRequest<ZwlrLayerSurfaceV1Server>, serial: UInt32) {
        guard let index = outstandingConfigureSerials.firstIndex(
            of: serial)
        else {
            request.postError(.invalidSurfaceState, message: "configure serial was not issued by this layer surface")
            return
        }
        acknowledgedConfigureSerial = serial
        outstandingConfigureSerials.removeSubrange(
            ...index)
    }
}
import NucleusRenderModel
