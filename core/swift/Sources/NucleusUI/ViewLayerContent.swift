import NucleusLayers

@_spi(NucleusCompositor) public enum LayerContentCommandKind: Sendable, Equatable {
    case rect
    case roundedRect
    case image
    case line
    case backdrop
    case textLayout
}

@_spi(NucleusCompositor) public struct ViewLayerContentCommand: Sendable, Equatable {
    @_spi(NucleusCompositor) public var kind: LayerContentCommandKind
    @_spi(NucleusCompositor) public var x: Float
    @_spi(NucleusCompositor) public var y: Float
    @_spi(NucleusCompositor) public var w: Float
    @_spi(NucleusCompositor) public var h: Float
    @_spi(NucleusCompositor) public var radius: Float
    @_spi(NucleusCompositor) public var strokeWidth: Float
    @_spi(NucleusCompositor) public var color: Color
    @_spi(NucleusCompositor) public var imageHandle: UInt64
    @_spi(NucleusCompositor) public var backdropMaterial: BackdropMaterial
    @_spi(NucleusCompositor) public var textLayout: TextLayout?

    @_spi(NucleusCompositor) public init(
        kind: LayerContentCommandKind,
        x: Float,
        y: Float,
        w: Float,
        h: Float,
        radius: Float = 0,
        strokeWidth: Float = 0,
        color: Color = Color(1, 1, 1, 1),
        imageHandle: UInt64 = 0,
        backdropMaterial: BackdropMaterial = .none
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.radius = radius
        self.strokeWidth = strokeWidth
        self.color = color
        self.imageHandle = imageHandle
        self.backdropMaterial = backdropMaterial
        self.textLayout = nil
    }

    @_spi(NucleusCompositor) public static func textLayout(
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        color: Color,
        layout: TextLayout
    ) -> ViewLayerContentCommand {
        var command = ViewLayerContentCommand(
            kind: .textLayout,
            x: x,
            y: y,
            w: width,
            h: height,
            color: color
        )
        command.textLayout = layout
        return command
    }

    @_spi(NucleusCompositor) public static func == (lhs: ViewLayerContentCommand, rhs: ViewLayerContentCommand) -> Bool {
        lhs.kind == rhs.kind &&
            lhs.x == rhs.x &&
            lhs.y == rhs.y &&
            lhs.w == rhs.w &&
            lhs.h == rhs.h &&
            lhs.radius == rhs.radius &&
            lhs.strokeWidth == rhs.strokeWidth &&
            lhs.color == rhs.color &&
            lhs.imageHandle == rhs.imageHandle &&
            lhs.backdropMaterial == rhs.backdropMaterial &&
            lhs.textLayout == rhs.textLayout
    }
}

public struct ViewLayerPresentation: Sendable, Equatable {
    public var role: LayerRole
    public var backdropGroup: BackdropGroup
    public var actionPolicy: ActionPolicy
    public var creationFrame: Rect?
    public var creationOpacity: Double?

    public init(
        role: LayerRole = .generic,
        backdropGroup: BackdropGroup = .none,
        actionPolicy: ActionPolicy = .none,
        creationFrame: Rect? = nil,
        creationOpacity: Double? = nil
    ) {
        self.role = role
        self.backdropGroup = backdropGroup
        self.actionPolicy = actionPolicy
        self.creationFrame = creationFrame
        self.creationOpacity = creationOpacity
    }

    public static let `default` = ViewLayerPresentation()
}

@_spi(NucleusCompositor) public struct ViewLayerContent: Sendable, Equatable {
    @_spi(NucleusCompositor) public var commands: [ViewLayerContentCommand]
    package var presentation: ViewLayerPresentation
    package var shadow: Shadow?

    package init(
        commands: [ViewLayerContentCommand] = [],
        presentation: ViewLayerPresentation = .default,
        shadow: Shadow? = nil
    ) {
        self.commands = commands
        self.presentation = presentation
        self.shadow = shadow
    }

    package static let none = ViewLayerContent()
}
