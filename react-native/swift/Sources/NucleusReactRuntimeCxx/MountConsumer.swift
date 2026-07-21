import CxxStdlib
import NucleusUI
import NucleusUIEmbedder
import NucleusReactRuntimeCxxBridge
import Synchronization
import Tracy

// Swift-native snapshots of `nucleus::react::MountMutation`. The raw C++ value
// never appears in cross-module Swift API. A tagged event retains only the data
// its mutation uses, and component classification happens once while the C++
// snapshot is still borrowed.
public enum MountComponentKind: Sendable {
    case root
    case view
    case text
    case image
    case other

    init(_ kind: nucleus.react.MountComponentKind) {
        switch kind {
        case .Root:
            self = .root
        case .View:
            self = .view
        case .Text:
            self = .text
        case .Image:
            self = .image
        case .Other:
            self = .other
        @unknown default:
            self = .other
        }
    }

    var isCreatable: Bool {
        self == .view || self == .text || self == .image
    }
}

public struct MountViewSnapshot: Sendable {
    public let nativeID: String
    public let frame: Rect

    public init(nativeID: String, frame: Rect) {
        self.nativeID = nativeID
        self.frame = frame
    }
}

public enum MountComponentSnapshot: Sendable {
    case root(MountViewSnapshot)
    case view(
        MountViewSnapshot,
        backgroundColor: MountEventColor?)
    case text(
        MountViewSnapshot,
        text: String,
        attributes: TextAttributesSnapshot?)
    case image(
        MountViewSnapshot,
        source: String?)
    case other

    public var kind: MountComponentKind {
        switch self {
        case .root: .root
        case .view: .view
        case .text: .text
        case .image: .image
        case .other: .other
        }
    }

    var viewSnapshot: MountViewSnapshot? {
        switch self {
        case .root(let snapshot),
             .view(let snapshot, _),
             .text(let snapshot, _, _),
             .image(let snapshot, _):
            snapshot
        case .other:
            nil
        }
    }

    fileprivate var copiedBytes: MountCopiedBytes {
        var result = MountCopiedBytes()
        if let viewSnapshot {
            result.nativeID = UInt64(viewSnapshot.nativeID.utf8.count)
        }
        switch self {
        case .text(_, let text, _):
            result.text = UInt64(text.utf8.count)
        case .image(_, let source):
            result.image = UInt64(source?.utf8.count ?? 0)
        case .root, .view, .other:
            break
        }
        return result
    }
}

public enum MountEvent: Sendable {
    case create(
        surfaceID: Int,
        tag: Int,
        componentName: String?,
        component: MountComponentSnapshot)
    case delete(surfaceID: Int, tag: Int)
    case insert(
        surfaceID: Int,
        parentTag: Int,
        childTag: Int,
        index: Int)
    case remove(surfaceID: Int, childTag: Int)
    case update(
        surfaceID: Int,
        tag: Int,
        component: MountComponentSnapshot)

    public init(_ mutation: nucleus.react.MountMutation) {
        let surfaceID = Int(mutation.surfaceId)
        switch mutation.type {
        case .Create:
            let kind = MountComponentKind(
                mutation.componentKind)
            let componentName = String(mutation.componentName)
            self = .create(
                surfaceID: surfaceID,
                tag: Int(mutation.tag),
                componentName: kind.isCreatable ? componentName : nil,
                component: MountComponentSnapshot(
                    mutation, kind: kind))
        case .Delete:
            self = .delete(
                surfaceID: surfaceID,
                tag: Int(mutation.oldTag))
        case .Insert:
            self = .insert(
                surfaceID: surfaceID,
                parentTag: Int(mutation.parentTag),
                childTag: Int(mutation.newTag),
                index: Int(mutation.index))
        case .Remove:
            self = .remove(
                surfaceID: surfaceID,
                childTag: Int(mutation.oldTag))
        case .Update:
            self = .update(
                surfaceID: surfaceID,
                tag: Int(mutation.newTag),
                component: MountComponentSnapshot(
                    mutation,
                    kind: MountComponentKind(
                        mutation.componentKind)))
        @unknown default:
            self = .update(
                surfaceID: surfaceID,
                tag: Int(mutation.newTag),
                component: .other)
        }
    }

