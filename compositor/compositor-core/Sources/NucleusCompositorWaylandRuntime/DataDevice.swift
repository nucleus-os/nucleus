// wl_data_device_manager on the router — clipboard (selection) and drag-and-drop.
// The router owns the protocol mechanics: data_source mime accumulation, minting a
// data_offer for the focused client, relaying the receiving client's fd back to the
// source as a `send` event (the data pipe), and selection bookkeeping. Compositor
// policy — which client holds keyboard focus, and the drag grab/hit-testing — is a
// delegate seam wired to RouterDataDeviceDriver.
//
// Ported from the legacy NucleusWaylandRouter/DataDevice.swift policy. The
// selection is delivered to a device when set (for the focused client) and when a
// client gains focus through the live seat driver.

import Glibc
import WaylandServerC
import WaylandServer
import WaylandServerDispatch
import NucleusCompositorServer

/// The compositor-policy seam for data-device. Focus decides selection delivery;
/// start_drag hands the drag session to the compositor's grab/hit-testing.
protocol DataDeviceDelegate: AnyObject {
    func dataDeviceClientFocused(_ clientKey: UInt) -> Bool
}

private final class WeakDataDevice {
    weak var device: WlDataDevice?
    init(_ device: WlDataDevice) { self.device = device }
}

private final class WeakDataOffer {
    weak var offer: WlDataOffer?
    init(_ offer: WlDataOffer) { self.offer = offer }
}

private final class ActiveWaylandDrag {
    weak var source: WlDataSource?
    weak var origin: WlSurface?
    weak var icon: WlSurface?
    let initiatingClientKey: UInt
    var targetSurfaceID: UInt32 = 0
    var targetDevices: [WeakDataDevice] = []
    var targetOffers: [WeakDataOffer] = []

    init(
        source: WlDataSource?,
        origin: WlSurface,
        icon: WlSurface?,
        initiatingClientKey: UInt
    ) {
        self.source = source
        self.origin = origin
        self.icon = icon
        self.initiatingClientKey = initiatingClientKey
    }
}

/// A clipboard selection's data source, abstracted over the protocol that owns it
/// (wl_data_source or ext_data_control_source_v1) so the focus-gated wl_data_device
/// and the always-on ext-data-control manager project one shared selection.
protocol SelectionSource: AnyObject {
    var selectionMimeTypes: [String] { get }
    /// Relay a receiving client's fd to the source (the data pipe). The source client
    /// writes + closes; this call owns the fd (dups or closes it).
    func sendSelection(mime: String, fd: Int32)
    /// The source is no longer the selection (it was replaced): notify its client so
    /// it can drop the source (wl_data_source.cancelled / ext_data_control_source.cancelled).
    func selectionCancelled()
}

/// An always-on observer of the clipboard selection (the ext-data-control manager),
/// re-projected on every change regardless of focus. Held weakly.
protocol SelectionObserver: AnyObject {
    func clipboardSelectionChanged(_ source: (any SelectionSource)?)
}

private final class WeakSelectionObserver {
    weak var observer: (any SelectionObserver)?
    init(_ observer: any SelectionObserver) { self.observer = observer }
}

final class WlDataDeviceManager {
    weak var delegate: DataDeviceDelegate?
    private unowned let compositor: WlCompositor
    fileprivate unowned let host: RouterHost

    private var devices: [WeakDataDevice] = []
    private var display: OpaquePointer?
    private var activeDrag: ActiveWaylandDrag?
    var dragActive: Bool { activeDrag != nil }
    /// The current clipboard selection source (held weakly — owned by its resource).
    /// Abstracted so an ext-data-control source can become the wl clipboard too.
    private weak var selection: (any SelectionSource)?
    /// Weak references are zeroed before their owner's `deinit`. Preserve only
    /// identity so source teardown can still prove that the dying resource owns
    /// the current selection without retaining it.
    private var selectionIdentity: ObjectIdentifier?
    /// Always-on selection observers (the ext-data-control manager); notified on every
    /// selection change so its clients stay current without focus.
    private var selectionObservers: [WeakSelectionObserver] = []

