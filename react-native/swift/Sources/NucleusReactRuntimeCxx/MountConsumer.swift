import CxxStdlib
import NucleusUI
import NucleusUIEmbedder
import NucleusReactRuntimeCxxBridge
import Synchronization
import Tracy

// Swift-native wrapper around `nucleus::react::MountMutation`. The
// raw C++ struct cannot appear in cross-module Swift API signatures
// — Swift's C++ interop emits the method but does not expose it to
// importers of the resulting `.swiftmodule`, so callers in other
// Swift modules see "no member" errors. Wrapping in a Swift struct
// gives Swift a native type to put in public signatures while
// preserving zero-copy access to the underlying C++ value (struct
// stores by value).
public enum MountEventType: Sendable { case create, delete, insert, remove, update }
public enum MountComponentKind: Sendable { case view, text, image, other }

public struct MountEvent: Sendable {
    public let type: MountEventType
    public let surfaceID: Int
    public let tag: Int
    public let parentTag: Int
    public let oldTag: Int
    public let newTag: Int
    public let index: Int
    public let componentName: String
    public let nativeID: String
    public let frame: Rect
    public let backgroundColor: MountEventColor?
    public let text: String
    public let textAttributes: TextAttributesSnapshot?
    public let imageSource: String?
    public let componentKind: MountComponentKind

    public init(_ mutation: nucleus.react.MountMutation) {
        switch mutation.type {
        case .Create: type = .create
        case .Delete: type = .delete
        case .Insert: type = .insert
        case .Remove: type = .remove
        case .Update: type = .update
        @unknown default: type = .update
        }
        surfaceID = Int(mutation.surfaceId)
        tag = Int(mutation.tag)
        parentTag = Int(mutation.parentTag)
        oldTag = Int(mutation.oldTag)
        newTag = Int(mutation.newTag)
        index = Int(mutation.index)
        componentName = String(mutation.componentName)
        nativeID = mutation.swiftNativeID
        frame = mutation.swiftFrame
        backgroundColor = mutation.swiftBackgroundColor
        text = mutation.swiftText
        textAttributes = mutation.textAttributes.value.map(TextAttributesSnapshot.init)
        imageSource = mutation.swiftImageSource
        switch componentName {
        case "Image", "RCTImage": componentKind = .image
        case "Paragraph", "RCTParagraph", "Text", "RCTText", "RawText", "RCTRawText": componentKind = .text
        case "RCTView", "View": componentKind = .view
        default: componentKind = .other
        }
    }

    public var isViewComponent: Bool { componentKind != .other }
    public var isMaterializedComponentUpdate: Bool { componentName == "RootView" || isViewComponent }
    public var isTextContentComponent: Bool { componentKind == .text }
    public var isImageComponent: Bool { componentKind == .image }
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

    init(_ attributes: nucleus.react.TextAttributes) {
        fontFamily = String(attributes.fontFamily)
        fontSize = attributes.fontSize
        fontWeight = Int(attributes.fontWeight)
        fontSlant = Int(attributes.fontSlant)
        textColor = attributes.textColor.value.map { MountEventColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) }
        lineHeight = attributes.lineHeight
        switch attributes.alignment {
        case .Natural: alignment = .natural
        case .Leading: alignment = .leading
        case .Center: alignment = .center
        case .Trailing: alignment = .trailing
        @unknown default: alignment = .natural
        }
        maximumNumberOfLines = Int(attributes.maximumNumberOfLines)
        switch attributes.lineBreakMode {
        case .Clipping: lineBreakMode = .clipping
        case .TruncatingTail: lineBreakMode = .truncatingTail
        case .WordWrapping: lineBreakMode = .wordWrapping
        @unknown default: lineBreakMode = .clipping
        }
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
// before a context is registered (i.e. before `attachSurface` runs)
// stay buffered; the next `attachSurface` triggers an immediate
// materialize against whatever has accumulated.
public final class MountConsumer: MountingObserverHandler, Sendable {
    private struct IncomingState: Sendable {
        var pending: [Int: [MountEvent]] = [:]
        var generations: [Int: UInt64] = [:]
        var retiredSurfaces: Set<Int> = []
        var nextSequence: UInt64 = 0
    }

    private struct CompletedBatch: Sendable {
        let surfaceID: Int
        let generation: UInt64
        let events: [MountEvent]
    }

    private let incoming = Mutex(IncomingState())
    @MainActor private var pendingBySurface: [Int: [MountEvent]] = [:]
    @MainActor
    private var contextsBySurface: [Int: MountSurfaceContext] = [:]
    @MainActor private var nextAcceptedSequence: UInt64 = 0
    @MainActor private var completedBatches: [UInt64: CompletedBatch] = [:]

