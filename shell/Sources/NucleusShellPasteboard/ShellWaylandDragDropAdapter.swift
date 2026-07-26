import FoundationEssentials
import Glibc
public import NucleusShellLoop
public import NucleusShellWayland
public import NucleusUI
public import WaylandClientDispatch
import WaylandProtocolTypes

/// The `wl_data_device` projection of NucleusUI's retained drag lifecycle.
///
/// Clipboard state intentionally lives in `ShellWaylandPasteboardAdapter`.
/// Sharing this target gives both transports the same descriptor executor
/// without sharing offers, sources, cancellation, or selection state.
@MainActor
@safe public final class ShellWaylandDragDropAdapter {
    public typealias DestinationResolver =
        @MainActor (_ surfaceID: UInt, _ surfaceLocation: Point)
            -> (scene: WindowScene, sceneLocation: Point)?
    public typealias DiagnosticHandler =
        @MainActor @Sendable (_ operation: String, _ message: String) -> Void

    @MainActor
    @safe private final class Offer: WlDataOfferEvents {
        let proxy: WaylandProxy<WlDataOfferClient>
        weak var adapter: ShellWaylandDragDropAdapter?
        var mimeTypes: Set<String> = []
        var sourceActions: Set<DragOperation> = []
        var selectedAction: DragOperation?
        var enterSerial: UInt32 = 0
        var surfaceID: UInt = 0
        var isDestroyed = false

        init(
            proxy: WaylandProxy<WlDataOfferClient>,
            adapter: ShellWaylandDragDropAdapter
        ) throws {
            self.proxy = proxy
            self.adapter = adapter
            try proxy.installListener(self)
        }

        func offer(
            _ proxy: WaylandBorrowedProxy<WlDataOfferClient>,
            mime_type: String
        ) {
            mimeTypes.insert(mime_type)
        }

        func sourceActions(
            _ proxy: WaylandBorrowedProxy<WlDataOfferClient>,
            source_actions: WlDataDeviceManagerDndAction
        ) {
            sourceActions =
                ShellWaylandDragDropAdapter.operations(
                    from: source_actions.rawValue)
        }

        func action(
            _ proxy: WaylandBorrowedProxy<WlDataOfferClient>,
            dnd_action: WlDataDeviceManagerDndAction
        ) {
            selectedAction =
                ShellWaylandDragDropAdapter.operation(
                    from: dnd_action.rawValue)
        }
    }

    @MainActor
    @safe private final class Source: WlDataSourceEvents {
        let proxy: WaylandProxy<WlDataSourceClient>
        let sessionID: DragSessionID
        weak var scene: WindowScene?
        let configuration: DragSourceConfiguration
        weak var adapter: ShellWaylandDragDropAdapter?
        var selectedAction: DragOperation?
        var didPerformDrop = false
        var providerTasks: [UInt64: Task<Void, Never>] = [:]
        var pendingDescriptors:
            [UInt64: StoredTransferFileDescriptor] = [:]
        var transferTokens: Set<UInt64> = []
        var isDestroyed = false

        init(
            proxy: WaylandProxy<WlDataSourceClient>,
            sessionID: DragSessionID,
            scene: WindowScene,
            configuration: DragSourceConfiguration,
            adapter: ShellWaylandDragDropAdapter
        ) throws {
            self.proxy = proxy
            self.sessionID = sessionID
            self.scene = scene
            self.configuration = configuration
            self.adapter = adapter
            try proxy.installListener(self)
        }

        func target(
            _ proxy: WaylandBorrowedProxy<WlDataSourceClient>,
            mime_type: String?
        ) {}

        func send(
            _ proxy: WaylandBorrowedProxy<WlDataSourceClient>,
            mime_type: String,
            fd: consuming WaylandClientOwnedFileDescriptor
        ) {
            let descriptor = fd.take()
            adapter?.source(
                self, send: mime_type, owning: descriptor)
        }

        func cancelled(
            _ proxy: WaylandBorrowedProxy<WlDataSourceClient>
        ) {
            adapter?.finishSource(self, outcome: .cancelled)
        }

        func dndDropPerformed(
            _ proxy: WaylandBorrowedProxy<WlDataSourceClient>
        ) {
            didPerformDrop = true
        }

