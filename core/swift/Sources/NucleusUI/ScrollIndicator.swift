public enum ScrollAxis: Sendable, Equatable {
    case horizontal
    case vertical
}

public enum ScrollIndicatorVisibilityPolicy: Sendable, Equatable {
    case automatic
    case always
    case whileScrolling
    case never
}

/// A retained, interactive scroll indicator.
@MainActor
public final class ScrollIndicator: View, ~Sendable {
    public let axis: ScrollAxis
    public private(set) var thumbRect: Rect = .zero

    package var onDragProgress: ((Double) -> Void)?
    package var onPage: ((Int) -> Void)?
    package var onBeginInteraction: (() -> Void)?
    package var onEndInteraction: (() -> Void)?

    private var dragAnchor: Double?

    package init(axis: ScrollAxis) {
        self.axis = axis
        super.init()
    }

    package func setThumbRect(_ rect: Rect) {
        guard rect != thumbRect else { return }
        thumbRect = rect
        setNeedsDisplay()
    }

    public override func draw(in context: GraphicsContext) {
        guard !thumbRect.isEmpty else { return }
        var path = Path()
        let radius = min(thumbRect.size.width, thumbRect.size.height) / 2
        path.addRoundedRect(thumbRect, radius: radius)
        context.fillColor = resolve(.role(.outline)).opacity(0.56)
        context.fill(path)
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        let coordinate = axis == .vertical ? event.location.y : event.location.x
        let thumbOrigin = axis == .vertical
            ? thumbRect.origin.y
            : thumbRect.origin.x
        let thumbLength = axis == .vertical
            ? thumbRect.size.height
            : thumbRect.size.width
        let trackLength = axis == .vertical
            ? bounds.size.height
            : bounds.size.width

        switch event.type {
        case .pointerDown:
            onBeginInteraction?()
            if thumbRect.contains(event.location) {
                dragAnchor = coordinate - thumbOrigin
            } else {
                onPage?(coordinate < thumbOrigin ? -1 : 1)
                onEndInteraction?()
            }
            return .handled
        case .pointerDragged:
            guard let dragAnchor else { return .notHandled }
            let travel = max(0, trackLength - thumbLength)
            let progress = travel > 0
                ? min(max(0, (coordinate - dragAnchor) / travel), 1)
                : 0
            onDragProgress?(progress)
            return .handled
        case .pointerUp:
            let wasDragging = dragAnchor != nil
            dragAnchor = nil
            if wasDragging { onEndInteraction?() }
            return wasDragging ? .handled : .notHandled
        case .pointerExited:
            return dragAnchor == nil ? .notHandled : .handled
        default:
            return .notHandled
        }
    }
}
