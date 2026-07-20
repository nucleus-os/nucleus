/// A bar showing progress through a task, or a level.
///
/// The bar in the reference is used both ways — a download's progress and the
/// current volume are the same control — so there is no separate level
/// indicator.
@MainActor
public final class ProgressIndicator: View, ~Sendable {
    public enum Orientation: Sendable, Equatable {
        /// Fills from the leading edge.
        case horizontal
        /// Fills outward from the middle. Used for values that are a deviation
        /// rather than an amount — balance, or a signed meter.
        case horizontalCentered
        /// Fills upward from the bottom, which is the direction a vertical
        /// meter is read.
        case vertical
    }

    public var orientation: Orientation = .horizontal {
        didSet { if orientation != oldValue { setNeedsLayout() } }
    }

    /// Progress from 0 to 1.
    ///
    /// Out-of-range values clamp and a non-finite one reads as empty, rather
    /// than either being rejected: a caller dividing by a total that briefly
    /// reads zero should get an empty bar, not a broken one or a crash.
    public var progress: Double {
        get { storedProgress }
        set {
            let clamped = newValue.isFinite ? min(1, max(0, newValue)) : 0
            guard clamped != storedProgress else { return }
            storedProgress = clamped
            accessibilityValue = String(clamped)
            setNeedsLayout()
        }
    }

    private var storedProgress: Double = 0

    public var trackColor: ColorSpec = .role(.surfaceVariant) {
        didSet { if trackColor != oldValue { applyColors() } }
    }

    public var fillColor: ColorSpec = .role(.primary) {
        didSet { if fillColor != oldValue { applyColors() } }
    }

    /// Rounding for both track and fill. Defaults to fully rounded ends, which
    /// is what the reference uses everywhere.
    public var barCornerRadius: Double? {
        didSet { if barCornerRadius != oldValue { setNeedsLayout() } }
    }

    /// The fill is a *full-size* bar revealed through a clip.
    ///
    /// Drawing it at the fraction's width instead would square off its trailing
    /// end, so a rounded bar at 5% shows a stubby rectangle rather than the
    /// rounded cap it has at 100%. Clipping a full-size copy keeps both ends
    /// exactly the shape the track has. This is the reference's approach and the
    /// reason is worth keeping with it.
    private let fillClip = View()
    private let fill = View()

    public override init() {
        super.init()
        clipsToBounds = true
        fillClip.clipsToBounds = true
        fillClip.addSubview(fill)
        addSubview(fillClip)
        isAccessibilityElement = true
        accessibilityRole = .progressIndicator
        accessibilityValue = "0.0"
        applyColors()
    }

    public convenience init(progress: Double) {
        self.init()
        self.progress = progress
    }

    private func applyColors() {
        backgroundColor = resolve(trackColor)
        fill.backgroundColor = resolve(fillColor)
    }

    public override func viewDidChangeEffectiveAppearance() {
        applyColors()
        super.viewDidChangeEffectiveAppearance()
    }

    public override var environmentDependencies: UIEnvironmentChanges {
        super.environmentDependencies
    }

    public override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        // Fully rounded unless told otherwise: half the short side.
        let radius = barCornerRadius ?? (min(size.width, size.height) / 2)
        cornerRadius = radius
        fill.cornerRadius = radius

        // The fill is always the full bar; only the window onto it moves.
        fill.frame = Rect(origin: .zero, size: size)

        switch orientation {
        case .horizontal:
            fillClip.frame = Rect(
                x: 0, y: 0, width: size.width * progress, height: size.height)
            fill.frame = Rect(origin: .zero, size: size)
        case .horizontalCentered:
            let width = size.width * progress
            let x = (size.width - width) / 2
            fillClip.frame = Rect(x: x, y: 0, width: width, height: size.height)
            // The fill stays put in the bar's coordinates, so its rounded ends
            // remain at the bar's ends rather than travelling with the window.
            fill.frame = Rect(x: -x, y: 0, width: size.width, height: size.height)
        case .vertical:
            let height = size.height * progress
            fillClip.frame = Rect(
                x: 0, y: size.height - height, width: size.width, height: height)
            fill.frame = Rect(
                x: 0, y: -(size.height - height), width: size.width, height: size.height)
        }
    }

    /// A bar has a natural thickness and no natural length — the layout decides
    /// how long it is.
    public override var intrinsicContentSize: Size {
        orientation == .vertical
            ? Size(width: ProgressIndicator.thickness, height: 0)
            : Size(width: 0, height: ProgressIndicator.thickness)
    }

    private static let thickness: Double = 4
}