    /// The current selection source, for an observer's bind-time projection.
    var currentSelection: (any SelectionSource)? { selection }

    init(compositor: WlCompositor, host: RouterHost) {
        self.compositor = compositor
        self.host = host
    }

    func addSelectionObserver(_ observer: any SelectionObserver) {
        selectionObservers.removeAll { $0.observer == nil || $0.observer === observer }
        selectionObservers.append(WeakSelectionObserver(observer))
    }

    func register(in router: NucleusWaylandRouter) {
        // libwayland's wl_data_device_manager is v3 (no manager `release`); data
        // source/offer/device get their v3 set_actions/finish at this version.
        router.addGlobal(
            interface: swift_wayland_iface_wl_data_device_manager(), version: 3, impl: self, bind: Self.bind)
        display = router.display.display
    }

    fileprivate func addDevice(_ device: WlDataDevice) {
        devices.append(WeakDataDevice(device))
        // A newly-created device for the focused client immediately learns the
        // current selection.
        if delegate?.dataDeviceClientFocused(device.clientKey) == true {
            device.sendSelectionOffer(selection)
        }
    }

    fileprivate func removeDevice(_ device: WlDataDevice) {
        devices.removeAll { $0.device == nil || $0.device === device }
    }

    /// Set the clipboard selection and deliver it to every focused device. Called
    /// from wl_data_device.set_selection and from ext_data_control_device.set_selection.
    func setSelection(_ source: (any SelectionSource)?) {
        // The replaced source's client is told it lost the selection.
        let replacementIdentity = source.map(ObjectIdentifier.init)
        if selectionIdentity != replacementIdentity {
            selection?.selectionCancelled()
        }
        selection = source
        selectionIdentity = replacementIdentity
        for box in devices {
            guard let device = box.device else { continue }
            if delegate?.dataDeviceClientFocused(device.clientKey) == true {
                device.sendSelectionOffer(source)
            }
        }
        // The always-on observers (ext-data-control) re-project regardless of focus.
        selectionObservers.removeAll { $0.observer == nil }
        for box in selectionObservers { box.observer?.clipboardSelectionChanged(source) }
    }

    func selectionSourceDestroyed(_ source: any SelectionSource) {
        guard selectionIdentity == ObjectIdentifier(source) else { return }
        setSelection(nil)
    }

    /// Deliver the current selection to one client's devices on keyboard focus
    /// change.
    func deliverSelection(toClient clientKey: UInt) {
        for box in devices where box.device?.clientKey == clientKey {
            box.device?.sendSelectionOffer(selection)
        }
    }

    fileprivate func startDrag(
        source: WlDataSource?,
        origin: WlSurface,
        icon: WlSurface?,
        serial: UInt32,
        initiatingClientKey: UInt,
        initialTarget: (
            surfaceID: UInt64, x: Double, y: Double, timeMsec: UInt32
        )?
    ) {
        cancelActiveDrag(notifySource: true)
        activeDrag = ActiveWaylandDrag(
            source: source,
            origin: origin,
            icon: icon,
            initiatingClientKey: initiatingClientKey)
        if let initialTarget {
            _ = dragMotion(
                surfaceID: initialTarget.surfaceID,
                x: initialTarget.x,
                y: initialTarget.y,
                timeMsec: initialTarget.timeMsec)
        }
        guard let source else { return }
        let sourceHandle = source.exchangeHandle
        let originID = UInt64(origin.objectId)
        let iconID = UInt64(icon?.objectId ?? 0)
        _ = MainActor.assumeIsolated {
            DataExchangeService.shared.startDrag(
                source: sourceHandle,
                origin: originID,
                icon: iconID,
                target: DataClientHandle(rawValue: UInt64(initiatingClientKey)),
                serial: serial)
        }
    }

