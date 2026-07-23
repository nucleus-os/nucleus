public import NucleusLayers
internal import protocol NucleusAppHostProtocols.ContextIDAllocator

/// Stable semantic identity for a `View`.
///
/// A view ID belongs to the UI model. It is deliberately unrelated to a
/// `NucleusLayers.LayerID`: a publisher may materialize the same semantic tree
/// into different visual contexts, and each visual context owns its own layer
/// namespace.
public struct ViewID: RawRepresentable, Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "ViewID.zero is reserved")
        self.rawValue = rawValue
    }
}

/// Stable semantic identity for a `Window`.
public struct WindowID: RawRepresentable, Hashable, Sendable, Equatable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "WindowID.zero is reserved")
        self.rawValue = rawValue
    }
}

package enum ViewDirtyDomain: CaseIterable, Hashable, Sendable {
    case structure
    case geometry
    case visibility
    case style
    case content
    case transform
    case scrolling
    case accessibility
    case animation
}

/// Per-domain semantic revisions for a view and for the dirty work below it.
///
/// Revisions come from the owning `UIContext`, so an ancestor can summarize a
/// descendant mutation by copying the same monotonically increasing value.
/// Publishers can therefore reject an entirely clean subtree without walking
/// it, while independent domains remain independently diffable.
package struct ViewDirtyGenerations: Sendable, Equatable {
    package var structure: UInt64 = 0
    package var geometry: UInt64 = 0
    package var visibility: UInt64 = 0
    package var style: UInt64 = 0
    package var content: UInt64 = 0
    package var transform: UInt64 = 0
    package var scrolling: UInt64 = 0
    package var accessibility: UInt64 = 0
    package var animation: UInt64 = 0

    package subscript(_ domain: ViewDirtyDomain) -> UInt64 {
        get {
            switch domain {
            case .structure: structure
            case .geometry: geometry
            case .visibility: visibility
            case .style: style
            case .content: content
            case .transform: transform
            case .scrolling: scrolling
            case .accessibility: accessibility
            case .animation: animation
            }
        }
        set {
            switch domain {
            case .structure: structure = newValue
            case .geometry: geometry = newValue
            case .visibility: visibility = newValue
            case .style: style = newValue
            case .content: content = newValue
            case .transform: transform = newValue
            case .scrolling: scrolling = newValue
            case .accessibility: accessibility = newValue
            case .animation: animation = newValue
            }
        }
    }
}

/// Semantic services and identity namespace shared by one retained UI graph.
///
/// This context contains no render layers, visual transaction buffers, or
/// registered paint content. A visual host is paired with it by `Application`
/// only while constructing a scene; views retain this semantic context alone.
@MainActor
public final class UIContext: ~Sendable {
    private let namespace: UInt32
    private var nextViewOrdinal: UInt32 = 1
    private var nextWindowOrdinal: UInt32 = 1
    private var nextAnimationOrdinal: UInt64 = 1
    private var nextDragSessionOrdinal: UInt64 = 1
    private var nextAccessibilityOrdinal: UInt64 = 1
    private var nextGeneration: UInt64 = 1
    private var actionPolicyStack: [ActionPolicy] = []
    private var pendingTransactionCompletions: [TransactionCompletionHandle] = []
    package var valueAnimationRecords: [UInt64: ValueAnimationRecord] = [:]
    package var valueAnimationSlots: [ValueAnimationSlot: UInt64] = [:]
    package var valueAnimationFrameRequest:
        (@MainActor () -> Void)?
    package var valueAnimationFrameRequestPending = false
    package var valueAnimationLastPresentationNanoseconds: UInt64?

    package var pendingAccessibilityNotifications:
        [AccessibilityNotification] = []

    private final class WeakEnvironmentConsumer {
        weak var view: View?

        init(_ view: View) {
            self.view = view
        }
    }

    private var environmentConsumers:
        [ViewID: WeakEnvironmentConsumer] = [:]
    private var glyphConsumers: [ViewID: WeakGlyphConsumer] = [:]

