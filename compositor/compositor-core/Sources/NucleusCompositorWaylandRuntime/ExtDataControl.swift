// ext_data_control_v1 on the router — the privileged clipboard-manager protocol.
//
// Unlike wl_data_device (focus-gated: a client sees the selection only while
// focused), a data-control client sees and can set the clipboard selection at all
// times — that is what lets the shell keep clipboard history and restore entries.
// Both protocols project the SAME selection: the router's WlDataDeviceManager owns
// the current selection as a shared `SelectionSource`, so a wl_data_source set by an
// app and an ext_data_control_source set by the shell are interchangeable — each
// protocol offers whichever is current, and a paste relays back to the owning source
// regardless of which protocol created it.
//
// Clipboard only: Nucleus has no primary-selection protocol, so set_primary_selection
// is ignored and primary_selection events are never sent (both permitted for a
// compositor without primary support). Ported from the legacy
// NucleusWaylandRouter/ExtDataControl.swift onto the router's selection model.

import Glibc
import WaylandServerC
import WaylandServer
import WaylandServerDispatch

private final class WeakExtDataControlDevice {
    weak var device: ExtDataControlDevice?
    init(_ device: ExtDataControlDevice) { self.device = device }
}

final class ExtDataControlManager: SelectionObserver {
    /// The shared clipboard owner both protocols project + set.
    private unowned let dataDevice: WlDataDeviceManager

    private var devices: [WeakExtDataControlDevice] = []

    init(dataDevice: WlDataDeviceManager) {
        self.dataDevice = dataDevice
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_ext_data_control_manager_v1(), version: 1, impl: self, bind: Self.bind)
        // Observe the shared clipboard so every data-control device stays current.
        dataDevice.addSelectionObserver(self)
    }

    fileprivate func setClipboard(_ source: (any SelectionSource)?) { dataDevice.setSelection(source) }
    fileprivate var currentClipboard: (any SelectionSource)? { dataDevice.currentSelection }

    fileprivate func addDevice(_ device: ExtDataControlDevice) {
        devices.append(WeakExtDataControlDevice(device))
        device.projectSelection(currentClipboard)
    }

    // MARK: SelectionObserver

    func clipboardSelectionChanged(_ source: (any SelectionSource)?) {
        devices.removeAll { $0.device == nil }
        for box in devices { box.device?.projectSelection(source) }
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client, let me = NucleusWaylandRouter.impl(data, as: ExtDataControlManager.self)
        else { return }
        _ = WaylandResource.create(
            client: client, interface: swift_wayland_iface_ext_data_control_manager_v1(),
            version: Int32(version), id: id, vtable: ExtDataControlManagerV1Server.vtable, owner: me)
    }
}

extension ExtDataControlManager: ExtDataControlManagerV1Requests {
    // create_data_source(id)
    func createDataSource(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId) {
        let source = ExtDataControlSource()
        guard let sres = id.create(vtable: ExtDataControlSourceV1Server.vtable, owner: source) else { return }
        source.bind(sres)
    }

    // get_data_device(id, seat)
    func getDataDevice(_ resource: UnsafeMutablePointer<wl_resource>, id: WlNewId,
                       seat: UnsafeMutablePointer<wl_resource>?) {
        let device = ExtDataControlDevice(manager: self)
        guard let dres = id.create(vtable: ExtDataControlDeviceV1Server.vtable, owner: device) else { return }
        device.bind(dres)
        addDevice(device)
    }
}

/// ext_data_control_source_v1 owner (Rule 9): a shell-offered clipboard source.
final class ExtDataControlSource: SelectionSource, ExtDataControlSourceV1Requests {
    private(set) var mimes: [String] = []
    private var resource: UnsafeMutablePointer<wl_resource>?

    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    // MARK: SelectionSource

    var selectionMimeTypes: [String] { mimes }

    func sendSelection(mime: String, fd: Int32) {
        guard let resource else { if fd >= 0 { close(fd) }; return }
        mime.withCString { ext_data_control_source_v1_send_send(resource, $0, fd) }
        if fd >= 0 { close(fd) }
    }

    func selectionCancelled() {
        guard let resource else { return }
        ext_data_control_source_v1_send_cancelled(resource)
    }

    // offer(mime_type)
    func offer(_ resource: UnsafeMutablePointer<wl_resource>, mime_type: UnsafePointer<CChar>?) {
        guard let mime_type else { return }
        mimes.append(String(cString: mime_type))
    }
}

/// ext_data_control_device_v1 owner (Rule 9): a client's always-on clipboard view.
final class ExtDataControlDevice {
    private weak var manager: ExtDataControlManager?
    private var resource: UnsafeMutablePointer<wl_resource>?

    init(manager: ExtDataControlManager) { self.manager = manager }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    /// Emit data_offer + offer(mime)* + selection(offer) for the current selection,
    /// or selection(null) to clear.
    fileprivate func projectSelection(_ source: (any SelectionSource)?) {
        guard let deviceRes = resource, let client = wl_resource_get_client(deviceRes)
        else { return }
        guard let source else {
            ext_data_control_device_v1_send_selection(deviceRes, nil)
            return
        }
        guard let offerRes = WaylandResource.create(
            client: client, interface: swift_wayland_iface_ext_data_control_offer_v1(),
            version: Int32(wl_resource_get_version(deviceRes)), id: 0,
            vtable: ExtDataControlOfferV1Server.vtable, owner: ExtDataControlOffer(source: source))
        else { return }
        ext_data_control_device_v1_send_data_offer(deviceRes, offerRes)
        for mime in source.selectionMimeTypes {
            mime.withCString { ext_data_control_offer_v1_send_offer(offerRes, $0) }
        }
        ext_data_control_device_v1_send_selection(deviceRes, offerRes)
    }

}

extension ExtDataControlDevice: ExtDataControlDeviceV1Requests {
    // set_selection(source): the shell sets the clipboard. A data-control source
    // becomes the shared selection; wl_data_device clients then offer it too.
    func setSelection(_ resource: UnsafeMutablePointer<wl_resource>,
                      source sourceRes: UnsafeMutablePointer<wl_resource>?) {
        let source = sourceRes.flatMap { WaylandResource.owner(of: $0, as: ExtDataControlSource.self) }
        manager?.setClipboard(source)
    }

    // set_primary_selection(source): primary selection unsupported; ignored.
    func setPrimarySelection(_ resource: UnsafeMutablePointer<wl_resource>,
                             source: UnsafeMutablePointer<wl_resource>?) {}
}

/// ext_data_control_offer_v1 owner (Rule 9): pipes a receive fd to the selection
/// source (a wl_data_source or another data-control source).
final class ExtDataControlOffer {
    private weak var source: (any SelectionSource)?
    init(source: (any SelectionSource)?) { self.source = source }
}

extension ExtDataControlOffer: ExtDataControlOfferV1Requests {
    // receive(mime, fd): relay to the owning source's send event (the data transfer).
    func receive(_ resource: UnsafeMutablePointer<wl_resource>, mime_type: UnsafePointer<CChar>?, fd: Int32) {
        guard let mime_type else { if fd >= 0 { close(fd) }; return }
        guard let source else { if fd >= 0 { close(fd) }; return }
        source.sendSelection(mime: String(cString: mime_type), fd: fd)
    }
}
