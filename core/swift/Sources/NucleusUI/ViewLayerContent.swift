import NucleusLayers

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

package struct ViewLayerContent: Sendable, Equatable {
    package var recording: PaintRecording
    package var presentation: ViewLayerPresentation
    package var shadow: Shadow?

    package init(
        recording: PaintRecording = PaintRecording(),
        presentation: ViewLayerPresentation = .default,
        shadow: Shadow? = nil
    ) {
        self.recording = recording
        self.presentation = presentation
        self.shadow = shadow
    }

    package static let none = ViewLayerContent()
}
