import FoundationEssentials
import Glibc
public import NucleusShellLoop
public import NucleusShellWayland
public import NucleusUI
import WaylandClientC
public import WaylandClientDispatch

/// The `wl_data_device` projection of NucleusUI's retained drag lifecycle.
///
/// Clipboard state intentionally lives in `ShellWaylandPasteboardAdapter`.
/// Sharing this target gives both transports the same descriptor executor
/// without sharing offers, sources, cancellation, or selection state.
@MainActor
public final class ShellWaylandDragDropAdapter {
    public typealias DestinationResolver =
        @MainActor (_ surfaceID: UInt, _ surfaceLocation: Point)
            -> (scene: WindowScene, sceneLocation: Point)?
    public typealias DiagnosticHandler =
        @MainActor @Sendable (_ operation: String, _ message: String) -> Void

    @MainActor
    private final class Offer: WlDataOfferEvents {
        let proxy: OpaquePointer
        weak var adapter: ShellWaylandDragDropAdapter?
        var mimeTypes: Set<String> = []
        var sourceActions: Set<DragOperation> = []
        var selectedAction: DragOperation?
        var enterSerial: UInt32 = 0
        var surfaceID: UInt = 0
        var isDestroyed = false

        init(
            proxy: OpaquePointer,
            adapter: ShellWaylandDragDropAdapter
        ) {
            self.proxy = proxy
            self.adapter = adapter
            WlDataOfferClient.addListener(proxy, owner: self)
        }

        nonisolated func offer(
            _ proxy: OpaquePointer,
            mime_type: UnsafePointer<CChar>?
        ) {
            guard let mime_type else { return }
            let mime = String(cString: mime_type)
            _ = MainActor.assumeIsolated {
                mimeTypes.insert(mime)
            }
        }

        nonisolated func sourceActions(
            _ proxy: OpaquePointer,
            source_actions: UInt32
        ) {
            MainActor.assumeIsolated {
                sourceActions =
                    ShellWaylandDragDropAdapter.operations(from: source_actions)
            }
        }

        nonisolated func action(
            _ proxy: OpaquePointer,
            dnd_action: UInt32
        ) {
            MainActor.assumeIsolated {
                selectedAction =
                    ShellWaylandDragDropAdapter.operation(from: dnd_action)
            }
        }
    }

    @MainActor
    private final class Source: WlDataSourceEvents {
        let proxy: OpaquePointer
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
            proxy: OpaquePointer,
            sessionID: DragSessionID,
            scene: WindowScene,
            configuration: DragSourceConfiguration,
            adapter: ShellWaylandDragDropAdapter
        ) {
            self.proxy = proxy
            self.sessionID = sessionID
            self.scene = scene
            self.configuration = configuration
            self.adapter = adapter
            WlDataSourceClient.addListener(proxy, owner: self)
        }

        nonisolated func target(
            _ proxy: OpaquePointer,
            mime_type: UnsafePointer<CChar>?
        ) {}

        nonisolated func send(
            _ proxy: OpaquePointer,
            mime_type: UnsafePointer<CChar>?,
            fd: Int32
        ) {
            let mime = mime_type.map(String.init(cString:))
            MainActor.assumeIsolated {
                adapter?.source(self, send: mime, owning: fd)
            }
        }

        nonisolated func cancelled(_ proxy: OpaquePointer) {
            MainActor.assumeIsolated {
                adapter?.finishSource(self, outcome: .cancelled)
            }
        }

        nonisolated func dndDropPerformed(_ proxy: OpaquePointer) {
            MainActor.assumeIsolated {
                didPerformDrop = true
            }
        }