    public var surfaceID: Int {
        switch self {
        case .create(let surfaceID, _, _, _),
             .delete(let surfaceID, _),
             .insert(let surfaceID, _, _, _),
             .remove(let surfaceID, _),
             .update(let surfaceID, _, _):
            surfaceID
        }
    }

    fileprivate var copiedBytes: MountCopiedBytes {
        switch self {
        case .create(_, _, let componentName, let component):
            var result = component.copiedBytes
            result.componentName =
                UInt64(componentName?.utf8.count ?? 0)
            return result
        case .update(_, _, let component):
            return component.copiedBytes
        case .delete, .insert, .remove:
            return MountCopiedBytes()
        }
    }
}

private extension MountComponentSnapshot {
    init(
        _ mutation: nucleus.react.MountMutation,
        kind: MountComponentKind
    ) {
        guard kind != .other else {
            self = .other
            return
        }
        let view = MountViewSnapshot(
            nativeID: mutation.swiftNativeID,
            frame: mutation.swiftFrame)
        switch kind {
        case .root:
            self = .root(view)
        case .view:
            self = .view(
                view,
                backgroundColor: mutation.swiftBackgroundColor)
        case .text:
            self = .text(
                view,
                text: mutation.swiftText,
                attributes: mutation.textAttributes.value.map(
                    TextAttributesSnapshot.init))
        case .image:
            self = .image(
                view,
                source: mutation.swiftImageSource)
        case .other:
            self = .other
        }
    }
}

// Swift-native snapshot of `nucleus::react::TextAttributes`. Same
// rationale as `MountEvent` — the raw C++ struct doesn't surface in
// cross-module Swift API signatures.
public enum MountTextAlignment: Sendable { case natural, leading, center, trailing }
public enum MountLineBreakMode: Sendable { case clipping, truncatingTail, wordWrapping }

public struct TextAttributesSnapshot: Sendable {
    public let fontFamily: String
    public let fontSize: Float
    public let fontWeight: Int
    public let fontSlant: Int
    public let textColor: MountEventColor?
    public let lineHeight: Double
    public let alignment: MountTextAlignment
    public let maximumNumberOfLines: Int
    public let lineBreakMode: MountLineBreakMode

    public init(
        fontFamily: String,
        fontSize: Float,
        fontWeight: Int,
        fontSlant: Int,
        textColor: MountEventColor?,
        lineHeight: Double,
        alignment: MountTextAlignment,
        maximumNumberOfLines: Int,
        lineBreakMode: MountLineBreakMode
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontSlant = fontSlant
        self.textColor = textColor
        self.lineHeight = lineHeight
        self.alignment = alignment
        self.maximumNumberOfLines = maximumNumberOfLines
        self.lineBreakMode = lineBreakMode
    }

    init(_ attributes: nucleus.react.TextAttributes) {
        let alignment: MountTextAlignment
        switch attributes.alignment {
        case .Natural: alignment = .natural
        case .Leading: alignment = .leading
        case .Center: alignment = .center
        case .Trailing: alignment = .trailing
        @unknown default: alignment = .natural
        }
        let lineBreakMode: MountLineBreakMode
        switch attributes.lineBreakMode {
        case .Clipping: lineBreakMode = .clipping
        case .TruncatingTail: lineBreakMode = .truncatingTail
        case .WordWrapping: lineBreakMode = .wordWrapping
        @unknown default: lineBreakMode = .clipping
        }
        self.init(
            fontFamily: String(attributes.fontFamily),
            fontSize: attributes.fontSize,
            fontWeight: Int(attributes.fontWeight),
            fontSlant: Int(attributes.fontSlant),
            textColor: attributes.textColor.value.map {
                MountEventColor(
                    red: $0.red,
                    green: $0.green,
                    blue: $0.blue,
                    alpha: $0.alpha)
            },
            lineHeight: attributes.lineHeight,
            alignment: alignment,
            maximumNumberOfLines:
                Int(attributes.maximumNumberOfLines),
            lineBreakMode: lineBreakMode)
    }
}