        func dndFinished(
            _ proxy: WaylandBorrowedProxy<WlDataSourceClient>
        ) {
            guard let adapter else { return }
            let outcome: DragCompletionOutcome
            if didPerformDrop, let selectedAction {
                outcome = .performed(selectedAction)
            } else if didPerformDrop {
                outcome = .failed
            } else {
                outcome = .rejected
            }
            adapter.finishSource(self, outcome: outcome)
        }

        func action(
            _ proxy: WaylandBorrowedProxy<WlDataSourceClient>,
            dnd_action: WlDataDeviceManagerDndAction
        ) {
            selectedAction =
                ShellWaylandDragDropAdapter.operation(
                    from: dnd_action.rawValue)
        }
    }

    private final class IncomingSession {
        let offer: Offer
        weak var scene: WindowScene?
        let sessionID: DragSessionID
        var lastSceneLocation: Point
        var isDropping = false

        init(
            offer: Offer,
            scene: WindowScene,
            sessionID: DragSessionID,
            lastSceneLocation: Point
        ) {
            self.offer = offer
            self.scene = scene
            self.sessionID = sessionID
            self.lastSceneLocation = lastSceneLocation
        }
    }

    private let client: ShellWaylandClient
    private let seat: ShellSeat
    private let manager: WaylandProxy<WlDataDeviceManagerClient>
    private var device: WaylandProxy<WlDataDeviceClient>?
    private let limits: ShellDataTransferLimits
    private let destinationResolver: DestinationResolver
    private let diagnosticHandler: DiagnosticHandler
    private let pollSetDidChange: @MainActor () -> Void
    private lazy var transferExecutor = DataTransferExecutor(
        pollSetDidChange: pollSetDidChange
    ) {
        [weak self] operation, failure in
        self?.diagnosticHandler(operation, String(describing: failure))
    }

    private var offers: [UInt: Offer] = [:]
    private var incoming: IncomingSession?
    private var sources: [UInt: Source] = [:]
    private var nextRequestID: UInt64 = 1
    private var readTokens: [UInt64: (offerKey: UInt, token: UInt64)] = [:]
    private var isShutdown = false

    public init?(
        client: ShellWaylandClient,
        seat: ShellSeat,
        limits: ShellDataTransferLimits = ShellDataTransferLimits(),
        destinationResolver: @escaping DestinationResolver,
        pollSetDidChange: @escaping @MainActor () -> Void = {},
        diagnosticHandler: @escaping DiagnosticHandler = { _, _ in }
    ) {
        guard let manager = client.dataDeviceManager,
              let device = try? manager.getDataDevice(seat: seat.protocolSeat)
        else {
            return nil
        }
        self.client = client
        self.seat = seat
        self.manager = manager
        self.device = device
        self.limits = limits
        self.destinationResolver = destinationResolver
        self.pollSetDidChange = pollSetDidChange
        self.diagnosticHandler = diagnosticHandler
        do {
            try device.installListener(self)
        } catch {
            try? device.release()
            return nil
        }
    }

    public var pollDescriptors: [ShellDataTransferPollDescriptor] {
        transferExecutor.pollDescriptors
    }

    public var activeTransferCount: Int {
        transferExecutor.activeTransferCount
    }

    public func nanosecondsUntilTransferDeadline(
        nowNanoseconds: UInt64
    ) -> UInt64? {
        transferExecutor.nanosecondsUntilDeadline(
            nowNanoseconds: nowNanoseconds)
    }

    public func processPollResult(
        token: UInt64,
        result: ShellPollResult,
        nowNanoseconds: UInt64
    ) {
        transferExecutor.processPollResult(
            token: token,
            result: result,
            nowNanoseconds: nowNanoseconds)
    }

    public func expireTransfers(nowNanoseconds: UInt64) {
        transferExecutor.expireTransfers(nowNanoseconds: nowNanoseconds)
    }