    public init() {}

    // MARK: MountingObserverHandler

    public func didMount(_ mutation: nucleus.react.MountMutation) {
        let event = MountEvent(mutation)
        incoming.withLock {
            guard !$0.retiredSurfaces.contains(event.surfaceID) else { return }
            $0.pending[event.surfaceID, default: []].append(event)
        }
    }

    public func didFinishTransaction(surfaceID: Int32) {
        let id = Int(surfaceID)
        let (sequence, batch) = incoming.withLock { state in
            let sequence = state.nextSequence
            state.nextSequence &+= 1
            return (sequence, CompletedBatch(
                surfaceID: id,
                generation: state.generations[id, default: 0],
                events: state.pending.removeValue(forKey: id) ?? []
            ))
        }
        Task { @MainActor [self] in
            accept(batch, sequence: sequence)
        }
    }

    // MARK: Materializer context lifecycle

    @MainActor
    package func registerContext(_ context: MountSurfaceContext) {
        _ = incoming.withLock { $0.retiredSurfaces.remove(context.surfaceID) }
        contextsBySurface[context.surfaceID] = context
        flush(surfaceID: context.surfaceID)
    }

    @MainActor
    package func unregisterContext(surfaceID: Int) {
        incoming.withLock {
            $0.generations[surfaceID, default: 0] &+= 1
            $0.retiredSurfaces.insert(surfaceID)
            $0.pending.removeValue(forKey: surfaceID)
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
    private func accept(_ batch: CompletedBatch, sequence: UInt64) {
        completedBatches[sequence] = batch
        while let next = completedBatches.removeValue(forKey: nextAcceptedSequence) {
            let isCurrent = incoming.withLock {
                $0.generations[next.surfaceID, default: 0] == next.generation
            }
            if isCurrent {
                pendingBySurface[next.surfaceID, default: []].append(contentsOf: next.events)
                flush(surfaceID: next.surfaceID)
            }
            nextAcceptedSequence &+= 1
        }
    }

    @MainActor
    private func apply(_ event: MountEvent, to registry: ViewComponentViewRegistry) {
        switch event.type {
        case .create:
            guard event.isViewComponent else { return }
            do {
                let component = try ReactComponentViewFactory.make(event: event)
                component.apply(event)
                registry.register(component)
            } catch {
                return
            }
        case .insert:
            guard let child = registry.component(for: event.newTag),
                  let parent = registry.component(for: event.parentTag) else {
                return
            }
            parent.view.addSubview(child.view)
            child.apply(event)
        case .update:
            if let child = registry.component(for: event.newTag),
               event.isMaterializedComponentUpdate {
                child.apply(event)
            }
        case .remove:
            if let child = registry.component(for: event.oldTag) {
                child.view.removeFromSuperview()
            }
        case .delete:
            registry.unregister(tag: event.oldTag)
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
    public var layoutDirection: nucleus.react.LayoutDirection

    public init(
        backingScaleFactor: BackingScaleFactor = .one,
        layoutDirection: nucleus.react.LayoutDirection = .Undefined
    ) {
        self.backingScaleFactor = backingScaleFactor
        self.layoutDirection = layoutDirection
    }
}

@MainActor
public protocol ReactComponentView: AnyObject {
    var tag: Int { get }
    var componentName: String { get }
    var nativeID: String { get }
    var view: View { get }

    func apply(_ event: MountEvent)
    func updateEnvironment(_ environment: ReactSurfaceEnvironment)
    func commitDisplayContentIfNeeded() throws
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

    public func apply(_ event: MountEvent) {
        nativeID = event.nativeID
        view.frame = event.frame
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
    public override func apply(_ event: MountEvent) {
        super.apply(event)
        if let color = event.backgroundColor {
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

    public override func apply(_ event: MountEvent) {
        super.apply(event)
        paragraphView.applyText(event.text, attributes: event.textAttributes)
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

    static func make(event: MountEvent) throws -> any ReactComponentView {
        if event.isImageComponent {
            return ReactImageComponentView(
                tag: event.tag,
                componentName: event.componentName,
                nativeID: event.nativeID,
                imageView: ImageView()
            )
        }
        if event.isTextContentComponent {
            return ReactParagraphComponentView(
                tag: event.tag,
                componentName: event.componentName,
                nativeID: event.nativeID,
                paragraphView: ReactParagraphView()
            )
        }
        return ReactViewComponentView(
            tag: event.tag,
            componentName: event.componentName,
            nativeID: event.nativeID,
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