// Per-surface materializer state. `attachSurface` registers the
// context before the consumer applies any events for that surface;
// the consumer routes incoming `didFinishTransaction` batches to the
// matching context's registry and rootView.
@MainActor
package final class MountSurfaceContext {
    let surfaceID: Int
    let rootView: View
    let registry: ViewComponentViewRegistry
    var environment: ReactSurfaceEnvironment
    var onMaterialize: ((ViewComponentViewRegistry) -> Void)?

    init(
        surfaceID: Int,
        rootView: View,
        registry: ViewComponentViewRegistry,
        environment: ReactSurfaceEnvironment
    ) {
        self.surfaceID = surfaceID
        self.rootView = rootView
        self.registry = registry
        self.environment = environment
    }
}

// Unified Fabric mount consumer. Implements `MountingObserverHandler`:
// the bridge buffers each mutation through `didMount`, and on
// `didFinishTransaction(surfaceID:)` the consumer materializes the
// batch against the registered surface context. Events that arrive
// after host surface registration but before a materializer context
// is attached stay buffered; `attachSurface` immediately flushes
// whatever has accumulated.
private struct MountCopiedBytes: Sendable {
    var componentName: UInt64 = 0
    var text: UInt64 = 0
    var nativeID: UInt64 = 0
    var image: UInt64 = 0
}

struct MountDrainMetrics: Sendable, Equatable {
    var completedBatchesQueued: UInt64 = 0
    var drainTasksScheduled: UInt64 = 0
    var batchesDrained: UInt64 = 0
    var mutationsMaterialized: UInt64 = 0
    var staleBatchesRejected: UInt64 = 0
    var copiedComponentNameBytes: UInt64 = 0
    var copiedTextBytes: UInt64 = 0
    var copiedNativeIDBytes: UInt64 = 0
    var copiedImageBytes: UInt64 = 0
    var lastBatchesDrainedPerTask: UInt64 = 0
}

struct MountBookkeepingCounts: Sendable, Equatable {
    var queuedBatches: Int
    var generations: Int
    var retiredSurfaces: Int
    var inFlightSurfaces: Int
}

typealias MountDrainOperation = @MainActor @Sendable () -> Void
typealias MountDrainScheduler =
    @Sendable (@escaping MountDrainOperation) -> Void

public final class MountConsumer: MountingObserverHandler, Sendable {
    private struct IncomingState: Sendable {
        var pending: [Int: [MountEvent]] = [:]
        var completedBatches: [CompletedBatch] = []
        var completedHead: Int = 0
        var drainScheduled = false
        var generations: [Int: UInt64] = [:]
        var activeSurfaces: Set<Int> = []
        var retiredSurfaces: Set<Int> = []
        var inFlightBatchCounts: [Int: Int] = [:]
        var metrics = MountDrainMetrics()
    }

    private struct CompletedBatch: Sendable {
        let surfaceID: Int
        let generation: UInt64
        let events: [MountEvent]
    }

    private let incoming = Mutex(IncomingState())
    private let scheduleDrain: MountDrainScheduler
    @MainActor private var pendingBySurface: [Int: [MountEvent]] = [:]
    @MainActor
    private var contextsBySurface: [Int: MountSurfaceContext] = [:]

    public convenience init() {
        self.init(scheduleDrain: { operation in
            Task { @MainActor in
                operation()
            }
        })
    }

    init(scheduleDrain: @escaping MountDrainScheduler) {
        self.scheduleDrain = scheduleDrain
    }

