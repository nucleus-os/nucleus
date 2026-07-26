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
import WaylandProtocolTypes

@MainActor
@safe final class ExtDataControlManager: SelectionObserver {
    /// The shared clipboard owner both protocols project + set.
    private unowned let dataDevice: WlDataDeviceManager

    private var devices = WeakObjectList<ExtDataControlDevice>()

    init(dataDevice: WlDataDeviceManager) {
        self.dataDevice = dataDevice
    }

    fileprivate func setClipboard(_ source: (any SelectionSource)?) { dataDevice.setSelection(source) }
    fileprivate var currentClipboard: (any SelectionSource)? { dataDevice.currentSelection }
    fileprivate func sourceDestroyed(_ source: ExtDataControlSource) {
        dataDevice.selectionSourceDestroyed(source)
    }

    fileprivate func addDevice(_ device: ExtDataControlDevice) {
        devices.append(device)
        device.projectSelection(currentClipboard)
    }

    // MARK: SelectionObserver

    func clipboardSelectionChanged(_ source: (any SelectionSource)?) {
        for device in devices.liveValues() {
            device.projectSelection(source)
        }
    }

}

extension ExtDataControlManager: ExtDataControlManagerV1Requests {
    // create_data_source(id)
    func createDataSource(
        _ request: WaylandRequest<ExtDataControlManagerV1Server>,
        id: WlNewId<ExtDataControlSourceV1Server>
    ) {
        _ = id.create { handle in
            ExtDataControlSource(resource: handle, manager: self)
        }
    }

    // get_data_device(id, seat)
    func getDataDevice(
        _ request: WaylandRequest<ExtDataControlManagerV1Server>,
        id: WlNewId<ExtDataControlDeviceV1Server>,
                       seat: WaylandBorrowedObject<WlSeatServer>) {
        _ = id.create(
            owner: { handle in
                ExtDataControlDevice(resource: handle, manager: self)
            },
            installed: { device in
                self.addDevice(device)
            })
    }
}

/// ext_data_control_source_v1 owner (Rule 9): a shell-offered clipboard source.
@MainActor
@safe final class ExtDataControlSource: SelectionSource, ExtDataControlSourceV1Requests {
    private weak var manager: ExtDataControlManager?
    private(set) var mimes: [String] = []
    private let resource:
        WaylandResourceHandle<ExtDataControlSourceV1Server>
    private var wasUsed = false

    init(
        resource: WaylandResourceHandle<ExtDataControlSourceV1Server>,
        manager: ExtDataControlManager
    ) {
        self.resource = resource
        self.manager = manager
    }
    fileprivate func claimForSelection() -> Bool {
        guard !wasUsed else { return false }
        wasUsed = true
        return true
    }

    isolated deinit {
        manager?.sourceDestroyed(self)
    }

    // MARK: SelectionSource

    var selectionMimeTypes: [String] { mimes }

    func sendSelection(mime: String, fd: Int32) {
        guard resource.isLive else {
            if fd >= 0 { close(fd) }
            return
        }
        resource.sendSend(mime_type: mime, fd: fd)
        if fd >= 0 { close(fd) }
    }

    func selectionCancelled() {
        resource.sendCancelled()
    }

    // offer(mime_type)
    func offer(
        _ request: WaylandRequest<ExtDataControlSourceV1Server>,
        mime_type: String
    ) {
        mimes.append(mime_type)
    }
}

/// ext_data_control_device_v1 owner (Rule 9): a client's always-on clipboard view.
@MainActor
@safe final class ExtDataControlDevice {
    private weak var manager: ExtDataControlManager?
    private let resource:
        WaylandResourceHandle<ExtDataControlDeviceV1Server>

    init(
        resource: WaylandResourceHandle<ExtDataControlDeviceV1Server>,
        manager: ExtDataControlManager
    ) {
        self.resource = resource
        self.manager = manager
    }

    /// Emit data_offer + offer(mime)* + selection(offer) for the current selection,
    /// or selection(null) to clear.
    fileprivate func projectSelection(_ source: (any SelectionSource)?) {
        guard resource.isLive else { return }
        guard let source else {
            resource.sendSelection(id: nil)
            return
        }
        _ = resource.createDataOffer(
            owner: { handle in
                ExtDataControlOffer(resource: handle, source: source)
            },
            installed: { offer in
                for mime in source.selectionMimeTypes {
                    offer.resource.sendOffer(mime_type: mime)
                }
                resource.sendSelection(id: offer.resource)
            })
    }

}

extension ExtDataControlDevice: ExtDataControlDeviceV1Requests {
    // set_selection(source): the shell sets the clipboard. A data-control source
    // becomes the shared selection; wl_data_device clients then offer it too.
    func setSelection(_ request: WaylandRequest<ExtDataControlDeviceV1Server>,
                      source sourceRes: WaylandBorrowedObject<ExtDataControlSourceV1Server>?) {
        let source = sourceRes?.owner(as: ExtDataControlSource.self)
        if let source, !source.claimForSelection() {
            request.postError(.usedSource, message: "data-control source was already used")
            return
        }
        manager?.setClipboard(source)
    }

    // set_primary_selection(source): primary selection unsupported; ignored.
    func setPrimarySelection(_ request: WaylandRequest<ExtDataControlDeviceV1Server>,
                             source: WaylandBorrowedObject<ExtDataControlSourceV1Server>?) {}
}

/// ext_data_control_offer_v1 owner (Rule 9): pipes a receive fd to the selection
/// source (a wl_data_source or another data-control source).
@MainActor
final class ExtDataControlOffer {
    private weak var source: (any SelectionSource)?
    fileprivate let resource:
        WaylandResourceHandle<ExtDataControlOfferV1Server>

    init(
        resource: WaylandResourceHandle<ExtDataControlOfferV1Server>,
        source: (any SelectionSource)?
    ) {
        self.resource = resource
        self.source = source
    }
}

extension ExtDataControlOffer: ExtDataControlOfferV1Requests {
    // receive(mime, fd): relay to the owning source's send event (the data transfer).
    func receive(_ request: WaylandRequest<ExtDataControlOfferV1Server>, mime_type: String, fd: consuming WaylandOwnedFileDescriptor) {
        guard let source else { return }
        source.sendSelection(mime: mime_type, fd: fd.take())
    }
}