    /// Route one drag motion from the authoritative compositor hit test. Returns
    /// true while a DND grab owns pointer/touch motion.
    @discardableResult
    func dragMotion(
        surfaceID: UInt64,
        x: Double,
        y: Double,
        timeMsec: UInt32
    ) -> Bool {
        guard let drag = activeDrag else { return false }
        let surface = surfaceID == 0
            ? nil
            : compositor.surface(id: UInt32(truncatingIfNeeded: surfaceID))
        let targetClientKey = surface?.resource
            .flatMap(wl_resource_get_client)
            .map(WlSeat.clientKey)
        let permittedSurface: WlSurface?
        if drag.source == nil,
            targetClientKey != drag.initiatingClientKey
        {
            permittedSurface = nil
        } else {
            permittedSurface = surface
        }
        let newID = permittedSurface?.objectId ?? 0
        if drag.targetSurfaceID != newID {
            leaveCurrentTarget(drag)
            if let permittedSurface {
                enterTarget(
                    drag, surface: permittedSurface, x: x, y: y)
            }
        }
        for box in drag.targetDevices {
            guard let resource = box.device?.resource else { continue }
            WlDataDeviceServer.sendMotion(
                resource, time: timeMsec, x: x, y: y)
        }
        return true
    }

    /// End the active implicit DND grab when its final pointer/touch contact is
    /// released.
    @discardableResult
    func dropActiveDrag() -> Bool {
        guard let drag = activeDrag else { return false }
        let offers = drag.targetOffers.compactMap(\.offer)
        let accepted = offers.contains { $0.canDrop }
        guard drag.targetSurfaceID != 0,
            (drag.source == nil || accepted)
        else {
            cancelActiveDrag(notifySource: true)
            return true
        }
        for box in drag.targetDevices {
            if let resource = box.device?.resource {
                WlDataDeviceServer.sendDrop(resource)
            }
        }
        for offer in offers { offer.noteDropped() }
        drag.source?.sendDropPerformed()
        if let source = drag.source {
            let handle = source.exchangeHandle
            let mime = offers.compactMap(\.acceptedMimeType).first
            _ = MainActor.assumeIsolated {
                DataExchangeService.shared.dropDrag(
                    source: handle,
                    acceptedMimeType: mime)
            }
        }
        if offers.allSatisfy({ $0.version < 3 }) {
            activeDrag = nil
        }
        return true
    }

    func cancelActiveDrag(notifySource: Bool) {
        guard let drag = activeDrag else { return }
        leaveCurrentTarget(drag)
        if notifySource {
            drag.source?.sendDndCancelled()
            if let source = drag.source {
                let handle = source.exchangeHandle
                MainActor.assumeIsolated {
                    DataExchangeService.shared.cancelDrag(
                        source: handle)
                }
            }
        }
        activeDrag = nil
    }

    fileprivate func sourceDestroyed(_ source: WlDataSource) {
        selectionSourceDestroyed(source)
        if activeDrag?.source === source {
            cancelActiveDrag(notifySource: false)
        }
    }

    fileprivate func finishDrag(from offer: WlDataOffer) {
        guard let drag = activeDrag,
            drag.targetOffers.contains(where: { $0.offer === offer })
        else { return }
        drag.source?.sendDndFinished()
        activeDrag = nil
    }

    fileprivate func offerDestroyed(_ offer: WlDataOffer) {
        guard let drag = activeDrag,
            drag.targetOffers.contains(where: { $0.offer === offer })
        else { return }
        cancelActiveDrag(notifySource: true)
    }

    private func enterTarget(
        _ drag: ActiveWaylandDrag,
        surface: WlSurface,
        x: Double,
        y: Double
    ) {
        guard let surfaceResource = surface.resource,
            let client = wl_resource_get_client(surfaceResource)
        else { return }
        let clientKey = WlSeat.clientKey(client)
        let targets = devices.compactMap(\.device).filter {
            $0.clientKey == clientKey
        }
        drag.targetSurfaceID = surface.objectId
        drag.targetDevices = targets.map(WeakDataDevice.init)
        let serial = display.map(wl_display_next_serial) ?? 0
        for device in targets {
            let offer = drag.source.flatMap {
                device.makeDragOffer(source: $0, manager: self)
            }
            if let offer { drag.targetOffers.append(WeakDataOffer(offer)) }
            WlDataDeviceServer.sendEnter(
                device.resource!,
                serial: serial,
                surface: surfaceResource,
                x: x,
                y: y,
                id: offer?.resource)
        }
    }