    // MARK: MountingObserverHandler

    public func didMount(_ mutation: nucleus.react.MountMutation) {
        enqueue(MountEvent(mutation))
    }

    public func didFinishTransaction(surfaceID: Int32) {
        let id = Int(surfaceID)
        let shouldSchedule = incoming.withLock { state in
            guard state.activeSurfaces.contains(id) else {
                state.pending.removeValue(forKey: id)
                state.metrics.staleBatchesRejected &+= 1
                return false
            }
            let batch = CompletedBatch(
                surfaceID: id,
                generation: state.generations[id, default: 0],
                events: state.pending.removeValue(forKey: id) ?? []
            )
            state.completedBatches.append(batch)
            state.inFlightBatchCounts[id, default: 0] += 1
            state.metrics.completedBatchesQueued &+= 1
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            state.metrics.drainTasksScheduled &+= 1
            return true
        }
        traceIncomingMetrics()
        guard shouldSchedule else { return }
        scheduleDrain { @MainActor [self] in
            drainCompletedBatches()
        }
    }

    func enqueue(_ event: MountEvent) {
        let accepted = incoming.withLock { state in
            guard
                state.activeSurfaces.contains(event.surfaceID),
                !state.retiredSurfaces.contains(event.surfaceID)
            else { return false }
            state.pending[event.surfaceID, default: []].append(event)
            let copied = event.copiedBytes
            state.metrics.copiedComponentNameBytes &+=
                copied.componentName
            state.metrics.copiedTextBytes &+= copied.text
            state.metrics.copiedNativeIDBytes &+= copied.nativeID
            state.metrics.copiedImageBytes &+= copied.image
            return true
        }
        if accepted {
            traceIncomingMetrics()
        }
    }

    // MARK: Materializer context lifecycle

    @MainActor
    package func registerSurface(surfaceID: Int) {
        incoming.withLock {
            $0.activeSurfaces.insert(surfaceID)
            $0.retiredSurfaces.remove(surfaceID)
        }
    }

    @MainActor
    package func registerContext(_ context: MountSurfaceContext) {
        registerSurface(surfaceID: context.surfaceID)
        contextsBySurface[context.surfaceID] = context
        flush(surfaceID: context.surfaceID)
    }

    @MainActor
    package func unregisterContext(surfaceID: Int) {
        incoming.withLock {
            $0.activeSurfaces.remove(surfaceID)
            $0.generations[surfaceID, default: 0] &+= 1
            $0.retiredSurfaces.insert(surfaceID)
            $0.pending.removeValue(forKey: surfaceID)
            Self.reclaimRetiredSurfaceIfIdle(
                surfaceID, state: &$0)
        }
        contextsBySurface.removeValue(forKey: surfaceID)
        pendingBySurface.removeValue(forKey: surfaceID)
    }

    @MainActor
    package func context(surfaceID: Int) -> MountSurfaceContext? {
        contextsBySurface[surfaceID]
    }

    @MainActor
    public func pendingCount(surfaceID: Int) -> UInt32 {
        UInt32(pendingBySurface[surfaceID]?.count ?? 0)
    }

    @MainActor
    public func pendingEvents(surfaceID: Int) -> [MountEvent] {
        pendingBySurface[surfaceID] ?? []
    }

    func metricsSnapshot() -> MountDrainMetrics {
        incoming.withLock { $0.metrics }
    }

    func bookkeepingCounts() -> MountBookkeepingCounts {
        incoming.withLock {
            MountBookkeepingCounts(
                queuedBatches:
                    $0.completedBatches.count
                    - $0.completedHead,
                generations: $0.generations.count,
                retiredSurfaces:
                    $0.retiredSurfaces.count,
                inFlightSurfaces:
                    $0.inFlightBatchCounts.count)
        }
    }

    func queuedBatchSurfaceIDs() -> [Int] {
        incoming.withLock {
            guard $0.completedHead < $0.completedBatches.count
            else { return [] }
            return $0.completedBatches[$0.completedHead...]
                .map(\.surfaceID)
        }
    }

