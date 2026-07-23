internal import NucleusLayers

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
    /// Layer-local logical damage associated with `recording`. `nil` means the
    /// complete recording bounds changed.
    package var damage: Rect?
    package var presentation: ViewLayerPresentation
    package var shadow: Shadow?

    package init(
        recording: PaintRecording = PaintRecording(),
        damage: Rect? = nil,
        presentation: ViewLayerPresentation = .default,
        shadow: Shadow? = nil
    ) {
        self.recording = recording
        self.damage = damage
        self.presentation = presentation
        self.shadow = shadow
    }

    package static let none = ViewLayerContent()
}
