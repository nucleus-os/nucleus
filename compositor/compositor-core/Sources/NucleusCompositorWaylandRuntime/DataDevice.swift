// wl_data_device_manager on the router — clipboard (selection) and drag-and-drop.
// The router owns the protocol mechanics: data_source mime accumulation, minting a
// data_offer for the focused client, relaying the receiving client's fd back to the
// source as a `send` event (the data pipe), and selection bookkeeping. Compositor
// policy — which client holds keyboard focus, and the drag grab/hit-testing — is a
// delegate seam wired at #12.
//
// Ported from the legacy NucleusWaylandRouter/DataDevice.swift policy. The
// selection is delivered to a device when set (for the focused client) and when a
// client gains focus (deliverSelection, called by the seat at #12).

import Glibc
import WaylandServerC
import WaylandServer
import WaylandServerDispatch

/// The compositor-policy seam for data-device. Focus decides selection delivery;
/// start_drag hands the drag session to the compositor's grab/hit-testing.
protocol DataDeviceDelegate: AnyObject {
    func dataDeviceClientFocused(_ clientKey: UInt) -> Bool
    func dataDeviceStartDrag(source: WlDataSource?, origin: WlSurface?, icon: WlSurface?, serial: UInt32)
}
extension DataDeviceDelegate {
    func dataDeviceClientFocused(_ clientKey: UInt) -> Bool { true }
    func dataDeviceStartDrag(source: WlDataSource?, origin: WlSurface?, icon: WlSurface?, serial: UInt32) {}
}

private final class WeakDataDevice {
    weak var device: WlDataDevice?
    init(_ device: WlDataDevice) { self.device = device }
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

    private var devices: [WeakDataDevice] = []
    /// The current clipboard selection source (held weakly — owned by its resource).
    /// Abstracted so an ext-data-control source can become the wl clipboard too.
    private weak var selection: (any SelectionSource)?
    /// Always-on selection observers (the ext-data-control manager); notified on every
    /// selection change so its clients stay current without focus.
    private var selectionObservers: [WeakSelectionObserver] = []

    /// The current selection source, for an observer's bind-time projection.
    var currentSelection: (any SelectionSource)? { selection }

    func addSelectionObserver(_ observer: any SelectionObserver) {
        selectionObservers.removeAll { $0.observer == nil || $0.observer === observer }
        selectionObservers.append(WeakSelectionObserver(observer))
    }

    func register(in router: NucleusWaylandRouter) {
        // libwayland's wl_data_device_manager is v3 (no manager `release`); data
        // source/offer/device get their v3 set_actions/finish at this version.
        router.addGlobal(
            interface: swift_wayland_iface_wl_data_device_manager(), version: 3, impl: self, bind: Self.bind)
    }

