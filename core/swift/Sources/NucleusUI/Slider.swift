@MainActor
open class Slider: Control, ~Sendable {
    private var storedMinimumValue = 0.0
    private var storedMaximumValue = 1.0
    private var storedValue = 0.0
    private var storedStep: Double?

    public var minimumValue: Double {
        get { storedMinimumValue }
        set {
            let value = newValue.isFinite ? newValue : 0
            guard value != storedMinimumValue else { return }
            storedMinimumValue = value
            if storedMaximumValue < value { storedMaximumValue = value }
            self.value = storedValue
            setNeedsDisplay()
        }
    }

    public var maximumValue: Double {
        get { storedMaximumValue }
        set {
            let value = newValue.isFinite
                ? max(storedMinimumValue, newValue)
                : storedMinimumValue
            guard value != storedMaximumValue else { return }
            storedMaximumValue = value
            self.value = storedValue
            setNeedsDisplay()
        }
    }

    public var value: Double {
        get { storedValue }
        set {
            let finite = newValue.isFinite ? newValue : storedMinimumValue
            var resolved = min(max(storedMinimumValue, finite), storedMaximumValue)
            if let step = storedStep, step > 0 {
                resolved = storedMinimumValue
                    + ((resolved - storedMinimumValue) / step).rounded() * step
                resolved = min(max(storedMinimumValue, resolved), storedMaximumValue)
            }
            guard resolved != storedValue else { return }
            storedValue = resolved
            accessibilityValue = String(resolved)
            onValueChange?(resolved)
            setNeedsDisplay()
        }
    }

    public var step: Double? {
        get { storedStep }
        set {
            let value = newValue.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            guard value != storedStep else { return }
            storedStep = value
            self.value = storedValue
        }
    }

    private var onValueChange: ((Double) -> Void)?
    private static let thumbDiameter = 16.0

    public override init() {
        super.init()
        accessibilityRole = .slider
        accessibilityValue = "0.0"
    }

    public func onChange(_ handler: @escaping (Double) -> Void) {
        onValueChange = handler
    }

    public override var intrinsicContentSize: Size {
        Size(width: 120, height: 24)
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        switch event.type {
        case .pointerDown, .touchDown:
            updateValue(at: event.location)
        case .pointerDragged, .touchMoved:
            guard isPressed else { return .notHandled }
            updateValue(at: event.location)
        case .keyDown:
            let increment = step ?? max(
                (maximumValue - minimumValue) / 100,
                Double.ulpOfOne)
            switch event.keyCode {
            case .leftArrow, .downArrow:
                value -= increment
                return .handled
            case .rightArrow, .upArrow:
                value += increment
                return .handled
            case .home:
                value = minimumValue
                return .handled
            case .end:
                value = maximumValue
                return .handled
            default:
                break
            }
        default:
            break
        }
        return super.handleEvent(event)
    }

    public override func draw(in context: GraphicsContext) {
        let trackY = bounds.size.height / 2 - 2
        let track = Rect(x: 0, y: trackY, width: bounds.size.width, height: 4)
        var trackPath = Path()
        trackPath.addRoundedRect(track, radius: 2)
        context.fillColor = resolve(.role(.surfaceVariant))
        context.fill(trackPath)

        let x = bounds.size.width * normalizedValue
        var fill = Path()
        fill.addRoundedRect(
            Rect(x: 0, y: trackY, width: x, height: 4),
            radius: 2)
        context.fillColor = resolve(.role(.primary))
        context.fill(fill)

        var thumb = Path()
        thumb.addEllipse(in: Rect(
            x: x - Slider.thumbDiameter / 2,
            y: bounds.size.height / 2 - Slider.thumbDiameter / 2,
            width: Slider.thumbDiameter,
            height: Slider.thumbDiameter))
        context.fillColor = resolve(.role(.onSurface))
        context.fill(thumb)
    }

    package var normalizedValue: Double {
        let range = maximumValue - minimumValue
        return range > 0 ? (value - minimumValue) / range : 0
    }

    private func updateValue(at point: Point) {
        let progress = bounds.size.width > 0
            ? min(max(0, point.x / bounds.size.width), 1)
            : 0
        value = minimumValue + (maximumValue - minimumValue) * progress
    }
}

@MainActor
public final class RangeSlider: Control, ~Sendable {
    private var storedMinimumValue = 0.0
    private var storedMaximumValue = 1.0
    private var storedLowerValue = 0.0
    private var storedUpperValue = 1.0
    private var storedStep: Double?