    private func leaveCurrentTarget(_ drag: ActiveWaylandDrag) {
        guard drag.targetSurfaceID != 0 else { return }
        for box in drag.targetDevices {
            if let resource = box.device?.resource {
                WlDataDeviceServer.sendLeave(resource)
            }
        }
        drag.source?.sendTarget(nil)
        drag.source?.sendAction(0)
        drag.targetSurfaceID = 0
        drag.targetDevices.removeAll()
        drag.targetOffers.removeAll()
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: WlDataDeviceManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_wl_data_device_manager(),
            version: Int32(version), id: id, vtable: WlDataDeviceManagerServer.vtable, owner: me)
    }
}

extension WlDataDeviceManager: WlDataDeviceManagerRequests {
    // create_data_source(id)
    func createDataSource(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        let source = WlDataSource(
            manager: self, clientKey: WlSeat.clientKey(id.client))
        guard let sres = id.create(vtable: WlDataSourceServer.vtable, owner: source) else { return }
        source.bind(sres)
    }

    // get_data_device(id, seat)
    func getDataDevice(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                       seat: UnsafeMutablePointer<wl_resource>?) {
        guard let seat,
            let binding = WaylandResource.owner(
                of: seat, as: SeatBinding.self),
            wl_resource_get_client(seat) == id.client
        else { return }
        let device = WlDataDevice(
            manager: self,
            seat: binding.seat,
            clientKey: WlSeat.clientKey(id.client))
        guard let dres = id.create(vtable: WlDataDeviceServer.vtable, owner: device) else { return }
        device.bind(dres)
        addDevice(device)
    }
}

/// wl_data_source owner (Rule 9): the offered mime types and the data pipe.
final class WlDataSource {
    private enum Use: Equatable {
        case unused
        case selection
        case drag
    }

    private weak var manager: WlDataDeviceManager?
    let exchangeHandle: DataSourceHandle
    private(set) var mimes: [String] = []
    private(set) var actions: UInt32 = 0
    private var resource: UnsafeMutablePointer<wl_resource>?
    private var use: Use = .unused
    private var actionsSet = false

    init(manager: WlDataDeviceManager, clientKey: UInt) {
        self.manager = manager
        exchangeHandle = MainActor.assumeIsolated {
            let service = DataExchangeService.shared
            let handle = DataSourceHandle(rawValue: service.allocateHandle())
            service.sourceCreated(
                handle,
                ownerKind: .wayland,
                client: DataClientHandle(rawValue: UInt64(clientKey)))
            return handle
        }
    }

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) {
        self.resource = resource
        let handle = exchangeHandle
        let resourceAddress = UInt(bitPattern: resource)
        MainActor.assumeIsolated {
            DataExchangeService.shared.registerSourceEvents(
                handle,
                onSend: { mime, fd in
                    guard let resource = UnsafeMutablePointer<wl_resource>(
                        bitPattern: resourceAddress)
                    else {
                        if fd >= 0 { close(fd) }
                        return
                    }
                    mime.withCString { wl_data_source_send_send(resource, $0, fd) }
                    if fd >= 0 { close(fd) }
                },
                onCancel: {
                    guard let resource = UnsafeMutablePointer<wl_resource>(
                        bitPattern: resourceAddress)
                    else { return }
                    wl_data_source_send_cancelled(resource)
                })
        }
    }

    /// Relay a receiving client's fd to this source as a `send` event; the source
    /// client writes the data and closes the fd. The server owns the relayed fd.
    fileprivate func send(mime: String, fd: Int32) {
        guard let resource else { if fd >= 0 { close(fd) }; return }
        mime.withCString { wl_data_source_send_send(resource, $0, fd) }
        if fd >= 0 { close(fd) }
    }

    deinit {
        manager?.sourceDestroyed(self)
        let handle = exchangeHandle
        MainActor.assumeIsolated {
            _ = DataExchangeService.shared.sourceDestroyed(handle)
        }
    }

    fileprivate func claimForSelection() -> Bool {
        guard use == .unused, !actionsSet else { return false }
        use = .selection
        return true
    }

    fileprivate func claimForDrag() -> Bool {
        guard use == .unused else { return false }
        use = .drag
        return true
    }

    fileprivate var effectiveDragActions: UInt32 {
        actionsSet ? actions : 1
    }

    fileprivate func sendTarget(_ mime: String?) {
        guard let resource else { return }
        if let mime {
            mime.withCString {
                WlDataSourceServer.sendTarget(resource, mime_type: $0)
            }
        } else {
            WlDataSourceServer.sendTarget(resource, mime_type: nil)
        }
    }

    fileprivate func sendAction(_ action: UInt32) {
        guard let resource, wl_resource_get_version(resource) >= 3 else { return }
        WlDataSourceServer.sendAction(resource, dnd_action: action)
    }

    fileprivate func sendDropPerformed() {
        guard let resource, wl_resource_get_version(resource) >= 3 else { return }
        WlDataSourceServer.sendDndDropPerformed(resource)
    }

    fileprivate func sendDndFinished() {
        guard let resource, wl_resource_get_version(resource) >= 3 else { return }
        WlDataSourceServer.sendDndFinished(resource)
    }

    fileprivate func sendDndCancelled() {
        guard let resource else { return }
        WlDataSourceServer.sendCancelled(resource)
    }
}