    // MARK: Internal flush

    @MainActor
    private func flush(surfaceID: Int) {
        guard let context = contextsBySurface[surfaceID] else {
            // No materializer registered yet; events stay buffered for the
            // next attach.
            return
        }
        let events = pendingBySurface.removeValue(forKey: surfaceID) ?? []
        let registry = context.registry
        if registry.component(for: context.surfaceID) == nil {
            registry.register(
                ReactComponentViewFactory.root(tag: context.surfaceID, view: context.rootView)
            )
        }
        Trace.plot("swift.rn.mounting.events", UInt64(events.count))
        Trace.zone("rn.mounting.materialize", color: Trace.Color.yellow) {
            for event in events {
                apply(event, to: registry)
            }
        }
        context.onMaterialize?(registry)
    }

    @MainActor
    private func drainCompletedBatches() {
        var drainedThisTask: UInt64 = 0
        while true {
            let next = incoming.withLock {
                state -> (CompletedBatch, Bool)? in
                guard
                    state.completedHead
                        < state.completedBatches.count
                else {
                    state.completedBatches.removeAll(
                        keepingCapacity: true)
                    state.completedHead = 0
                    state.drainScheduled = false
                    state.metrics
                        .lastBatchesDrainedPerTask =
                        drainedThisTask
                    return nil
                }
                let batch =
                    state.completedBatches[
                        state.completedHead]
                state.completedHead += 1
                let current =
                    !state.retiredSurfaces.contains(
                        batch.surfaceID)
                    && state.generations[
                        batch.surfaceID,
                        default: 0] == batch.generation
                return (batch, current)
            }
            guard let (batch, isCurrent) = next else {
                Trace.plot(
                    "swift.rn.mounting.batches_per_drain",
                    drainedThisTask)
                traceIncomingMetrics()
                return
            }
            if isCurrent {
                pendingBySurface[
                    batch.surfaceID,
                    default: []
                ].append(contentsOf: batch.events)
                flush(surfaceID: batch.surfaceID)
            }
            drainedThisTask &+= 1
            incoming.withLock { state in
                state.metrics.batchesDrained &+= 1
                if isCurrent {
                    state.metrics
                        .mutationsMaterialized &+=
                        UInt64(batch.events.count)
                } else {
                    state.metrics
                        .staleBatchesRejected &+= 1
                }
                if let count = state.inFlightBatchCounts[
                    batch.surfaceID]
                {
                    if count <= 1 {
                        state.inFlightBatchCounts.removeValue(
                            forKey: batch.surfaceID)
                    } else {
                        state.inFlightBatchCounts[
                            batch.surfaceID] = count - 1
                    }
                }
                Self.reclaimRetiredSurfaceIfIdle(
                    batch.surfaceID,
                    state: &state)
            }
        }
    }

    private static func reclaimRetiredSurfaceIfIdle(
        _ surfaceID: Int,
        state: inout IncomingState
    ) {
        guard
            !state.activeSurfaces.contains(surfaceID),
            state.retiredSurfaces.contains(surfaceID),
            state.inFlightBatchCounts[surfaceID] == nil,
            state.pending[surfaceID] == nil
        else { return }
        state.retiredSurfaces.remove(surfaceID)
        state.generations.removeValue(forKey: surfaceID)
    }

    private func traceIncomingMetrics() {
        let metrics = metricsSnapshot()
        Trace.plot(
            "swift.rn.mounting.completed_batches_queued",
            metrics.completedBatchesQueued)
        Trace.plot(
            "swift.rn.mounting.drain_tasks_scheduled",
            metrics.drainTasksScheduled)
        Trace.plot(
            "swift.rn.mounting.batches_drained",
            metrics.batchesDrained)
        Trace.plot(
            "swift.rn.mounting.mutations_materialized",
            metrics.mutationsMaterialized)
        Trace.plot(
            "swift.rn.mounting.stale_batches_rejected",
            metrics.staleBatchesRejected)
        Trace.plot(
            "swift.rn.mounting.copied_text_bytes",
            metrics.copiedTextBytes)
        Trace.plot(
            "swift.rn.mounting.copied_native_id_bytes",
            metrics.copiedNativeIDBytes)
        Trace.plot(
            "swift.rn.mounting.copied_image_bytes",
            metrics.copiedImageBytes)
    }

