import Foundation

public struct DragSessionID: Hashable, Sendable, Comparable {
    public let context: UInt32
    public let ordinal: UInt64

    public init(context: UInt32, ordinal: UInt64) {
        precondition(context != 0, "drag context zero is reserved")
        precondition(ordinal != 0, "drag ordinal zero is reserved")
        self.context = context
        self.ordinal = ordinal
    }

    public static func < (lhs: DragSessionID, rhs: DragSessionID) -> Bool {
        lhs.context == rhs.context
            ? lhs.ordinal < rhs.ordinal
            : lhs.context < rhs.context
    }
}

public enum DragOperation: UInt32, Sendable, Hashable, CaseIterable {
    case copy = 1
    case move = 2
    case link = 4
}

public struct DragOfferMetadata: Sendable, Equatable {
    public let contentTypes: [String]
    public let allowedOperations: Set<DragOperation>

    public init(
        contentTypes: some Sequence<String>,
        allowedOperations: Set<DragOperation>
    ) {
        self.contentTypes = Array(Set(
            contentTypes.filter { !$0.isEmpty })).sorted()
        self.allowedOperations = allowedOperations
    }
}

public struct DragDropProposal: Sendable, Equatable {
    public let contentType: String
    public let operation: DragOperation

    public init(contentType: String, operation: DragOperation) {
        precondition(!contentType.isEmpty)
        self.contentType = contentType
        self.operation = operation
    }
}

public struct DragDropInfo: Sendable, Equatable {
    public let sessionID: DragSessionID
    public let offer: DragOfferMetadata
    public let location: Point
    public let proposal: DragDropProposal?

    public init(
        sessionID: DragSessionID,
        offer: DragOfferMetadata,
        location: Point,
        proposal: DragDropProposal?
    ) {
        self.sessionID = sessionID
        self.offer = offer
        self.location = location
        self.proposal = proposal
    }
}

public struct DragPayload: Sendable, Equatable {
    public let contentType: String
    public let data: Data

    public init(contentType: String, data: Data) {
        self.contentType = contentType
        self.data = data
    }
}

public enum DragCompletionOutcome: Sendable, Equatable {
    case performed(DragOperation)
    case cancelled
    case rejected
    case failed
}

@MainActor
public struct DragSourceConfiguration {
    public typealias PayloadProvider =
        @MainActor @Sendable () async throws -> Data

    public let offer: DragOfferMetadata
    public let maximumPayloadBytes: Int
    public let preview: View?
    public let payloadProviders: [String: PayloadProvider]
    public let completion:
        (@MainActor (DragCompletionOutcome) -> Void)?

    public init(
        payloadProviders: [String: PayloadProvider],
        allowedOperations: Set<DragOperation> = [.copy],
        maximumPayloadBytes: Int = 8 * 1024 * 1024,
        preview: View? = nil,
        completion:
            (@MainActor (DragCompletionOutcome) -> Void)? = nil
    ) {
        precondition(maximumPayloadBytes >= 0)
        precondition(!payloadProviders.isEmpty)
        precondition(!allowedOperations.isEmpty)
        self.offer = DragOfferMetadata(
            contentTypes: payloadProviders.keys,
            allowedOperations: allowedOperations)
        self.maximumPayloadBytes = maximumPayloadBytes
        self.preview = preview
        self.payloadProviders = payloadProviders
        self.completion = completion
    }
}

@MainActor
public struct DropDestinationConfiguration {
    public let acceptedContentTypes: Set<String>
    public let proposal:
        @MainActor (DragDropInfo) -> DragDropProposal?
    public let entered: (@MainActor (DragDropInfo) -> Void)?
    public let updated: (@MainActor (DragDropInfo) -> Void)?
    public let exited: (@MainActor (DragDropInfo) -> Void)?
    public let perform:
        @MainActor (DragDropInfo, DragPayload) -> Bool

    public init(
        acceptedContentTypes: Set<String>,
        proposal:
            @escaping @MainActor (DragDropInfo) -> DragDropProposal?,
        entered: (@MainActor (DragDropInfo) -> Void)? = nil,
        updated: (@MainActor (DragDropInfo) -> Void)? = nil,
        exited: (@MainActor (DragDropInfo) -> Void)? = nil,
        perform:
            @escaping @MainActor (DragDropInfo, DragPayload) -> Bool
    ) {
        precondition(!acceptedContentTypes.isEmpty)
        self.acceptedContentTypes = acceptedContentTypes
        self.proposal = proposal
        self.entered = entered
        self.updated = updated
        self.exited = exited
        self.perform = perform
    }
}