    /// Starts an outbound Wayland drag using the current pointer-down serial.
    /// The serial is consumed on success or failure and cannot be replayed.
    @discardableResult
    public func startDrag(
        from sourceView: View,
        source: DragSourceConfiguration,
        originSurface: WaylandProxy<WlSurfaceClient>,
        at sceneLocation: Point
    ) -> DragSessionID? {
        guard !isShutdown,
              let device,
              let authorization = seat.takeDragAuthorization(
                for: originSurface),
              let scene = sourceView.window?.windowScene,
              let sessionID = scene.beginProjectedDrag(
                  from: sourceView,
                  source: source,
                  at: sceneLocation)
        else {
            return nil
        }
        let proxy: WaylandProxy<WlDataSourceClient>
        do {
            proxy = try manager.createDataSource()
        } catch {
            scene.completeDrag(
                sessionID: sessionID,
                outcome: .failed)
            return nil
        }

        let projected: Source
        do {
            projected = try Source(
                proxy: proxy,
                sessionID: sessionID,
                scene: scene,
                configuration: source,
                adapter: self)
        } catch {
            try? proxy.destroy()
            scene.completeDrag(sessionID: sessionID, outcome: .failed)
            return nil
        }
        sources[proxy.identity] = projected
        for mime in source.offer.contentTypes {
            guard (try? proxy.offer(mime_type: mime)) != nil else {
                finishSource(projected, outcome: .failed)
                return nil
            }
        }
        do {
            try proxy.setActions(
                dnd_actions: Self.protocolActions(
                    source.offer.allowedOperations))
            try device.startDrag(
                source: proxy,
                origin: originSurface,
                icon: nil,
                serial: authorization.serial)
        } catch {
            finishSource(projected, outcome: .failed)
            return nil
        }
        guard flush(operation: "start-drag") else {
            finishSource(projected, outcome: .failed)
            return nil
        }
        return sessionID
    }

    public func surfaceWillClose(_ surfaceID: UInt) {
        guard incoming?.offer.surfaceID == surfaceID else { return }
        cancelIncoming()
    }

    public func sceneWillDisconnect(_ scene: WindowScene) {
        if incoming?.scene === scene {
            cancelIncoming()
        }
        for source in sources.values where source.scene === scene {
            finishSource(source, outcome: .cancelled)
        }
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelIncoming()
        for source in Array(sources.values) {
            finishSource(source, outcome: .cancelled)
        }
        for offer in Array(offers.values) {
            destroyOffer(offer)
        }
        readTokens.removeAll()
        transferExecutor.shutdown()
        if let device {
            try? device.release()
            self.device = nil
        }
    }

    isolated deinit {
        shutdown()
    }

    private func beginIncoming(
        offer: Offer,
        serial: UInt32,
        surfaceID: UInt,
        surfaceLocation: Point
    ) {
        cancelIncoming()
        guard serial != 0,
              !offer.mimeTypes.isEmpty,
              !offer.sourceActions.isEmpty,
              let destination = destinationResolver(
                surfaceID,
                surfaceLocation)
        else {
            reject(offer, serial: serial)
            destroyOffer(offer)
            return
        }

        offer.enterSerial = serial
        offer.surfaceID = surfaceID
        var providers: [String: DragSourceConfiguration.PayloadProvider] = [:]
        for mime in offer.mimeTypes {
            providers[mime] = { [weak self, weak offer] in
                guard let self, let offer else {
                    throw DataTransferFailure.cancelled
                }
                return try await self.receive(
                    offer: offer,
                    mime: mime)
            }
        }
        let configuration = DragSourceConfiguration(
            payloadProviders: providers,
            allowedOperations: offer.sourceActions,
            maximumPayloadBytes: limits.maximumBytes,
            completion: { [weak self, weak offer] outcome in
                guard let self, let offer else { return }
                self.incomingDidComplete(offer: offer, outcome: outcome)
            })
        guard let sessionID = destination.scene.beginExternalDrag(
            source: configuration,
            at: destination.sceneLocation)
        else {
            reject(offer, serial: serial)
            destroyOffer(offer)
            return
        }
        incoming = IncomingSession(
            offer: offer,
            scene: destination.scene,
            sessionID: sessionID,
            lastSceneLocation: destination.sceneLocation)
        negotiateIncoming(at: destination.sceneLocation)
    }

    private func moveIncoming(
        surfaceLocation: Point
    ) {
        guard let incoming,
              let destination = destinationResolver(
                incoming.offer.surfaceID,
                surfaceLocation),
              destination.scene === incoming.scene
        else {
            cancelIncoming()
            return
        }
        incoming.lastSceneLocation = destination.sceneLocation
        negotiateIncoming(at: destination.sceneLocation)
    }

