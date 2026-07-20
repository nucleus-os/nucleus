import NucleusTypes
import NucleusLayers

/// AppKit-shaped semantic backdrop view. Apps name the
/// material role (`.popover`, `.sidebar`, `.titlebar`, ...); the framework's
/// catalog turns that role plus `state`/`appearance`/`isEmphasized` into
/// concrete blur+tint+noise parameters. Producers never see passes,
/// saturation, or noise strength.
@MainActor
public final class VisualEffectView: View, ~Sendable {

    /// Supported semantic material names from modern AppKit. Legacy aliases
    /// live in `BlurEffect.Style` and fold into these through `MaterialBridge`.
    public enum Material: Sendable, Equatable {
        case titlebar
        case selection
        case menu
        case popover
        case sidebar
        case headerView
        case sheet
        case windowBackground
        case hudWindow
        case fullScreenUI
        case toolTip
        case contentBackground
        case underWindowBackground
        case underPageBackground
    }

    /// Supported `NSVisualEffectView.BlendingMode`-shaped vocabulary.
    public enum BlendingMode: Sendable, Equatable {
        case behindWindow
        case withinWindow
    }

    /// Supported `NSVisualEffectView.State`-shaped vocabulary.
    public enum State: Sendable, Equatable {
        case followsWindowActiveState
        case active
        case inactive
    }

    public var material: Material {
        didSet { syncBackdrop() }
    }

    public var blendingMode: BlendingMode {
        didSet { syncBackdrop() }
    }

    public var state: State {
        didSet { syncBackdrop() }
    }

    public var isEmphasized: Bool {
        didSet { syncBackdrop() }
    }

    /// `NSVisualEffectView.maskImage` analogue. Optional alpha mask
    /// applied to the backdrop's region; nil for the layer's full bounds.
    public var maskImage: ImageHandle? {
        didSet { syncBackdrop() }
    }

    public override var cornerRadius: Double {
        didSet { syncBackdrop() }
    }

    /// Material-level opacity attenuation (separate from `alphaValue`,
    /// which scales the whole view). The catalog multiplies the resolved
    /// chain alpha by this value. Range [0, 1] (clamped on set).
    public var materialOpacity: Double {
        didSet {
            let clamped = min(max(0, materialOpacity), 1)
            if clamped != materialOpacity {
                materialOpacity = clamped
                return
            }
            syncBackdrop()
        }
    }

    /// UIKit pattern: children added here render with the effect applied.
    /// AppKit's `addSubview` pattern also works — `contentView` is just
    /// this view for now (no separate content-layer indirection until a
    /// real reason appears).
    public var contentView: View { self }

    /// UIKit pattern: read or replace the visual effect as a single
    /// `BlurEffect`/`VibrancyEffect` value. Getter synthesizes one from
    /// the current `material`/`blendingMode`/`isEmphasized`; setter
    /// derives those back through `MaterialBridge`.
    public var effect: VisualEffect? {
        get { MaterialBridge.effect(material: material, blendingMode: blendingMode, isEmphasized: isEmphasized) }
        set {
            if let blur = newValue as? BlurEffect {
                let mapped = MaterialBridge.material(for: blur.style)
                material = mapped.material
                isEmphasized = mapped.isEmphasized
                appearance = mapped.forcedAppearance ?? appearance
            } else if let vibrancy = newValue as? VibrancyEffect {
                let mapped = MaterialBridge.material(for: vibrancy.blurEffect.style)
                material = mapped.material
                isEmphasized = mapped.isEmphasized
                appearance = mapped.forcedAppearance ?? appearance
                // The vibrancy style itself is purely a tint preset that
                // the catalog folds into the chain via the resolved
                // BackdropMaterial; carried through `material` for now.
            }
        }
    }

    public init(
        material: Material = .contentBackground,
        blendingMode: BlendingMode = .behindWindow,
        state: State = .followsWindowActiveState,
        isEmphasized: Bool = false,
        cornerRadius: Double = 0,
        materialOpacity: Double = 1,
        appearance: Appearance? = nil
    ) {
        let resolvedAppearance =
            appearance ?? Application.currentUIContext.environment.appearance
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.isEmphasized = isEmphasized
        self.maskImage = nil
        self.materialOpacity = min(max(0, materialOpacity), 1)
        super.init(layerDescriptor: LayerDescriptor(
            kind: .backdrop,
            backdropMaterial: MaterialBridge.backdropMaterial(
                material: material,
                blendingMode: blendingMode,
                state: state,
                isEmphasized: isEmphasized,
                cornerRadius: max(0, cornerRadius),
                opacity: min(max(0, materialOpacity), 1),
                appearance: resolvedAppearance,
                maskImage: nil
            )
        ))
        self.appearance = appearance
        self.cornerRadius = max(0, cornerRadius)
        isAccessibilityElement = false
        applyBackdrop()
    }

    /// UIKit-shaped convenience: `init(effect:)`.
    public convenience init(effect: VisualEffect) {
        self.init()
        self.effect = effect
    }

    private func syncBackdrop() {
        applyBackdrop()
        setNeedsDisplay()
        setNeedsLayout()
    }

    private func applyBackdrop() {
        setProperties(ViewProperties(backdropMaterial: resolvedBackdropMaterial()))
        backgroundColor = uiContext.environment.reducesTransparency
            ? effectivePalette.surface
            : nil
    }

    package func resolvedBackdropMaterial() -> BackdropMaterial {
        guard !uiContext.environment.reducesTransparency else {
            return .none
        }
        return MaterialBridge.backdropMaterial(
            material: material,
            blendingMode: blendingMode,
            state: state,
            isEmphasized: isEmphasized,
            cornerRadius: cornerRadius,
            opacity: materialOpacity,
            appearance: appearance ?? effectiveAppearance,
            maskImage: maskImage
        )
    }

    public override var properties: ViewProperties {
        ViewProperties(frame: frame, isHidden: isHidden, backdropMaterial: resolvedBackdropMaterial())
    }

    public override var environmentDependencies: UIEnvironmentChanges {
        [.reducedTransparency, .appearance, .increasedContrast]
    }

    public override func environmentDidChange(
        _ changes: UIEnvironmentChanges
    ) {
        applyBackdrop()
        super.environmentDidChange(changes)
    }
}