    public var minimumValue: Double {
        get { storedMinimumValue }
        set {
            let minimum = newValue.isFinite ? newValue : 0
            applyValues(
                minimum: minimum,
                maximum: max(minimum, storedMaximumValue),
                lower: storedLowerValue,
                upper: storedUpperValue)
        }
    }

    public var maximumValue: Double {
        get { storedMaximumValue }
        set {
            let maximum = newValue.isFinite
                ? max(storedMinimumValue, newValue)
                : storedMinimumValue
            applyValues(
                minimum: storedMinimumValue,
                maximum: maximum,
                lower: storedLowerValue,
                upper: storedUpperValue)
        }
    }

    public var lowerValue: Double {
        get { storedLowerValue }
        set {
            let lower = quantized(newValue)
            applyValues(
                minimum: storedMinimumValue,
                maximum: storedMaximumValue,
                lower: lower,
                upper: max(lower, storedUpperValue))
        }
    }

    public var upperValue: Double {
        get { storedUpperValue }
        set {
            let upper = quantized(newValue)
            applyValues(
                minimum: storedMinimumValue,
                maximum: storedMaximumValue,
                lower: min(storedLowerValue, upper),
                upper: upper)
        }
    }

    public var step: Double? {
        get { storedStep }
        set {
            let next = newValue.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            }
            guard next != storedStep else { return }
            storedStep = next
            applyValues(
                minimum: storedMinimumValue,
                maximum: storedMaximumValue,
                lower: storedLowerValue,
                upper: storedUpperValue,
                forceDisplay: true)
        }
    }

    private enum ActiveThumb { case lower, upper }
    private var activeThumb: ActiveThumb?
    private var onValueChange: ((ClosedRange<Double>) -> Void)?
    private let lowerAccessibilityID: AccessibilityID
    private let upperAccessibilityID: AccessibilityID

    public override init() {
        let context = Application.currentUIContext
        lowerAccessibilityID = context.allocateAccessibilityID()
        upperAccessibilityID = context.allocateAccessibilityID()
        super.init()
        accessibilityRole = .rangeSlider
        accessibilityVirtualChildrenProvider = { [weak self] in
            self?.accessibilityThumbs() ?? []
        }
        synchronizeAccessibilityValue()
    }

    public func onChange(
        _ handler: @escaping (ClosedRange<Double>) -> Void
    ) {
        onValueChange = handler
    }

    public override var intrinsicContentSize: Size {
        Size(width: 120, height: 24)
    }

    public override func handleEvent(_ event: Event) -> EventHandling {
        switch event.type {
        case .pointerDown, .touchDown:
            activeThumb = nearestThumb(to: event.location.x)
            updateActiveThumb(at: event.location.x)
        case .pointerDragged, .touchMoved:
            guard isPressed, activeThumb != nil else { return .notHandled }
            updateActiveThumb(at: event.location.x)
        case .pointerUp, .touchUp, .pointerCancelled, .touchCancelled:
            activeThumb = nil
        case .keyDown:
            let amount = canonicalStep
            switch event.keyCode {
            case .leftArrow, .downArrow:
                lowerValue -= amount
                return .handled
            case .rightArrow, .upArrow:
                upperValue += amount
                return .handled
            default:
                break
            }
        default:
            break
        }
        return super.handleEvent(event)
    }

    public override func draw(in context: GraphicsContext) {
        let width = bounds.size.width
        let lowerX = width * normalized(lowerValue)
        let upperX = width * normalized(upperValue)
        let y = bounds.size.height / 2
        context.fillColor = resolve(.role(.surfaceVariant))
        context.fill(Rect(x: 0, y: y - 2, width: width, height: 4))
        context.fillColor = resolve(.role(.primary))
        context.fill(Rect(
            x: lowerX,
            y: y - 2,
            width: max(0, upperX - lowerX),
            height: 4))
        for x in [lowerX, upperX] {
            var thumb = Path()
            thumb.addEllipse(in: Rect(x: x - 8, y: y - 8, width: 16, height: 16))
            context.fillColor = resolve(.role(.onSurface))
            context.fill(thumb)
        }
    }

    private var canonicalStep: Double {
        if let step, step.isFinite, step > 0 { return step }
        return max((maximumValue - minimumValue) / 100, Double.ulpOfOne)
    }

    private func accessibilityThumbs() -> [AccessibilityVirtualElement] {
        let thumbSize = 24.0
        let centerY = bounds.size.height / 2
        func frame(for value: Double) -> Rect {
            Rect(
                x: bounds.size.width * normalized(value) - thumbSize / 2,
                y: centerY - thumbSize / 2,
                width: thumbSize,
                height: thumbSize)
        }
        func properties(
            label: String,
            current: Double
        ) -> AccessibilityProperties {
            AccessibilityProperties(
                isElement: true,
                label: label,
                value: String(current),
                role: .slider,
                orientation: .horizontal,
                rangeValue: AccessibilityRangeValue(
                    minimum: minimumValue,
                    maximum: maximumValue,
                    current: current,
                    increment: step))
        }
        return [
            AccessibilityVirtualElement(
                id: lowerAccessibilityID,
                properties: properties(
                    label: "Lower value",
                    current: lowerValue),
                frame: frame(for: lowerValue),
                actions: [.focus, .increment, .decrement, .setValue],
                performAction: { [weak self] request in
                    self?.performAccessibilityThumbAction(
                        request,
                        thumb: .lower) ?? false
                }),
            AccessibilityVirtualElement(
                id: upperAccessibilityID,
                properties: properties(
                    label: "Upper value",
                    current: upperValue),
                frame: frame(for: upperValue),
                actions: [.focus, .increment, .decrement, .setValue],
                performAction: { [weak self] request in
                    self?.performAccessibilityThumbAction(
                        request,
                        thumb: .upper) ?? false
                }),
        ]
    }

    private func performAccessibilityThumbAction(
        _ request: AccessibilityActionRequest,
        thumb: ActiveThumb
    ) -> Bool {
        switch request.action {
        case .focus:
            return window?.makeFirstResponder(self) == true
        case .increment:
            if thumb == .lower {
                lowerValue += canonicalStep
            } else {
                upperValue += canonicalStep
            }
            return true
        case .decrement:
            if thumb == .lower {
                lowerValue -= canonicalStep
            } else {
                upperValue -= canonicalStep
            }
            return true
        case .setValue:
            guard let value = request.value else { return false }
            if thumb == .lower {
                lowerValue = value
            } else {
                upperValue = value
            }
            return true
        default:
            return false
        }
    }

    private func applyValues(
        minimum: Double,
        maximum: Double,
        lower: Double,
        upper: Double,
        forceDisplay: Bool = false
    ) {
        let boundedMaximum = max(minimum, maximum)
        var nextLower = min(max(minimum, lower), boundedMaximum)
        var nextUpper = min(max(minimum, upper), boundedMaximum)
        nextLower = quantized(
            nextLower,
            minimum: minimum,
            maximum: boundedMaximum)
        nextUpper = quantized(
            nextUpper,
            minimum: minimum,
            maximum: boundedMaximum)
        if nextLower > nextUpper {
            nextUpper = nextLower
        }

        let boundsChanged = minimum != storedMinimumValue
            || boundedMaximum != storedMaximumValue
        let valueChanged = nextLower != storedLowerValue
            || nextUpper != storedUpperValue
        guard boundsChanged || valueChanged || forceDisplay else { return }

        storedMinimumValue = minimum
        storedMaximumValue = boundedMaximum
        storedLowerValue = nextLower
        storedUpperValue = nextUpper
        synchronizeAccessibilityValue()
        if valueChanged {
            onValueChange?(nextLower...nextUpper)
        }
        setNeedsDisplay()
    }

    private func quantized(
        _ value: Double,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> Double {
        let minimum = minimum ?? storedMinimumValue
        let maximum = maximum ?? storedMaximumValue
        let finite = value.isFinite ? value : minimum
        var result = min(max(minimum, finite), maximum)
        if let step = storedStep {
            result = minimum + ((result - minimum) / step).rounded() * step
            result = min(max(minimum, result), maximum)
        }
        return result
    }

    private func synchronizeAccessibilityValue() {
        accessibilityValue = "\(storedLowerValue)–\(storedUpperValue)"
    }

    private func normalized(_ value: Double) -> Double {
        let range = maximumValue - minimumValue
        return range > 0 ? (value - minimumValue) / range : 0
    }

    private func nearestThumb(to x: Double) -> ActiveThumb {
        let lowerX = bounds.size.width * normalized(lowerValue)
        let upperX = bounds.size.width * normalized(upperValue)
        return abs(x - lowerX) <= abs(x - upperX) ? .lower : .upper
    }

    private func updateActiveThumb(at x: Double) {
        guard let activeThumb else { return }
        let progress = bounds.size.width > 0
            ? min(max(0, x / bounds.size.width), 1)
            : 0
        let proposed = minimumValue + (maximumValue - minimumValue) * progress
        switch activeThumb {
        case .lower: lowerValue = min(proposed, upperValue)
        case .upper: upperValue = max(proposed, lowerValue)
        }
    }
}