@MainActor
package final class DragSession {
    enum Kind: Equatable {
        case local
        case incomingPlatform
        case outgoingPlatform
    }

    let id: DragSessionID
    let kind: Kind
    weak var sourceView: View?
    let source: DragSourceConfiguration
    weak var targetView: View?
    var targetGeneration: UInt64 = 0
    var proposal: DragDropProposal?
    var lastInfo: DragDropInfo?
    var pendingDrop: Task<Void, Never>?
    var pendingPayload: Task<Data, any Error>?
    var isTerminal = false

    init(
        id: DragSessionID,
        sourceView: View?,
        source: DragSourceConfiguration,
        kind: Kind
    ) {
        self.id = id
        self.kind = kind
        self.sourceView = sourceView
        self.source = source
    }
}

extension View {
    public func setDragSource(_ source: DragSourceConfiguration?) {
        storedDragSource = source
        if source == nil {
            clearAccessibilityAction(.startDrag)
            clearAccessibilityAction(.cancelDrag)
            return
        }
        setAccessibilityAction(.startDrag) { [weak self] _ in
            guard let self, let scene = window?.windowScene else {
                return false
            }
            return scene.beginDrag(
                from: self,
                at: scene.dragCenter(of: self)) != nil
        }
        setAccessibilityAction(.cancelDrag) { [weak self] _ in
            guard let scene = self?.window?.windowScene,
                  scene.activeDragSession != nil
            else {
                return false
            }
            scene.cancelDrag()
            return true
        }
    }

    public func setDropDestination(
        _ destination: DropDestinationConfiguration?
    ) {
        storedDropDestination = destination
        storedDropDestinationGeneration &+= 1
        precondition(
            storedDropDestinationGeneration != 0,
            "drop destination generation exhausted")
        if destination == nil {
            clearAccessibilityAction(.performDrop)
            return
        }
        setAccessibilityAction(.performDrop) { [weak self] _ in
            guard let self, let scene = window?.windowScene,
                  scene.activeDragSession != nil
            else {
                return false
            }
            let point = scene.dragCenter(of: self)
            guard scene.updateDrag(at: point) != nil else {
                return false
            }
            scene.dropFromInput(at: point)
            return true
        }
    }
}

extension WindowScene {
    package func beginConfiguredDrag(
        startingAt view: View,
        sceneLocation: Point
    ) -> Bool {
        var candidate: View? = view
        while let current = candidate {
            if current.storedDragSource != nil {
                return beginDrag(
                    from: current,
                    at: sceneLocation) != nil
            }
            candidate = current.superview
        }
        return false
    }

    @discardableResult
    public func beginDrag(
        from sourceView: View,
        at sceneLocation: Point
    ) -> DragSessionID? {
        guard activationState != .disconnected,
              sourceView.uiContext === uiContext,
              sourceView.window?.windowScene === self,
              let source = sourceView.storedDragSource
        else {
            return nil
        }
        return beginDrag(
            from: sourceView,
            source: source,
            at: sceneLocation)
    }

    /// Starts a drag whose immutable payload offer is supplied by a host
    /// adapter instead of being stored on the source view.
    @discardableResult
    public func beginDrag(
        from sourceView: View,
        source: DragSourceConfiguration,
        at sceneLocation: Point
    ) -> DragSessionID? {
        guard activationState != .disconnected,
              sourceView.uiContext === uiContext,
              sourceView.window?.windowScene === self
        else {
            return nil
        }
        return beginDragSession(
            sourceView: sourceView,
            source: source,
            kind: .local,
            at: sceneLocation)
    }

    /// Starts a drag entering this scene from a platform transport. The
    /// transport owns any platform offer; the retained session owns only the
    /// immutable metadata and async payload closures.
    @discardableResult
    public func beginExternalDrag(
        source: DragSourceConfiguration,
        at sceneLocation: Point
    ) -> DragSessionID? {
        guard activationState != .disconnected,
              source.preview == nil
        else {
            return nil
        }
        return beginDragSession(
            sourceView: nil,
            source: source,
            kind: .incomingPlatform,
            at: sceneLocation)
    }