extension WlDataSource: WlDataSourceRequests {
    func offer(_ resource: UnsafeMutablePointer<wl_resource>, mime_type: UnsafePointer<CChar>?) {
        guard let mime_type else { return }
        let mime = String(cString: mime_type)
        mimes.append(mime)
        let handle = exchangeHandle
        MainActor.assumeIsolated {
            DataExchangeService.shared.addMimeType(
                mime, to: handle)
        }
    }

    func setActions(_ resource: UnsafeMutablePointer<wl_resource>, dnd_actions: UInt32) {
        guard dnd_actions & ~DndActionNegotiation.allowedMask == 0 else {
            swift_wayland_resource_post_error(
                resource, 0 /* invalid_action_mask */,
                "drag action mask contains unsupported bits")
            return
        }
        guard !actionsSet, use == .unused else {
            swift_wayland_resource_post_error(
                resource, 1 /* invalid_source */,
                "drag actions can be set once before the source is used")
            return
        }
        actionsSet = true
        actions = dnd_actions
    }
}

extension WlDataSource: SelectionSource {
    var selectionMimeTypes: [String] { mimes }
    func sendSelection(mime: String, fd: Int32) { send(mime: mime, fd: fd) }
    /// wl_data_source.cancelled: this source is no longer the selection.
    func selectionCancelled() {
        guard let resource else { return }
        wl_data_source_send_cancelled(resource)
    }
}

/// wl_data_offer owner (Rule 9): introduces a source's mimes to a receiving client
/// and pipes its `receive` fd back to the source (which may be a wl_data_source or an
/// ext-data-control source — the shared SelectionSource).
final class WlDataOffer {
    enum Kind: Equatable {
        case selection
        case drag
    }

    private weak var manager: WlDataDeviceManager?
    private weak var source: (any SelectionSource)?
    private weak var dragSource: WlDataSource?
    private let kind: Kind
    private(set) var resource: UnsafeMutablePointer<wl_resource>?
    private(set) var version: Int32 = 1
    fileprivate var acceptedMimeType: String?
    private var selectedAction: UInt32 = 0
    private var dropped = false
    private var finished = false

    init(source: (any SelectionSource)?) {
        self.source = source
        kind = .selection
    }

    init(
        source: WlDataSource,
        manager: WlDataDeviceManager
    ) {
        self.source = source
        dragSource = source
        self.manager = manager
        kind = .drag
    }

    func bind(_ resource: UnsafeMutablePointer<wl_resource>) {
        self.resource = resource
        version = wl_resource_get_version(resource)
    }

    deinit {
        manager?.offerDestroyed(self)
    }

    var canDrop: Bool {
        kind == .drag
            && (version < 3
                || acceptedMimeType != nil && selectedAction != 0)
    }

    func noteDropped() { dropped = true }
}