    public let services: UIHostServices
    public let clock: UIClock
    public let imageRequests: ImageRequestPipeline
    public var glyphCatalog: GlyphCatalog? {
        didSet {
            guard glyphCatalog !== oldValue else { return }
            for consumer in glyphConsumers.values {
                consumer.value?.contextGlyphCatalogDidChange(
                    from: oldValue)
            }
        }
    }
    public private(set) var environment = UIEnvironment()
    /// Monotonic identity for values derived from the complete environment.
    ///
    /// Consumers that cache measurements use this instead of attempting to
    /// predict which environment fields a caller's measurement closure reads.
    public private(set) var environmentGeneration: UInt64 = 1

    /// Scene-local animation speed multiplier. Invalid values canonicalize to
    /// one so no duration reaching the renderer is NaN, infinite, or negative.
    public var animationSpeed: Double = 1 {
        didSet {
            guard animationSpeed.isFinite, animationSpeed > 0 else {
                animationSpeed = 1
                return
            }
        }
    }

    /// Opaque host identity used when semantic image requests are registered.
    ///
    /// The scalar identifies the host but owns no registered image or paint
    /// resource. Image ownership remains in `ImageResource`; visual paint
    /// ownership remains in the publisher.
    package let resourceHostHandle: UInt64
    package let runtimeHost: LayerRuntimeHost

    public init(
        services: UIHostServices,
        environment: UIEnvironment = UIEnvironment(),
        resourceHostHandle: UInt64 = 0,
        runtimeHost: LayerRuntimeHost = .inMemory(),
        glyphCatalog: GlyphCatalog? = nil,
        clock: UIClock = .continuous
    ) {
        let namespace: UInt32
        do {
            namespace = try runtimeHost.operations.contextIDAllocator.reserve()
        } catch {
            preconditionFailure(
                "UIContext identity namespace allocation failed: \(error)")
        }
        self.services = services
        self.clock = clock
        self.imageRequests = ImageRequestPipeline(
            resourceHostHandle: resourceHostHandle,
            runtimeHost: runtimeHost,
            clock: clock,
            resolver: services.imageSourceResolver,
            diagnostic: { failure, request in
                services.report(UIHostDiagnostic(
                    service: .image,
                    operation: "request-resource",
                    resourceIdentity: request.id.rawValue,
                    generation: request.cancellationGeneration,
                    failure: .image(failure)))
            })
        self.environment = environment
        self.glyphCatalog = glyphCatalog
        self.namespace = namespace
        self.resourceHostHandle = resourceHostHandle
        self.runtimeHost = runtimeHost
    }

    isolated deinit {
        runtimeHost.lifecycle.contextIDAllocator.release(namespace)
    }

    package func registerGlyphConsumer(_ view: GlyphView) {
        glyphConsumers[view.id] = WeakGlyphConsumer(view)
    }

    package func unregisterGlyphConsumer(_ id: ViewID) {
        glyphConsumers[id] = nil
    }