    /// Starts the source side of a drag whose target lifecycle belongs to a
    /// platform transport. Pointer movement still owns the preview, while
    /// target negotiation and terminal completion come from the transport.
    @discardableResult
    public func beginProjectedDrag(
        from sourceView: View,
        source: DragSourceConfiguration,
        at sceneLocation: Point
    ) -> DragSessionID? {
        guard activationState != .disconnected,
              sourceView.uiContext === uiContext,
              sourceView.window?.windowScene === self
        else {
            return nil
        }
        return beginDragSession(
            sourceView: sourceView,
            source: source,
            kind: .outgoingPlatform,
            at: sceneLocation)
    }

    private func beginDragSession(
        sourceView: View?,
        source: DragSourceConfiguration,
        kind: DragSession.Kind,
        at sceneLocation: Point
    ) -> DragSessionID {
        cancelDrag()
        if let preview = source.preview {
            precondition(
                preview.uiContext === uiContext,
                "a drag preview must use the source UIContext")
            precondition(
                preview.superview == nil,
                "a drag preview must not already be retained")
            preview.isHitTestingEnabled = false
            sourceView?.window?.root?.addSubview(preview)
        }
        let session = DragSession(
            id: uiContext.allocateDragSessionID(),
            sourceView: sourceView,
            source: source,
            kind: kind)
        activeDragSession = session
        positionDragPreview(session, at: sceneLocation)
        _ = updateDrag(at: sceneLocation)
        return session.id
    }

    @discardableResult
    public func updateDrag(at sceneLocation: Point) -> DragDropProposal? {
        guard let session = activeDragSession,
              !session.isTerminal,
              session.sourceView == nil
                || session.sourceView?.window?.windowScene === self
        else {
            cancelDrag()
            return nil
        }
        positionDragPreview(session, at: sceneLocation)
        if session.kind == .outgoingPlatform {
            return nil
        }
        let candidate = dropCandidate(
            for: session, at: sceneLocation)
        if candidate?.view !== session.targetView {
            session.pendingPayload?.cancel()
            session.pendingPayload = nil
            notifyExit(session)
            session.targetView = candidate?.view
            session.targetGeneration =
                candidate?.view.storedDropDestinationGeneration ?? 0
            session.proposal = candidate?.proposal
            session.lastInfo = candidate?.info
            if let candidate {
                candidate.configuration.entered?(candidate.info)
            }
        } else if let candidate {
            session.proposal = candidate.proposal
            session.lastInfo = candidate.info
        } else {
            session.proposal = nil
            session.lastInfo = nil
        }
        if let candidate {
            candidate.configuration.updated?(candidate.info)
        }
        return candidate?.proposal
    }

    @discardableResult
    public func drop(
        at sceneLocation: Point
    ) async -> DragCompletionOutcome {
        guard let session = activeDragSession,
              !session.isTerminal
        else {
            return .cancelled
        }
        guard updateDrag(at: sceneLocation) != nil,
              let target = session.targetView,
              let proposal = session.proposal,
              let info = session.lastInfo,
              let destination = target.storedDropDestination,
              let provider =
                session.source.payloadProviders[proposal.contentType]
        else {
            finish(session, outcome: .rejected, notifyExit: true)
            return .rejected
        }
        let targetGeneration = session.targetGeneration
        let sourceID = session.sourceView?.id
        let targetID = target.id
        let data: Data
        do {
            let payloadTask = Task { @MainActor in
                try await provider()
            }
            session.pendingPayload = payloadTask
            data = try await payloadTask.value
            session.pendingPayload = nil
        } catch {
            session.pendingPayload = nil
            guard activeDragSession === session, !session.isTerminal else {
                return .cancelled
            }
            finish(session, outcome: .failed, notifyExit: true)
            return .failed
        }
        guard data.count <= session.source.maximumPayloadBytes else {
            finish(session, outcome: .failed, notifyExit: true)
            return .failed
        }
        guard activeDragSession === session,
              !session.isTerminal,
              session.sourceView?.id == sourceID,
              (session.sourceView == nil
                || session.sourceView?.window?.windowScene === self),
              session.targetView?.id == targetID,
              target.window?.windowScene === self,
              target.storedDropDestinationGeneration == targetGeneration,
              session.proposal == proposal
        else {
            if activeDragSession === session {
                finish(session, outcome: .cancelled, notifyExit: true)
            }
            return .cancelled
        }
        let accepted = destination.perform(
            info,
            DragPayload(contentType: proposal.contentType, data: data))
        let outcome: DragCompletionOutcome =
            accepted ? .performed(proposal.operation) : .rejected
        finish(session, outcome: outcome, notifyExit: false)
        return outcome
    }