        nonisolated func dndFinished(_ proxy: OpaquePointer) {
            MainActor.assumeIsolated {
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
        }

        nonisolated func action(
            _ proxy: OpaquePointer,
            dnd_action: UInt32
        ) {
            MainActor.assumeIsolated {
                selectedAction =
                    ShellWaylandDragDropAdapter.operation(from: dnd_action)
            }
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
    private let manager: OpaquePointer
    private var device: OpaquePointer?
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
        guard let manager = client.proxy(.dataDeviceManager),
              let device = wl_data_device_manager_get_data_device(
                manager,
                seat.protocolSeat)
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
        WlDataDeviceClient.addListener(device, owner: self)
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
        originSurface: OpaquePointer,
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
        guard let proxy = wl_data_device_manager_create_data_source(manager)
        else {
            scene.completeDrag(
                sessionID: sessionID,
                outcome: .failed)
            return nil
        }

        let projected = Source(
            proxy: proxy,
            sessionID: sessionID,
            scene: scene,
            configuration: source,
            adapter: self)
        sources[key(proxy)] = projected
        for mime in source.offer.contentTypes {
            mime.withCString { wl_data_source_offer(proxy, $0) }
        }
        wl_data_source_set_actions(
            proxy,
            Self.actionMask(source.offer.allowedOperations))
        wl_data_device_start_drag(
            device,
            proxy,
            originSurface,
            nil,
            authorization.serial)
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
            wl_data_device_release(device)
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
        mime?.withCString {
            wl_data_offer_accept(offer.proxy, offer.enterSerial, $0)
        }
        if mime == nil {
            wl_data_offer_accept(
                offer.proxy,
                offer.enterSerial,
                nil)
        }
        let operation = proposal?.operation
        wl_data_offer_set_actions(
            offer.proxy,
            operation.map(Self.actionMask) ?? 0,
            operation.map(Self.actionMask) ?? 0)
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
                wl_data_offer_finish(current.offer.proxy)
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
        guard pipe2(&descriptors, O_CLOEXEC | O_NONBLOCK) == 0 else {
            continuation.resume(returning: .failure(.transport(
                "failed to create drag pipe: "
                    + String(cString: strerror(errno)))))
            return
        }
        let readDescriptor = TransferFileDescriptor(owning: descriptors[0])
        let writeDescriptor = TransferFileDescriptor(owning: descriptors[1])
        mime.withCString {
            wl_data_offer_receive(
                offer.proxy,
                $0,
                writeDescriptor.rawValue)
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
        readTokens[requestID] = (key(offer.proxy), token)
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
              sources[key(source.proxy)] === source,
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
        guard sources[key(source.proxy)] === source,
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
        sources.removeValue(forKey: key(source.proxy))
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
        wl_data_source_destroy(source.proxy)
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
        let offerKey = key(session.offer.proxy)
        let requests = readTokens.filter {
            $0.value.offerKey == offerKey
        }.map(\.key)
        for requestID in requests {
            cancelRead(requestID: requestID)
        }
        destroyOffer(session.offer)
    }

    private func reject(_ offer: Offer, serial: UInt32) {
        wl_data_offer_accept(offer.proxy, serial, nil)
        wl_data_offer_set_actions(offer.proxy, 0, 0)
        _ = flush(operation: "reject-drag")
    }

    private func destroyOffer(_ offer: Offer) {
        guard !offer.isDestroyed else { return }
        offer.isDestroyed = true
        offer.adapter = nil
        offers.removeValue(forKey: key(offer.proxy))
        wl_data_offer_destroy(offer.proxy)
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
                    + String(cString: strerror(errno)))
            return false
        }
        return true
    }

    private func flush(operation: String) -> Bool {
        let result = client.flush()
        guard result < 0, errno != EAGAIN else { return true }
        diagnosticHandler(
            operation,
            "Wayland flush failed: " + String(cString: strerror(errno)))
        return false
    }

    private func allocateRequestID() -> UInt64 {
        let result = nextRequestID
        nextRequestID &+= 1
        precondition(nextRequestID != 0, "drag request id exhausted")
        return result
    }

    private func key(_ proxy: OpaquePointer) -> UInt {
        UInt(bitPattern: proxy)
    }

    private func monotonicNowNanoseconds() -> UInt64 {
        var time = timespec()
        _ = clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(max(0, time.tv_sec))
            .saturatingMultiply(1_000_000_000)
            .saturatingAdd(UInt64(max(0, time.tv_nsec)))
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
}

extension ShellWaylandDragDropAdapter: WlDataDeviceEvents {
    public nonisolated func dataOffer(
        _ proxy: OpaquePointer,
        id: OpaquePointer?
    ) {
        guard let id else { return }
        let rawID = UInt(bitPattern: id)
        MainActor.assumeIsolated {
            guard !isShutdown,
                  let proxy = OpaquePointer(bitPattern: rawID)
            else {
                return
            }
            offers[rawID] = Offer(proxy: proxy, adapter: self)
        }
    }

    public nonisolated func enter(
        _ proxy: OpaquePointer,
        serial: UInt32,
        surface: OpaquePointer?,
        x: Double,
        y: Double,
        id: OpaquePointer?
    ) {
        let offerID = id.map { UInt(bitPattern: $0) }
        let surfaceID = surface.map { UInt(bitPattern: $0) } ?? 0
        MainActor.assumeIsolated {
            guard let offerID, let offer = offers[offerID] else {
                return
            }
            beginIncoming(
                offer: offer,
                serial: serial,
                surfaceID: surfaceID,
                surfaceLocation: Point(x: x, y: y))
        }
    }

    public nonisolated func leave(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated {
            cancelIncoming()
        }
    }

    public nonisolated func motion(
        _ proxy: OpaquePointer,
        time: UInt32,
        x: Double,
        y: Double
    ) {
        MainActor.assumeIsolated {
            moveIncoming(surfaceLocation: Point(x: x, y: y))
        }
    }

    public nonisolated func drop(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated {
            performIncomingDrop()
        }
    }

    public nonisolated func selection(
        _ proxy: OpaquePointer,
        id: OpaquePointer?
    ) {
        let offerID = id.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated {
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
}