    fileprivate func addDevice(_ device: WlDataDevice) {
        devices.append(WeakDataDevice(device))
        // A newly-created device for the focused client immediately learns the
        // current selection.
        if delegate?.dataDeviceClientFocused(device.clientKey) ?? true {
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
        if let old = selection, old !== source { old.selectionCancelled() }
        selection = source
        for box in devices {
            guard let device = box.device else { continue }
            if delegate?.dataDeviceClientFocused(device.clientKey) ?? true {
                device.sendSelectionOffer(source)
            }
        }
        // The always-on observers (ext-data-control) re-project regardless of focus.
        selectionObservers.removeAll { $0.observer == nil }
        for box in selectionObservers { box.observer?.clipboardSelectionChanged(source) }
    }

    /// Deliver the current selection to one client's devices — the seat calls this
    /// on keyboard focus change at #12.
    func deliverSelection(toClient clientKey: UInt) {
        for box in devices where box.device?.clientKey == clientKey {
            box.device?.sendSelectionOffer(selection)
        }
    }

    fileprivate func startDrag(source: WlDataSource?, origin: WlSurface?, icon: WlSurface?, serial: UInt32) {
        delegate?.dataDeviceStartDrag(source: source, origin: origin, icon: icon, serial: serial)
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
        let source = WlDataSource()
        guard let sres = id.create(vtable: WlDataSourceServer.vtable, owner: source) else { return }
        source.bind(sres)
    }

    // get_data_device(id, seat)
    func getDataDevice(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                       seat: UnsafeMutablePointer<wl_resource>?) {
        let device = WlDataDevice(manager: self, clientKey: WlSeat.clientKey(id.client))
        guard let dres = id.create(vtable: WlDataDeviceServer.vtable, owner: device) else { return }
        device.bind(dres)
        addDevice(device)
    }
}

/// wl_data_source owner (Rule 9): the offered mime types and the data pipe.
final class WlDataSource {
    private(set) var mimes: [String] = []
    private(set) var actions: UInt32 = 0
    private var resource: UnsafeMutablePointer<wl_resource>?

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Relay a receiving client's fd to this source as a `send` event; the source
    /// client writes the data and closes the fd. The server owns the relayed fd.
    fileprivate func send(mime: String, fd: Int32) {
        guard let resource else { if fd >= 0 { close(fd) }; return }
        mime.withCString { wl_data_source_send_send(resource, $0, fd) }
        if fd >= 0 { close(fd) }
    }
}

extension WlDataSource: WlDataSourceRequests {
    func offer(_ resource: UnsafeMutablePointer<wl_resource>, mime_type: UnsafePointer<CChar>?) {
        guard let mime_type else { return }
        mimes.append(String(cString: mime_type))
    }

    func setActions(_ resource: UnsafeMutablePointer<wl_resource>, dnd_actions: UInt32) {
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
    private weak var source: (any SelectionSource)?
    init(source: (any SelectionSource)?) { self.source = source }
}

extension WlDataOffer: WlDataOfferRequests {
    func accept(_ resource: UnsafeMutablePointer<wl_resource>, serial: UInt32,
                mime_type: UnsafePointer<CChar>?) {}  // feedback only; the compositor needs no state here

    // receive(mime, fd): relay to the source's send event (the data transfer).
    func receive(_ resource: UnsafeMutablePointer<wl_resource>, mime_type: UnsafePointer<CChar>?, fd: Int32) {
        guard let mime_type else { if fd >= 0 { close(fd) }; return }
        guard let source else { if fd >= 0 { close(fd) }; return }
        source.sendSelection(mime: String(cString: mime_type), fd: fd)
    }

    func finish(_ resource: UnsafeMutablePointer<wl_resource>) {}

    func setActions(_ resource: UnsafeMutablePointer<wl_resource>, dnd_actions: UInt32,
                    preferred_action: UInt32) {}
}

/// wl_data_device owner (Rule 9): the per-seat clipboard/DnD endpoint for a client.
final class WlDataDevice {
    private weak var manager: WlDataDeviceManager?
    let clientKey: UInt
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(manager: WlDataDeviceManager, clientKey: UInt) {
        self.manager = manager
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
        guard let offerRes = WaylandResource.create(
                client: client, interface: swift_wayland_iface_wl_data_offer(),
                version: Int32(wl_resource_get_version(deviceRes)), id: 0,
                vtable: WlDataOfferServer.vtable, owner: WlDataOffer(source: source))
        else { return }
        wl_data_device_send_data_offer(deviceRes, offerRes)
        for mime in source.selectionMimeTypes {
            mime.withCString { wl_data_offer_send_offer(offerRes, $0) }
        }
        wl_data_device_send_selection(deviceRes, offerRes)
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
        manager?.startDrag(source: source, origin: origin, icon: icon, serial: serial)
    }

    // set_selection(source, serial)
    func setSelection(_ resource: UnsafeMutablePointer<wl_resource>,
                      source sourceRes: UnsafeMutablePointer<wl_resource>?, serial: UInt32) {
        let source = sourceRes.flatMap { WaylandResource.owner(of: $0, as: WlDataSource.self) }
        manager?.setSelection(source)
    }
}
