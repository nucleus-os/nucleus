package struct DataSourceHandle: RawRepresentable, Hashable, Sendable {
    package var rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct DataOfferHandle: RawRepresentable, Hashable, Sendable {
    package var rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct DataSeatHandle: RawRepresentable, Hashable, Sendable {
    package var rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package struct DataClientHandle: RawRepresentable, Hashable, Sendable {
    package var rawValue: UInt64

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

package enum SelectionKind: UInt32, CaseIterable, Sendable {
    case clipboard = 1
    case primary = 2
    case dataControl = 3
}

package enum SelectionOwnerKind: UInt32, Sendable {
    case wayland = 1
    case xwayland = 2
    case portal = 3
}

package struct MimeTypeSet: Equatable, Sendable {
    private var ordered: [String] = []
    private var members: Set<String> = []

    package init() {}

    package var values: [String] {
        ordered
    }

    package mutating func insert(_ mimeType: String) {
        guard !mimeType.isEmpty, members.insert(mimeType).inserted else { return }
        ordered.append(mimeType)
    }

    package func contains(_ mimeType: String) -> Bool {
        members.contains(mimeType)
    }
}

package struct SelectionOwner: Equatable, Sendable {
    package var handle: DataSourceHandle
    package var kind: SelectionOwnerKind
    package var client: DataClientHandle
    package var mimeTypes: MimeTypeSet
    package var sensitiveContent: Bool
    package var privateSource: Bool
    package var portalOrigin: UInt64

    package init(
        handle: DataSourceHandle,
        kind: SelectionOwnerKind,
        client: DataClientHandle,
        mimeTypes: MimeTypeSet = MimeTypeSet(),
        sensitiveContent: Bool = false,
        privateSource: Bool = false,
        portalOrigin: UInt64 = 0
    ) {
        self.handle = handle
        self.kind = kind
        self.client = client
        self.mimeTypes = mimeTypes
        self.sensitiveContent = sensitiveContent
        self.privateSource = privateSource
        self.portalOrigin = portalOrigin
    }
}

package struct SelectionDestination: Equatable, Sendable {
    package var handle: DataClientHandle

    package init(handle: DataClientHandle) {
        self.handle = handle
    }
}

package struct SelectionOffer: Equatable, Sendable {
    package var handle: DataOfferHandle
    package var kind: SelectionKind
    package var source: DataSourceHandle
    package var destination: SelectionDestination
    package var acceptedMimeType: String?

    package init(
        handle: DataOfferHandle,
        kind: SelectionKind,
        source: DataSourceHandle,
        destination: SelectionDestination,
        acceptedMimeType: String? = nil
    ) {
        self.handle = handle
        self.kind = kind
        self.source = source
        self.destination = destination
        self.acceptedMimeType = acceptedMimeType
    }
}

package struct DragSession: Equatable, Sendable {
    package enum State: UInt32, Sendable {
        case active = 1
        case cancelled = 2
        case dropped = 3
    }

    package var source: DataSourceHandle
    package var origin: UInt64
    package var icon: UInt64
    package var target: DataClientHandle
    package var serial: UInt32
    package var offeredMimeTypes: MimeTypeSet
    package var acceptedMimeType: String?
    package var state: State

    package init(
        source: DataSourceHandle,
        origin: UInt64,
        icon: UInt64,
        target: DataClientHandle,
        serial: UInt32,
        offeredMimeTypes: MimeTypeSet,
        acceptedMimeType: String? = nil,
        state: State = .active
    ) {
        self.source = source
        self.origin = origin
        self.icon = icon
        self.target = target
        self.serial = serial
        self.offeredMimeTypes = offeredMimeTypes
        self.acceptedMimeType = acceptedMimeType
        self.state = state
    }
}

package struct DataSelectionPlan: Equatable, Sendable {
    package var kind: SelectionKind
    package var seat: DataSeatHandle
    package var source: DataSourceHandle?
    package var destination: DataClientHandle?
    package var cancelSource: DataSourceHandle?
    package var sendOffer: Bool
    package var clearSelection: Bool

    package static func none(kind: SelectionKind, seat: DataSeatHandle) -> DataSelectionPlan {
        DataSelectionPlan(
            kind: kind,
            seat: seat,
            source: nil,
            destination: nil,
            cancelSource: nil,
            sendOffer: false,
            clearSelection: false
        )
    }
}

package struct DataTransferPlan: Equatable, Sendable {
    package var allowed: Bool
    package var source: DataSourceHandle?
}

package struct DataDragResult: Equatable, Sendable {
    package var allowed: Bool
    package var action: UInt32
}

/// Notified whenever a seat's selection of a given kind changes (set, replaced,
/// or cleared), regardless of which client/protocol caused it. The privileged
/// `ext_data_control` projection observes this to keep its always-on clipboard
/// view current; the focus-gated `wl_data_device` path does not need it (it pushes
/// on its own set + on focus-enter).
@MainActor
package protocol DataSelectionObserver: AnyObject {
    func selectionDidChange(kind: SelectionKind, seat: DataSeatHandle)
}

@MainActor
package final class DataExchangeService {
    package struct Snapshot: Equatable, Sendable {
        package var sourceCount: Int
        package var offerCount: Int
        package var clipboardOwner: DataSourceHandle?
        package var primaryOwner: DataSourceHandle?
        package var dataControlOwner: DataSourceHandle?
        package var activeDrag: DragSession?
        package var historyCount: Int
    }

    private struct SelectionKey: Hashable {
        var kind: SelectionKind
        var seat: DataSeatHandle
    }

    private var sources: [DataSourceHandle: SelectionOwner] = [:]
    private var offers: [DataOfferHandle: SelectionOffer] = [:]
    private var selections: [SelectionKey: DataSourceHandle] = [:]
    private var focusedDestinations: [DataSeatHandle: SelectionDestination] = [:]
    private var clipboardHistory: [DataSourceHandle] = []
    private var activeDrag: DragSession?

    // Shared across every selection-protocol router (wl_data_device,
    // ext_data_control): one monotonic handle space so source/offer handles never
    // collide in the maps above, one source-event registry so a transfer or
    // cancel reaches the owning client's source wire object regardless of which
    // router created it, and one selection-change broadcast.
    private var nextHandle: UInt64 = 1
    private struct SourceEvents {
        let onSend: (String, Int32) -> Void
        let onCancel: () -> Void
    }
    private var sourceEvents: [DataSourceHandle: SourceEvents] = [:]
    private struct WeakSelectionObserver { weak var value: (any DataSelectionObserver)? }
    private var selectionObservers: [WeakSelectionObserver] = []

    package init() {}

    package func reset() {
        sources.removeAll(keepingCapacity: true)
        offers.removeAll(keepingCapacity: true)
        selections.removeAll(keepingCapacity: true)
        focusedDestinations.removeAll(keepingCapacity: true)
        clipboardHistory.removeAll(keepingCapacity: true)
        activeDrag = nil
        sourceEvents.removeAll(keepingCapacity: true)
        nextHandle = 1
        // Observers are router singletons; they persist across a server reset.
    }

    /// Allocate a process-unique handle for a source or offer, shared by every
    /// selection-protocol router so their handles index the same maps without
    /// collision.
    package func allocateHandle() -> UInt64 {
        let h = nextHandle
        nextHandle &+= 1
        if nextHandle == 0 { nextHandle = 1 }
        return h
    }

    /// Register how to drive a source's wire object: `onSend` forwards a receiver's
    /// pipe fd (the registrant dups before writing the `send` event), `onCancel`
    /// tells the source it was superseded. Lets a transfer or cancel cross from the
    /// router that owns the *offer* to the router that owns the *source*.
    package func registerSourceEvents(
        _ handle: DataSourceHandle, onSend: @escaping (_ mimeType: String, _ fd: Int32) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard handle.rawValue != 0 else { return }
        sourceEvents[handle] = SourceEvents(onSend: onSend, onCancel: onCancel)
    }

    package func emitSourceSend(_ handle: DataSourceHandle, mimeType: String, fd: Int32) {
        sourceEvents[handle]?.onSend(mimeType, fd)
    }

    package func emitSourceCancelled(_ handle: DataSourceHandle) {
        sourceEvents[handle]?.onCancel()
    }

    package func addSelectionObserver(_ observer: any DataSelectionObserver) {
        selectionObservers.removeAll { $0.value == nil || $0.value === observer }
        selectionObservers.append(WeakSelectionObserver(value: observer))
    }

    package func removeSelectionObserver(_ observer: any DataSelectionObserver) {
        selectionObservers.removeAll { $0.value == nil || $0.value === observer }
    }

    private func notifySelectionObservers(kind: SelectionKind, seat: DataSeatHandle) {
        selectionObservers.removeAll { $0.value == nil }
        for observer in selectionObservers {
            observer.value?.selectionDidChange(kind: kind, seat: seat)
        }
    }

    package func sourceCreated(
        _ handle: DataSourceHandle, ownerKind: SelectionOwnerKind, client: DataClientHandle
    ) {
        guard handle.rawValue != 0 else { return }
        sources[handle] = SelectionOwner(handle: handle, kind: ownerKind, client: client)
    }

    package func xwaylandSourceCreated(
        _ handle: DataSourceHandle, atom: UInt32, client: DataClientHandle
    ) {
        sourceCreated(handle, ownerKind: .xwayland, client: client)
        if atom != 0 {
            addMimeType("application/x-nucleus-xselection-\(atom)", to: handle)
        }
    }

    package func updateSourceMetadata(
        _ handle: DataSourceHandle, sensitiveContent: Bool, privateSource: Bool,
        portalOrigin: UInt64
    ) {
        guard var source = sources[handle] else { return }
        source.sensitiveContent = sensitiveContent
        source.privateSource = privateSource
        source.portalOrigin = portalOrigin
        sources[handle] = source
    }

    package func addMimeType(_ mimeType: String, to handle: DataSourceHandle) {
        guard var source = sources[handle] else { return }
        source.mimeTypes.insert(mimeType)
        sources[handle] = source
    }

    /// The MIME types a source advertises, in offer order. Used by a projection
    /// (ext_data_control) that does not own the source's wire object to enumerate
    /// its offers when re-advertising the selection.
    package func mimeTypes(for handle: DataSourceHandle) -> [String] {
        sources[handle]?.mimeTypes.values ?? []
    }

    @discardableResult
    package func sourceDestroyed(_ handle: DataSourceHandle) -> [DataSelectionPlan] {
        sources.removeValue(forKey: handle)
        sourceEvents.removeValue(forKey: handle)
        offers = offers.filter { $0.value.source != handle }
        if activeDrag?.source == handle {
            activeDrag?.state = .cancelled
        }

        var plans: [DataSelectionPlan] = []
        var cleared: [SelectionKey] = []
        for (key, selected) in selections where selected == handle {
            selections.removeValue(forKey: key)
            cleared.append(key)
            plans.append(
                DataSelectionPlan(
                    kind: key.kind,
                    seat: key.seat,
                    source: nil,
                    destination: focusedDestinations[key.seat]?.handle,
                    cancelSource: nil,
                    sendOffer: false,
                    clearSelection: true
                ))
        }
        // Broadcast after the model settles so always-on observers re-read cleared state.
        for key in cleared { notifySelectionObservers(kind: key.kind, seat: key.seat) }
        return plans
    }

    @discardableResult
    package func setSelection(
        kind: SelectionKind, seat: DataSeatHandle, source: DataSourceHandle?, serial: UInt32
    ) -> DataSelectionPlan {
        _ = serial
        let key = SelectionKey(kind: kind, seat: seat)
        let previous = selections[key]
        if let source {
            guard sources[source] != nil else {
                selections.removeValue(forKey: key)
                notifySelectionObservers(kind: kind, seat: seat)
                return DataSelectionPlan(
                    kind: kind,
                    seat: seat,
                    source: nil,
                    destination: focusedDestinations[seat]?.handle,
                    cancelSource: previous,
                    sendOffer: false,
                    clearSelection: true
                )
            }
            selections[key] = source
            recordHistoryIfNeeded(kind: kind, source: source)
        } else {
            selections.removeValue(forKey: key)
        }

        let destination = focusedDestinations[seat]?.handle
        // Broadcast after the model settles so always-on observers (ext_data_control)
        // re-read the new owner. The returned plan still drives the focus-gated
        // wl_data_device client.
        notifySelectionObservers(kind: kind, seat: seat)
        return DataSelectionPlan(
            kind: kind,
            seat: seat,
            source: source,
            destination: destination,
            cancelSource: previous != source ? previous : nil,
            sendOffer: source != nil && destination != nil,
            clearSelection: source == nil
        )
    }

    package func focusDestinationChanged(seat: DataSeatHandle, destination: DataClientHandle?) {
        if let destination, destination.rawValue != 0 {
            focusedDestinations[seat] = SelectionDestination(handle: destination)
        } else {
            focusedDestinations.removeValue(forKey: seat)
        }
    }

    package func currentSelectionOffer(
        kind: SelectionKind, seat: DataSeatHandle, destination: DataClientHandle
    ) -> DataSelectionPlan {
        let key = SelectionKey(kind: kind, seat: seat)
        guard let source = selections[key], sources[source] != nil else {
            return DataSelectionPlan(
                kind: kind,
                seat: seat,
                source: nil,
                destination: destination,
                cancelSource: nil,
                sendOffer: false,
                clearSelection: true
            )
        }
        return DataSelectionPlan(
            kind: kind,
            seat: seat,
            source: source,
            destination: destination,
            cancelSource: nil,
            sendOffer: true,
            clearSelection: false
        )
    }

    package func offerCreated(
        _ handle: DataOfferHandle, kind: SelectionKind, source: DataSourceHandle,
        destination: DataClientHandle
    ) {
        guard handle.rawValue != 0, sources[source] != nil else { return }
        offers[handle] = SelectionOffer(
            handle: handle,
            kind: kind,
            source: source,
            destination: SelectionDestination(handle: destination)
        )
    }

    package func offerDestroyed(_ handle: DataOfferHandle) {
        offers.removeValue(forKey: handle)
    }

    package func acceptOffer(_ handle: DataOfferHandle, mimeType: String?) {
        guard var offer = offers[handle] else { return }
        guard let mimeType, sources[offer.source]?.mimeTypes.contains(mimeType) == true else {
            offer.acceptedMimeType = nil
            offers[handle] = offer
            return
        }
        offer.acceptedMimeType = mimeType
        offers[handle] = offer
    }

    package func requestTransfer(_ handle: DataOfferHandle, mimeType: String) -> DataTransferPlan {
        guard let offer = offers[handle], let source = sources[offer.source] else {
            return DataTransferPlan(allowed: false, source: nil)
        }
        guard source.mimeTypes.contains(mimeType) else {
            return DataTransferPlan(allowed: false, source: nil)
        }
        if let accepted = offer.acceptedMimeType, accepted != mimeType {
            return DataTransferPlan(allowed: false, source: nil)
        }
        if source.privateSource || source.sensitiveContent {
            return DataTransferPlan(
                allowed: source.portalOrigin == 0,
                source: source.portalOrigin == 0 ? source.handle : nil)
        }
        return DataTransferPlan(allowed: true, source: source.handle)
    }

    package func startDrag(
        source: DataSourceHandle, origin: UInt64, icon: UInt64, target: DataClientHandle,
        serial: UInt32
    ) -> DataDragResult {
        guard let owner = sources[source] else {
            activeDrag = nil
            return DataDragResult(allowed: false, action: 0)
        }
        activeDrag = DragSession(
            source: source,
            origin: origin,
            icon: icon,
            target: target,
            serial: serial,
            offeredMimeTypes: owner.mimeTypes
        )
        return DataDragResult(allowed: true, action: 1)
    }

    package func cancelDrag(source: DataSourceHandle) {
        guard activeDrag?.source == source else { return }
        activeDrag?.state = .cancelled
    }

    package func dropDrag(source: DataSourceHandle, acceptedMimeType: String?) -> DataDragResult {
        guard var drag = activeDrag, drag.source == source else {
            return DataDragResult(allowed: false, action: 0)
        }
        if let acceptedMimeType {
            guard drag.offeredMimeTypes.contains(acceptedMimeType) else {
                return DataDragResult(allowed: false, action: 0)
            }
            drag.acceptedMimeType = acceptedMimeType
        }
        drag.state = .dropped
        activeDrag = drag
        return DataDragResult(allowed: true, action: 1)
    }

    package func snapshot(seat: DataSeatHandle = DataSeatHandle(rawValue: 1)) -> Snapshot {
        Snapshot(
            sourceCount: sources.count,
            offerCount: offers.count,
            clipboardOwner: selections[SelectionKey(kind: .clipboard, seat: seat)],
            primaryOwner: selections[SelectionKey(kind: .primary, seat: seat)],
            dataControlOwner: selections[SelectionKey(kind: .dataControl, seat: seat)],
            activeDrag: activeDrag,
            historyCount: clipboardHistory.count
        )
    }

    private func recordHistoryIfNeeded(kind: SelectionKind, source: DataSourceHandle) {
        guard kind == .clipboard else { return }
        guard let owner = sources[source], !owner.privateSource, !owner.sensitiveContent else {
            return
        }
        clipboardHistory.removeAll { $0 == source }
        clipboardHistory.append(source)
    }
}
