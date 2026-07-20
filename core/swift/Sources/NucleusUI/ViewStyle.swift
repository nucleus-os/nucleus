public struct Border: Sendable, Equatable {
    public var width: Float
    public var color: Color

    public init(width: Float = 0, color: Color = Color(0, 0, 0, 0)) {
        self.width = width.isFinite ? max(0, width) : 0
        self.color = color
    }

    public static let none = Border()
}

public struct ViewStyle: Sendable, Equatable {
    public var backgroundColor: Color?
    public var cornerRadius: Double
    public var border: Border

    public init(
        backgroundColor: Color? = nil,
        cornerRadius: Double = 0,
        border: Border = .none
    ) {
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius.isFinite ? max(0, cornerRadius) : 0
        self.border = border
    }

    public static let none = ViewStyle()
}

extension ViewStyle {
    /// Paint the styled background and border. Invoked by `displayIfNeeded`
    /// *before* `View.draw(in:)`, so a subclass draws on top of its style.
    @MainActor
    package func draw(in context: GraphicsContext, bounds: Rect) {
        let width = max(0, bounds.size.width)
        let height = max(0, bounds.size.height)
        guard width > 0, height > 0 else { return }

        if let color = backgroundColor {
            context.fillRect(
                Rect(x: 0, y: 0, width: width, height: height),
                color: color,
                cornerRadius: cornerRadius)
        }

        if border.width > 0 {
            // Inset by half the stroke so the stroke lands inside `bounds`
            // rather than straddling its edge. This now emits an actual
            // stroke — it previously carried a `strokeWidth` with no stroke
            // style, and Skia's default fill painted borders solid.
            let inset = Double(border.width) * 0.5
            context.strokeRect(
                Rect(
                    x: inset, y: inset,
                    width: max(0, width - Double(border.width)),
                    height: max(0, height - Double(border.width))),
                color: border.color,
                cornerRadius: max(0, cornerRadius - inset),
                width: Double(border.width))
        }
    }
}