    /// Construct a detached semantic graph in this context.
    ///
    /// This is explicit test/tooling syntax. It installs no visual context and
    /// cannot create a renderable `WindowScene`; an embedder or app host must
    /// later pair the graph with its real visual context.
    public func construct<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try Application.withUIContext(self, body)
    }

    /// Construct a detached semantic graph across an asynchronous operation.
    ///
    /// The construction scope is task-local, so child tasks inherit the
    /// semantic owner without exposing a process-wide mutable context stack.
    /// As with the synchronous overload, this installs no visual context.
    public func construct<T>(
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await Application.withUIContext(self, body)
    }

    package func allocateViewID() -> ViewID {
        let ordinal = nextViewOrdinal
        nextViewOrdinal &+= 1
        precondition(
            nextViewOrdinal != 0 && nextViewOrdinal < 0x8000_0000,
            "UIContext view identity namespace exhausted")
        return ViewID(rawValue: (UInt64(namespace) << 32) | UInt64(ordinal))
    }

    package func allocateWindowID() -> WindowID {
        let ordinal = nextWindowOrdinal
        nextWindowOrdinal &+= 1
        precondition(
            nextWindowOrdinal != 0 && nextWindowOrdinal < 0x8000_0000,
            "UIContext window identity namespace exhausted")
        return WindowID(
            rawValue: (UInt64(namespace) << 32) |
                UInt64(0x8000_0000 | ordinal)
        )
    }

    package func allocateGeneration() -> UInt64 {
        let generation = nextGeneration
        nextGeneration &+= 1
        precondition(nextGeneration != 0, "UIContext dirty generation exhausted")
        return generation
    }

    package func allocateAnimationID() -> UInt64 {
        let animationID = nextAnimationOrdinal
        nextAnimationOrdinal &+= 1
        precondition(nextAnimationOrdinal != 0, "UIContext animation identity exhausted")
        return animationID
    }

    package func allocateDragSessionID() -> DragSessionID {
        let ordinal = nextDragSessionOrdinal
        nextDragSessionOrdinal &+= 1
        precondition(
            nextDragSessionOrdinal != 0,
            "drag session identity exhausted")
        return DragSessionID(context: namespace, ordinal: ordinal)
    }

    package func allocateAccessibilityID() -> AccessibilityID {
        let ordinal = nextAccessibilityOrdinal
        nextAccessibilityOrdinal &+= 1
        precondition(
            nextAccessibilityOrdinal != 0,
            "UIContext accessibility identity namespace exhausted")
        return AccessibilityID(context: namespace, ordinal: ordinal)
    }

    package func postAccessibilityNotification(
        _ notification: AccessibilityNotification
    ) {
        pendingAccessibilityNotifications.append(notification)
    }

    package func takeAccessibilityNotifications()
        -> [AccessibilityNotification]
    {
        defer {
            pendingAccessibilityNotifications.removeAll(
                keepingCapacity: true)
        }
        return pendingAccessibilityNotifications
    }

    package func effectiveAnimationDuration(_ duration: Double) -> Double {
        precondition(
            duration.isFinite && duration >= 0,
            "animation duration must be finite and nonnegative"
        )
        guard !environment.reducesMotion else { return 0 }
        return duration / animationSpeed
    }

    public func updateEnvironment(_ environment: UIEnvironment) {
        let next = UIEnvironment(
            reducesMotion: environment.reducesMotion,
            reducesTransparency: environment.reducesTransparency,
            increasesContrast: environment.increasesContrast,
            appearance: environment.appearance,
            textScale: environment.textScale)
        let changes = next.changes(from: self.environment)
        guard !changes.isEmpty else { return }
        self.environment = next
        environmentGeneration &+= 1
        precondition(
            environmentGeneration != 0,
            "UIContext environment generation exhausted")
        if changes.contains(.reducedMotion), next.reducesMotion {
            finishMotionScaledValueAnimationsForReducedMotion()
        }

        var dead: [ViewID] = []
        for (id, consumer) in environmentConsumers {
            guard let view = consumer.view else {
                dead.append(id)
                continue
            }
            let relevant = view.environmentDependencies
                .intersection(changes)
            if !relevant.isEmpty {
                view.environmentDidChange(relevant)
            }
        }
        for id in dead {
            environmentConsumers[id] = nil
        }
    }

    package func registerEnvironmentConsumer(_ view: View) {
        environmentConsumers[view.id] = WeakEnvironmentConsumer(view)
    }

    package func unregisterEnvironmentConsumer(_ id: ViewID) {
        environmentConsumers[id] = nil
    }

    package var currentActionPolicy: ActionPolicy {
        actionPolicyStack.last ?? .none
    }

    package func pushActionPolicy(_ policy: ActionPolicy) {
        actionPolicyStack.append(policy)
    }

    package func replaceCurrentActionPolicy(_ policy: ActionPolicy) {
        precondition(!actionPolicyStack.isEmpty, "no semantic transaction is active")
        actionPolicyStack[actionPolicyStack.count - 1] = policy
    }

    package func popActionPolicy() {
        precondition(!actionPolicyStack.isEmpty, "semantic transaction stack underflow")
        actionPolicyStack.removeLast()
    }

    package func withActionPolicy<T>(
        _ policy: ActionPolicy,
        _ body: () throws -> T
    ) rethrows -> T {
        pushActionPolicy(policy)
        defer { popActionPolicy() }
        return try body()
    }

    package func enqueueTransactionCompletion(
        _ handle: TransactionCompletionHandle
    ) {
        pendingTransactionCompletions.append(handle)
    }

    package func takeTransactionCompletions() -> [TransactionCompletionHandle] {
        defer { pendingTransactionCompletions.removeAll(keepingCapacity: true) }
        return pendingTransactionCompletions
    }
}