    @MainActor
    private func apply(_ event: MountEvent, to registry: ViewComponentViewRegistry) {
        switch event {
        case .create(
            _, let tag, let componentName,
            let snapshot):
            guard
                snapshot.kind.isCreatable,
                let componentName
            else { return }
            let component = ReactComponentViewFactory.make(
                tag: tag,
                componentName: componentName,
                snapshot: snapshot)
            component.apply(snapshot)
            registry.register(component)
        case .insert(
            _, let parentTag, let childTag, let index):
            guard
                let child = registry.component(for: childTag),
                let parent = registry.component(for: parentTag)
            else {
                return
            }
            parent.view.insertSubview(child.view, at: index)
        case .update(_, let tag, let snapshot):
            if let child = registry.component(for: tag),
               snapshot.kind != .other
            {
                child.apply(snapshot)
            }
        case .remove(_, let childTag):
            if let child = registry.component(for: childTag) {
                child.view.removeFromSuperview()
            }
        case .delete(_, let tag):
            registry.unregister(tag: tag)
        }
    }
}

public struct MountEventColor: Sendable, Equatable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
}

private extension nucleus.react.MountMutation {
    var swiftFrame: Rect {
        Rect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    var swiftBackgroundColor: MountEventColor? {
        guard let color = backgroundColor.value else { return nil }
        return MountEventColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }

    var swiftNativeID: String {
        guard let id = nativeId.value else { return "" }
        return String(id)
    }

    var swiftText: String {
        guard let value = text.value else { return "" }
        return String(value)
    }

    var swiftImageSource: String? {
        guard let value = imageSource.value else { return nil }
        let resolved = String(value)
        return resolved.isEmpty ? nil : resolved
    }

}

@MainActor
public final class ViewComponentViewRegistry {
    private var componentsByTag: [Int: any ReactComponentView] = [:]

    public init() {}

    public var components: [any ReactComponentView] {
        componentsByTag.values.sorted { $0.tag < $1.tag }
    }

    public func component(for tag: Int) -> (any ReactComponentView)? {
        componentsByTag[tag]
    }

    func register(_ componentView: any ReactComponentView) {
        componentsByTag[componentView.tag] = componentView
    }

    func unregister(tag: Int) {
        componentsByTag.removeValue(forKey: tag)
    }
}

@MainActor
public struct ReactSurfaceEnvironment: Sendable, Equatable {
    public var backingScaleFactor: BackingScaleFactor

    public init(
        backingScaleFactor: BackingScaleFactor = .one
    ) {
        self.backingScaleFactor = backingScaleFactor
    }
}

@MainActor
public protocol ReactComponentView: AnyObject {
    var tag: Int { get }
    var componentName: String { get }
    var nativeID: String { get }
    var view: View { get }

    func apply(_ snapshot: MountComponentSnapshot)
    func updateEnvironment(_ environment: ReactSurfaceEnvironment)
}

@MainActor
public class ReactBaseComponentView: ReactComponentView {
    public let tag: Int
    public let componentName: String
    public private(set) var nativeID: String
    public let view: View
    var environment: ReactSurfaceEnvironment

    init(
        tag: Int,
        componentName: String,
        nativeID: String,
        view: View
    ) {
        self.tag = tag
        self.componentName = componentName
        self.nativeID = nativeID
        self.view = view
        self.environment = ReactSurfaceEnvironment()
    }