    private func negotiateIncoming(at sceneLocation: Point) {
        guard let incoming, let scene = incoming.scene else {
            return
        }
        let proposal = scene.updateDrag(at: sceneLocation)
        let offer = incoming.offer
        let mime = proposal?.contentType
        try? offer.proxy.accept(
            serial: offer.enterSerial,
            mime_type: mime)
        let operation = proposal?.operation
        let actions = operation.map(Self.protocolAction) ?? .none
        try? offer.proxy.setActions(
            dnd_actions: actions,
            preferred_action: actions)
        _ = flush(operation: "update-drag")
    }

    private func performIncomingDrop() {
        guard let incoming,
              !incoming.isDropping,
              let scene = incoming.scene
        else {
            cancelIncoming()
            return
        }
        incoming.isDropping = true
        let sessionID = incoming.sessionID
        let location = incoming.lastSceneLocation
        Task { @MainActor [weak self, weak scene] in
            guard let self, let scene else { return }
            let outcome = await scene.drop(at: location)
            guard let current = self.incoming,
                  current.sessionID == sessionID
            else {
                return
            }
            if case .performed = outcome {
                try? current.offer.proxy.finish()
                _ = self.flush(operation: "finish-drag")
            }
            self.finishIncoming(current)
        }
    }

    private func receive(
        offer: Offer,
        mime: String
    ) async throws -> Data {
        guard !isShutdown,
              incoming?.offer === offer,
              offer.mimeTypes.contains(mime)
        else {
            throw DataTransferFailure.cancelled
        }
        let requestID = allocateRequestID()
        let result: Result<[UInt8], DataTransferFailure> =
            await withTaskCancellationHandler {
                if Task.isCancelled {
                    return .failure(.cancelled)
                }
                return await withCheckedContinuation { continuation in
                    startRead(
                        requestID: requestID,
                        offer: offer,
                        mime: mime,
                        continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelRead(requestID: requestID)
                }
            }
        return Data(try result.get())
    }

    private func startRead(
        requestID: UInt64,
        offer: Offer,
        mime: String,
        continuation:
            CheckedContinuation<Result<[UInt8], DataTransferFailure>, Never>
    ) {
        guard !isShutdown, incoming?.offer === offer else {
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard unsafe pipe2(&descriptors, O_CLOEXEC | O_NONBLOCK) == 0 else {
            continuation.resume(returning: .failure(.transport(
                "failed to create drag pipe: "
                    + (unsafe String(cString: strerror(errno))))))
            return
        }
        let readDescriptor = TransferFileDescriptor(owning: descriptors[0])
        let writeDescriptor = TransferFileDescriptor(owning: descriptors[1])
        do {
            try offer.proxy.receive(
                mime_type: mime,
                fd: WaylandClientOwnedFileDescriptor(writeDescriptor.release()))
        } catch {
            continuation.resume(returning: .failure(
                .transport("failed to request the Wayland drag payload")))
            return
        }
        let token = transferExecutor.installRead(
            owning: readDescriptor,
            operation: "receive-drag",
            byteLimit: limits.maximumBytes,
            deadlineNanoseconds: monotonicNowNanoseconds().saturatingAdd(
                limits.transferTimeoutNanoseconds)
        ) { [weak self] result in
            self?.readTokens.removeValue(forKey: requestID)
            continuation.resume(returning: result)
        }
        readTokens[requestID] = (offer.proxy.identity, token)
        guard flush(operation: "receive-drag") else {
            transferExecutor.failRead(
                token: token,
                failure: .transport("failed to flush drag receive request"))
            return
        }
    }

    private func cancelRead(requestID: UInt64) {
        guard let entry = readTokens.removeValue(forKey: requestID)
        else { return }
        transferExecutor.cancelRead(token: entry.token)
    }

    private func source(
        _ source: Source,
        send mime: String?,
        owning fileDescriptor: Int32
    ) {
        guard fileDescriptor >= 0 else {
            diagnosticHandler(
                "serve-drag",
                "compositor supplied an invalid transfer descriptor")
            return
        }
        guard configureTransferDescriptor(fileDescriptor) else {
            _ = Glibc.close(fileDescriptor)
            return
        }
        let stored = StoredTransferFileDescriptor(
            owning: TransferFileDescriptor(owning: fileDescriptor))
        guard !isShutdown,
              sources[source.proxy.identity] === source,
              let mime,
              let provider = source.configuration.payloadProviders[mime]
        else {
            stored.close()
            return
        }

        let requestID = allocateRequestID()
        source.pendingDescriptors[requestID] = stored
        source.providerTasks[requestID] = Task {
            @MainActor [weak self, weak source] in
            guard let self, let source else {
                stored.close()
                return
            }
            do {
                let data = try await provider()
                guard data.count <= source.configuration.maximumPayloadBytes
                else {
                    throw DataTransferFailure.transport(
                        "drag payload exceeded "
                            + "\(source.configuration.maximumPayloadBytes) "
                            + "byte limit")
                }
                self.installSourceWrite(
                    source: source,
                    requestID: requestID,
                    payload: Array(data))
            } catch {
                source.providerTasks.removeValue(forKey: requestID)
                source.pendingDescriptors.removeValue(
                    forKey: requestID)?.close()
                self.diagnosticHandler(
                    "serve-drag",
                    String(describing: error))
            }
        }
    }

    private func installSourceWrite(
        source: Source,
        requestID: UInt64,
        payload: [UInt8]
    ) {
        source.providerTasks.removeValue(forKey: requestID)
        guard sources[source.proxy.identity] === source,
              let descriptor = source.pendingDescriptors.removeValue(
                forKey: requestID)
        else {
            source.pendingDescriptors.removeValue(
                forKey: requestID)?.close()
            return
        }
        if let token = transferExecutor.installWrite(
            owning: descriptor,
            operation: "serve-drag",
            payload: payload,
            deadlineNanoseconds: monotonicNowNanoseconds().saturatingAdd(
                limits.transferTimeoutNanoseconds))
        {
            source.transferTokens.insert(token)
        }
    }

    private func finishSource(
        _ source: Source,
        outcome: DragCompletionOutcome
    ) {
        guard !source.isDestroyed else { return }
        source.isDestroyed = true
        sources.removeValue(forKey: source.proxy.identity)
        for task in source.providerTasks.values {
            task.cancel()
        }
        source.providerTasks.removeAll()
        for descriptor in source.pendingDescriptors.values {
            descriptor.close()
        }
        source.pendingDescriptors.removeAll()
        for token in source.transferTokens {
            transferExecutor.cancel(token: token)
        }
        source.transferTokens.removeAll()
        source.scene?.completeDrag(
            sessionID: source.sessionID,
            outcome: outcome)
        source.adapter = nil
        try? source.proxy.destroy()
    }

    private func incomingDidComplete(
        offer: Offer,
        outcome: DragCompletionOutcome
    ) {
        guard let incoming, incoming.offer === offer else {
            return
        }
        if incoming.isDropping {
            return
        }
        finishIncoming(incoming)
    }

    private func cancelIncoming() {
        guard let incoming else { return }
        incoming.scene?.cancelDrag()
        if self.incoming != nil {
            finishIncoming(incoming)
        }
    }

    private func finishIncoming(_ session: IncomingSession) {
        guard incoming?.sessionID == session.sessionID else {
            return
        }
        incoming = nil
        let offerKey = session.offer.proxy.identity
        let requests = readTokens.filter {
            $0.value.offerKey == offerKey
        }.map(\.key)
        for requestID in requests {
            cancelRead(requestID: requestID)
        }
        destroyOffer(session.offer)
    }

    private func reject(_ offer: Offer, serial: UInt32) {
        try? offer.proxy.accept(serial: serial, mime_type: nil)
        try? offer.proxy.setActions(
            dnd_actions: .none,
            preferred_action: .none)
        _ = flush(operation: "reject-drag")
    }

    private func destroyOffer(_ offer: Offer) {
        guard !offer.isDestroyed else { return }
        offer.isDestroyed = true
        offer.adapter = nil
        offers.removeValue(forKey: offer.proxy.identity)
        try? offer.proxy.destroy()
    }

    private func configureTransferDescriptor(_ descriptor: Int32) -> Bool {
        let statusFlags = fcntl(descriptor, F_GETFL)
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard statusFlags >= 0,
              descriptorFlags >= 0,
              fcntl(
                descriptor,
                F_SETFL,
                statusFlags | O_NONBLOCK) == 0,
              fcntl(
                descriptor,
                F_SETFD,
                descriptorFlags | FD_CLOEXEC) == 0
        else {
            diagnosticHandler(
                "serve-drag",
                "failed to configure transfer descriptor: "
                    + (unsafe String(cString: strerror(errno))))
            return false
        }
        return true
    }

    private func flush(operation: String) -> Bool {
        let result = client.flush()
        guard result < 0, errno != EAGAIN else { return true }
        diagnosticHandler(
            operation,
            "Wayland flush failed: " + (unsafe String(cString: strerror(errno))))
        return false
    }

    private func allocateRequestID() -> UInt64 {
        let result = nextRequestID
        nextRequestID &+= 1
        precondition(nextRequestID != 0, "drag request id exhausted")
        return result
    }

    private func monotonicNowNanoseconds() -> UInt64 {
        ShellMonotonicClock.nowNanoseconds()
    }

    fileprivate nonisolated static func operations(
        from mask: UInt32
    ) -> Set<DragOperation> {
        Set(DragOperation.allCases.filter {
            mask & $0.rawValue != 0
        })
    }

    fileprivate nonisolated static func operation(
        from rawValue: UInt32
    ) -> DragOperation? {
        DragOperation(rawValue: rawValue)
    }

    fileprivate nonisolated static func actionMask(
        _ operations: Set<DragOperation>
    ) -> UInt32 {
        operations.reduce(0) { $0 | $1.rawValue }
    }

    fileprivate nonisolated static func actionMask(
        _ operation: DragOperation
    ) -> UInt32 {
        operation.rawValue
    }

    fileprivate nonisolated static func protocolActions(
        _ operations: Set<DragOperation>
    ) -> WlDataDeviceManagerDndAction {
        WlDataDeviceManagerDndAction(rawValue: actionMask(operations))
    }

    fileprivate nonisolated static func protocolAction(
        _ operation: DragOperation
    ) -> WlDataDeviceManagerDndAction {
        WlDataDeviceManagerDndAction(rawValue: actionMask(operation))
    }
}

extension ShellWaylandDragDropAdapter: WlDataDeviceEvents {
    public func dataOffer(
        _ proxy: WaylandBorrowedProxy<WlDataDeviceClient>,
        id: WaylandProxy<WlDataOfferClient>
    ) {
        guard !isShutdown else {
            try? id.destroy()
            return
        }
        do {
            offers[id.identity] = try Offer(proxy: id, adapter: self)
        } catch {
            try? id.destroy()
        }
    }

    public func enter(
        _ proxy: WaylandBorrowedProxy<WlDataDeviceClient>,
        serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>,
        x: Double,
        y: Double,
        id: WaylandBorrowedProxy<WlDataOfferClient>?
    ) {
        let offerID: UInt?
        if let id {
            offerID = id.identity
        } else {
            offerID = nil
        }
        let surfaceID = surface.identity
        guard let offerID, let offer = offers[offerID] else {
            return
        }
        beginIncoming(
            offer: offer,
            serial: serial,
            surfaceID: surfaceID,
            surfaceLocation: Point(x: x, y: y))
    }

    public func leave(
        _ proxy: WaylandBorrowedProxy<WlDataDeviceClient>
    ) {
        cancelIncoming()
    }

    public func motion(
        _ proxy: WaylandBorrowedProxy<WlDataDeviceClient>,
        time: UInt32,
        x: Double,
        y: Double
    ) {
        moveIncoming(surfaceLocation: Point(x: x, y: y))
    }

    public func drop(
        _ proxy: WaylandBorrowedProxy<WlDataDeviceClient>
    ) {
        performIncomingDrop()
    }

    public func selection(
        _ proxy: WaylandBorrowedProxy<WlDataDeviceClient>,
        id: WaylandBorrowedProxy<WlDataOfferClient>?
    ) {
        let offerID: UInt?
        if let id {
            offerID = id.identity
        } else {
            offerID = nil
        }
        // Clipboard selection is owned by ext-data-control. Destroy the
        // corresponding core data-device offer without touching drag state.
        guard let offerID,
              let offer = offers[offerID],
              incoming?.offer !== offer
        else {
            return
        }
        destroyOffer(offer)
    }
}
