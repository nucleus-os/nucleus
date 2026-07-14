public struct Border: Sendable, Equatable {
    public var width: Float
    public var color: Color

    public init(width: Float = 0, color: Color = Color(0, 0, 0, 0)) {
        self.width = max(0, width)
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
        self.cornerRadius = max(0, cornerRadius)
        self.border = border
    }

    public static let none = ViewStyle()
}

package enum LayerContentBuilder {
    package static func commands(
        style: ViewStyle,
        bounds: Rect,
        additional commands: [ViewLayerContentCommand] = []
    ) -> [ViewLayerContentCommand] {
        var result = styleCommands(style: style, bounds: bounds)
        result.append(contentsOf: commands)
        return result
    }

    package static func styleCommands(style: ViewStyle, bounds: Rect) -> [ViewLayerContentCommand] {
        var commands: [ViewLayerContentCommand] = []
        let width = max(0, Float(bounds.size.width))
        let height = max(0, Float(bounds.size.height))
        if let color = style.backgroundColor, width > 0, height > 0 {
            let radius = Float(style.cornerRadius)
            commands.append(.init(
                kind: radius > 0 ? .roundedRect : .rect,
                x: 0,
                y: 0,
                w: width,
                h: height,
                radius: radius,
                color: color
            ))
        }
        if style.border.width > 0, width > 0, height > 0 {
            commands.append(.init(
                kind: style.cornerRadius > 0 ? .roundedRect : .rect,
                x: style.border.width * 0.5,
                y: style.border.width * 0.5,
                w: max(0, width - style.border.width),
                h: max(0, height - style.border.width),
                radius: max(0, Float(style.cornerRadius) - style.border.width * 0.5),
                strokeWidth: style.border.width,
                color: style.border.color
            ))
        }
        return commands
    }

    package static func image(
        _ image: ImageHandle,
        bounds: Rect,
        fallbackSize: Size,
        cornerRadius: Float
    ) -> ViewLayerContentCommand {
        let width = bounds.size.width > 0 ? bounds.size.width : fallbackSize.width
        let height = bounds.size.height > 0 ? bounds.size.height : fallbackSize.height
        return .init(
            kind: .image,
            x: 0,
            y: 0,
            w: Float(width),
            h: Float(height),
            radius: cornerRadius,
            imageHandle: image.id
        )
    }
}