extension WlDataOffer: WlDataOfferRequests {
    func accept(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32,
                mime_type: UnsafePointer<CChar>?) {
        guard !finished else {
            swift_wayland_resource_post_error(
                resource, 3 /* invalid_offer */, "offer is already finished")
            return
        }
        guard kind == .drag, let dragSource else { return }
        let requested = mime_type.map(String.init(cString:))
        acceptedMimeType = requested.flatMap {
            dragSource.mimes.contains($0) ? $0 : nil
        }
        dragSource.sendTarget(acceptedMimeType)
    }

    // receive(mime, fd): relay to the source's send event (the data transfer).
    func receive(_ resource: UnsafeMutablePointer<wl_resource>, mime_type: UnsafePointer<CChar>?, fd: Int32) {
        guard !finished else {
            if fd >= 0 { close(fd) }
            swift_wayland_resource_post_error(
                resource, 3 /* invalid_offer */, "offer is already finished")
            return
        }
        guard let mime_type else { if fd >= 0 { close(fd) }; return }
        guard let source else { if fd >= 0 { close(fd) }; return }
        source.sendSelection(mime: String(cString: mime_type), fd: fd)
    }

    func finish(_ resource: UnsafeMutablePointer<wl_resource>) {
        guard kind == .drag, dropped,
            acceptedMimeType != nil,
            selectedAction == 1 || selectedAction == 2,
            !finished
        else {
            swift_wayland_resource_post_error(
                resource, 0 /* invalid_finish */,
                "drag offer cannot be finished in its current state")
            return
        }
        finished = true
        manager?.finishDrag(from: self)
    }

    func setActions(_ resource: UnsafeMutablePointer<wl_resource>, dnd_actions: UInt32,
                    preferred_action: UInt32) {
        guard kind == .drag, let dragSource, !finished else {
            swift_wayland_resource_post_error(
                resource, 3 /* invalid_offer */,
                "actions are valid only on a live drag offer")
            return
        }
        do {
            let result = try DndActionNegotiation.resolve(
                sourceActions: dragSource.effectiveDragActions,
                destinationActions: dnd_actions,
                preferredAction: preferred_action)
            guard result.selectedAction != selectedAction else { return }
            selectedAction = result.selectedAction
            dragSource.sendAction(selectedAction)
            WlDataOfferServer.sendAction(
                resource, dnd_action: selectedAction)
        } catch DndActionNegotiation.ValidationError.invalidMask {
            swift_wayland_resource_post_error(
                resource, 1 /* invalid_action_mask */,
                "destination action mask contains unsupported bits")
        } catch {
            swift_wayland_resource_post_error(
                resource, 2 /* invalid_action */,
                "preferred action must be one advertised destination action")
        }
    }
}

/// wl_data_device owner (Rule 9): the per-seat clipboard/DnD endpoint for a client.
final class WlDataDevice {
    private weak var manager: WlDataDeviceManager?
    private weak var seat: WlSeat?
    let clientKey: UInt
    fileprivate var resource: UnsafeMutablePointer<wl_resource>?