    public func cancelDrag() {
        guard let session = activeDragSession else { return }
        finish(session, outcome: .cancelled, notifyExit: true)
    }

    /// Completes a source session projected to a platform drag transport.
    /// Stale or duplicate completion messages are ignored.
    public func completeDrag(
        sessionID: DragSessionID,
        outcome: DragCompletionOutcome
    ) {
        guard let session = activeDragSession,
              session.id == sessionID
        else {
            return
        }
        finish(session, outcome: outcome, notifyExit: true)
    }

    package func dropFromInput(at sceneLocation: Point) {
        guard let session = activeDragSession,
              session.kind != .outgoingPlatform,
              session.pendingDrop == nil
        else { return }
        session.pendingDrop = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            _ = await drop(at: sceneLocation)
            session.pendingDrop = nil
        }
    }

    package func dragParticipantWillDetach(_ view: View) {
        guard let session = activeDragSession else { return }
        if session.sourceView === view
            || session.sourceView?.isDescendant(of: view) == true
            || session.targetView === view
            || session.targetView?.isDescendant(of: view) == true
        {
            cancelDrag()
        }
    }

    package func dragCenter(of view: View) -> Point {
        let local = Point(
            x: view.bounds.origin.x + view.bounds.size.width / 2,
            y: view.bounds.origin.y + view.bounds.size.height / 2)
        guard let window = view.window else { return .zero }
        return window.scenePoint(
            fromWindow: view.convert(local, to: nil))
    }

    private func dropCandidate(
        for session: DragSession,
        at sceneLocation: Point
    ) -> (
        view: View,
        configuration: DropDestinationConfiguration,
        proposal: DragDropProposal,
        info: DragDropInfo
    )? {
        guard let hit = hitTest(at: sceneLocation) else { return nil }
        var view: View? = hit.view
        while let current = view {
            if let destination = current.storedDropDestination {
                let commonTypes = destination.acceptedContentTypes
                    .intersection(session.source.offer.contentTypes)
                if !commonTypes.isEmpty {
                    let local = current.convert(
                        hit.window.windowPoint(fromScene: sceneLocation),
                        from: nil)
                    let base = DragDropInfo(
                        sessionID: session.id,
                        offer: session.source.offer,
                        location: local,
                        proposal: nil)
                    if let proposal = destination.proposal(base),
                       commonTypes.contains(proposal.contentType),
                       session.source.offer.allowedOperations.contains(
                           proposal.operation)
                    {
                        let info = DragDropInfo(
                            sessionID: session.id,
                            offer: session.source.offer,
                            location: local,
                            proposal: proposal)
                        return (
                            current, destination, proposal, info)
                    }
                }
            }
            view = current.superview
        }
        return nil
    }

    private func notifyExit(_ session: DragSession) {
        guard let target = session.targetView,
              let info = session.lastInfo,
              let destination = target.storedDropDestination
        else {
            return
        }
        destination.exited?(info)
    }

    private func finish(
        _ session: DragSession,
        outcome: DragCompletionOutcome,
        notifyExit: Bool
    ) {
        guard !session.isTerminal else { return }
        session.isTerminal = true
        session.pendingPayload?.cancel()
        session.pendingPayload = nil
        if notifyExit { self.notifyExit(session) }
        session.source.preview?.removeFromSuperview()
        session.targetView = nil
        session.lastInfo = nil
        session.proposal = nil
        if activeDragSession === session {
            activeDragSession = nil
        }
        session.source.completion?(outcome)
    }

    private func positionDragPreview(
        _ session: DragSession,
        at sceneLocation: Point
    ) {
        guard let preview = session.source.preview,
              let window = session.sourceView?.window,
              let root = window.root
        else {
            return
        }
        let local = root.convert(
            window.windowPoint(fromScene: sceneLocation),
            from: nil)
        preview.frame = Rect(
            x: local.x,
            y: local.y,
            width: preview.frame.size.width,
            height: preview.frame.size.height)
    }
}