    public func apply(_ snapshot: MountComponentSnapshot) {
        guard let snapshot = snapshot.viewSnapshot else { return }
        nativeID = snapshot.nativeID
        view.frame = snapshot.frame
    }

    public func updateEnvironment(_ environment: ReactSurfaceEnvironment) {
        self.environment = environment
    }

}

@MainActor
public final class ReactRootComponentView: ReactBaseComponentView {
    init(tag: Int, view: View) {
        super.init(tag: tag, componentName: "RootView", nativeID: "", view: view)
    }
}

@MainActor
public final class ReactViewComponentView: ReactBaseComponentView {
    public override func apply(_ snapshot: MountComponentSnapshot) {
        super.apply(snapshot)
        guard case .view(_, let backgroundColor) = snapshot
        else { return }
        if let color = backgroundColor {
            view.backgroundColor = Color(color.red, color.green, color.blue, color.alpha)
        } else {
            view.backgroundColor = nil
        }
    }
}

@MainActor
public final class ReactParagraphComponentView: ReactBaseComponentView {
    /// The same object as `view`, held typed so text can be applied to it.
    private let paragraphView: ReactParagraphView

    init(tag: Int, componentName: String, nativeID: String, paragraphView: ReactParagraphView) {
        self.paragraphView = paragraphView
        super.init(
            tag: tag, componentName: componentName, nativeID: nativeID, view: paragraphView)
    }

    public override func apply(_ snapshot: MountComponentSnapshot) {
        super.apply(snapshot)
        guard case .text(_, let text, let attributes) = snapshot
        else { return }
        paragraphView.applyText(text, attributes: attributes)
        let aligned = pixelAlignedEnclosing(view.frame, scale: environment.backingScaleFactor)
        if aligned != view.frame {
            view.frame = aligned
        }
    }

    public override func updateEnvironment(_ environment: ReactSurfaceEnvironment) {
        super.updateEnvironment(environment)
        let aligned = pixelAlignedEnclosing(view.frame, scale: environment.backingScaleFactor)
        if aligned != view.frame {
            view.frame = aligned
        }
    }

}

@MainActor
public enum ReactComponentViewFactory {
    static func root(tag: Int, view: View) -> any ReactComponentView {
        ReactRootComponentView(tag: tag, view: view)
    }

    static func make(
        tag: Int,
        componentName: String,
        snapshot: MountComponentSnapshot
    ) -> any ReactComponentView {
        if snapshot.kind == .image {
            return ReactImageComponentView(
                tag: tag,
                componentName: componentName,
                nativeID:
                    snapshot.viewSnapshot?.nativeID ?? "",
                imageView: ImageView()
            )
        }
        if snapshot.kind == .text {
            return ReactParagraphComponentView(
                tag: tag,
                componentName: componentName,
                nativeID:
                    snapshot.viewSnapshot?.nativeID ?? "",
                paragraphView: ReactParagraphView()
            )
        }
        return ReactViewComponentView(
            tag: tag,
            componentName: componentName,
            nativeID:
                snapshot.viewSnapshot?.nativeID ?? "",
            view: View()
        )
    }
}

private func pixelAlignedEnclosing(_ rect: Rect, scale: BackingScaleFactor) -> Rect {
    let pixelsPerPoint = Swift.max(Double(scale.backingPixelsPerPoint), 1)
    let minX = (rect.origin.x * pixelsPerPoint).rounded(.down) / pixelsPerPoint
    let minY = (rect.origin.y * pixelsPerPoint).rounded(.down) / pixelsPerPoint
    let maxX = ((rect.origin.x + rect.size.width) * pixelsPerPoint).rounded(.up) / pixelsPerPoint
    let maxY = ((rect.origin.y + rect.size.height) * pixelsPerPoint).rounded(.up) / pixelsPerPoint
    return Rect(
        x: minX,
        y: minY,
        width: Swift.max(0, maxX - minX),
        height: Swift.max(0, maxY - minY)
    )
}