    init(manager: WlDataDeviceManager, seat: WlSeat, clientKey: UInt) {
        self.manager = manager
        self.seat = seat
        self.clientKey = clientKey
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Emit data_offer + offer(mime)* + selection(offer) for `source`, or
    /// selection(null) to clear.
    fileprivate func sendSelectionOffer(_ source: (any SelectionSource)?) {
        guard let deviceRes = resource, let client = wl_resource_get_client(deviceRes) else { return }
        guard let source else {
            wl_data_device_send_selection(deviceRes, nil)
            return
        }
        let offer = WlDataOffer(source: source)
        guard let offerRes = WaylandResource.create(
                client: client, interface: swift_wayland_iface_wl_data_offer(),
                version: Int32(wl_resource_get_version(deviceRes)), id: 0,
                vtable: WlDataOfferServer.vtable, owner: offer)
        else { return }
        offer.bind(offerRes)
        wl_data_device_send_data_offer(deviceRes, offerRes)
        for mime in source.selectionMimeTypes {
            mime.withCString { wl_data_offer_send_offer(offerRes, $0) }
        }
        wl_data_device_send_selection(deviceRes, offerRes)
    }

    fileprivate func makeDragOffer(
        source: WlDataSource,
        manager: WlDataDeviceManager
    ) -> WlDataOffer? {
        guard let deviceRes = resource,
            let client = wl_resource_get_client(deviceRes)
        else { return nil }
        let offer = WlDataOffer(source: source, manager: manager)
        guard let offerResource = WaylandResource.create(
            client: client,
            interface: swift_wayland_iface_wl_data_offer(),
            version: Int32(wl_resource_get_version(deviceRes)),
            id: 0,
            vtable: WlDataOfferServer.vtable,
            owner: offer)
        else { return nil }
        offer.bind(offerResource)
        WlDataDeviceServer.sendDataOffer(deviceRes, id: offerResource)
        for mime in source.mimes {
            mime.withCString {
                WlDataOfferServer.sendOffer(
                    offerResource, mime_type: $0)
            }
        }
        if offer.version >= 3 {
            WlDataOfferServer.sendSourceActions(
                offerResource,
                source_actions: source.effectiveDragActions)
        }
        return offer
    }

    deinit { manager?.removeDevice(self) }
}

extension WlDataDevice: WlDataDeviceRequests {
    // start_drag(source, origin, icon, serial)
    func startDrag(_ resource: UnsafeMutablePointer<wl_resource>,
                   source sourceRes: UnsafeMutablePointer<wl_resource>?,
                   origin originRes: UnsafeMutablePointer<wl_resource>?,
                   icon iconRes: UnsafeMutablePointer<wl_resource>?, serial: UInt32) {
        let source = sourceRes.flatMap { WaylandResource.owner(of: $0, as: WlDataSource.self) }
        let origin = originRes.flatMap { WaylandResource.owner(of: $0, as: WlSurface.self) }
        let icon = iconRes.flatMap { WaylandResource.owner(of: $0, as: WlSurface.self) }
        guard let origin,
            seat?.authorize(
                serial: serial,
                clientKey: clientKey,
                surfaceID: origin.objectId,
                kinds: [.pointerButton, .touchDown]) == true
        else { return }
        if let source, !source.claimForDrag() {
            swift_wayland_resource_post_error(
                resource, 1 /* used_source */,
                "data source was already used")
            return
        }
        if let icon, !icon.claimDragIconRole() {
            swift_wayland_resource_post_error(
                resource, 0 /* WL_DATA_DEVICE_ERROR_ROLE */,
                "drag icon surface already has an incompatible role")
            return
        }
        let managerBits = manager.map {
            UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque())
        } ?? 0
        manager?.startDrag(
            source: source,
            origin: origin,
            icon: icon,
            serial: serial,
            initiatingClientKey: clientKey,
            initialTarget: MainActor.assumeIsolated {
                guard let managerPointer = UnsafeRawPointer(
                    bitPattern: managerBits)
                else { return nil }
                let manager = Unmanaged<WlDataDeviceManager>
                    .fromOpaque(managerPointer).takeUnretainedValue()
                let host = manager.host
                guard
                      let snapshot = host.inputHost?.dispatch.currentSnapshot()
                else { return nil }
                let hit = routerHitTest(
                    host: host,
                    sx: snapshot.cursorX, sy: snapshot.cursorY)
                return (
                    UInt64(hit.surfaceId), hit.localX, hit.localY,
                    UInt32(truncatingIfNeeded:
                        InputDispatch.monotonicNowNs() / 1_000_000))
            })
    }

    // set_selection(source, serial)
    func setSelection(_ resource: UnsafeMutablePointer<wl_resource>,
                      source sourceRes: UnsafeMutablePointer<wl_resource>?, serial: UInt32) {
        let source = sourceRes.flatMap { WaylandResource.owner(of: $0, as: WlDataSource.self) }
        guard seat?.authorize(
            serial: serial,
            clientKey: clientKey,
            kinds: [.pointerButton, .touchDown, .keyboardKey]) == true
        else { return }
        if let source, !source.claimForSelection() {
            swift_wayland_resource_post_error(
                resource, 1 /* used_source */,
                "data source was already used")
            return
        }
        manager?.setSelection(source)
    }
}
