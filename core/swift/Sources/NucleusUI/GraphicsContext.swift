import NucleusLayers
import NucleusTypes

/// What fills a shape. `.color` uses the context's `fillColor`; the gradients
/// and the SkSL escape hatch are peers, so reaching for a runtime effect is not
/// a different kind of call than reaching for a gradient.
public enum Shading: Sendable, Equatable {
    case color(Color)
    case linearGradient(from: Point, to: Point, stops: [GradientStop])
    case radialGradient(center: Point, radius: Double, stops: [GradientStop])
    case sweepGradient(center: Point, start: Double, end: Double, stops: [GradientStop])
    case effect(RuntimeEffectHandle, uniforms: [Float])
}

public struct GradientStop: Sendable, Equatable {
    public var location: Double
    public var color: Color

    public init(location: Double, color: Color) {
        self.location = location
        self.color = color
    }
}

/// A registered SkSL program. The handle is minted once through the effect
/// registrar and reused every frame; only its uniforms are per-frame data.
public struct RuntimeEffectHandle: Sendable, Equatable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

public enum LineCap: Sendable, Equatable { case butt, round, square }
public enum LineJoin: Sendable, Equatable { case miter, round, bevel }

public enum BlendMode: Sendable, Equatable {
    case srcOver, src, multiply, screen, plus, overlay, dstIn, dstOut
}

/// One view's recorded drawing. Pure data: no handles are minted while
/// recording, so two recordings of the same drawing compare equal and the
/// publisher's diff can suppress a redundant re-registration.
/// One view's recorded drawing.
///
/// The type is public because `GraphicsContext` produces it, but its contents
/// are `package`: reading a recording is an embedder concern. A product view
/// authors through `GraphicsContext` and never inspects what it produced — and
/// a product *test* that reaches for the command list is asserting on the wrong
/// thing, which is how a bug that rendered nothing once passed a green suite.
public struct PaintRecording: Sendable, Equatable {
    package var commands: [PaintCommand] = []
    package var payload: [UInt8] = []
    /// Text layouts referenced by `textLayoutHandle`, which during recording
    /// holds a **one-based index into this array**, not a registry handle.
    /// `PaintRegistration` resolves those indices to real handles. Minting
    /// during recording would make every recording containing text unequal to
    /// the last one and re-register the view on every publish.
    package var textLayouts: [TextLayout] = []

    package var isEmpty: Bool { commands.isEmpty }

    package init() {}

    /// Whether anything was drawn.
    public var isEmptyDrawing: Bool { commands.isEmpty }
}

/// The drawing surface handed to `View.draw(in:)`.
///
/// A class, not an `inout` struct: AppKit's `NSGraphicsContext` is a class, and
/// threading `inout` through every drawing helper would tax each signature for
/// nothing. `@MainActor` and non-`Sendable` because it is view-tree state.
///
/// Every operation is non-throwing. Appending geometry has no failure a view
/// could act on; registration and publication can fail, and report it at the
/// host boundary after recording completes.
@MainActor
public final class GraphicsContext {
    private var storedRecording = PaintRecording()

    /// The recorded drawing, with any unbalanced `saveGState` closed off.
    ///
    /// A `draw(in:)` override that calls `saveGState()` and returns early leaves
    /// an unmatched save; the rasterizer would then replay a canvas save with no
    /// restore, and a clip set after it would persist for the rest of that
    /// view's recording. Balancing here keeps a client's mistake from changing
    /// how *later* commands render. Prefer `withGraphicsState {}`, which cannot
    /// unbalance in the first place.
    package var recording: PaintRecording {
        guard !stack.isEmpty else { return storedRecording }
        var balanced = storedRecording
        for _ in stack { balanced.commands.append(PaintCommand(kind: .restore)) }
        return balanced
    }

    private struct State {
        var fillColor = Color(1, 1, 1, 1)
        var strokeColor = Color(1, 1, 1, 1)
        var lineWidth: Double = 1
        var lineCap: LineCap = .butt
        var lineJoin: LineJoin = .miter
        var blendMode: BlendMode = .srcOver
        var alpha: Double = 1
        var antialias = true
        var transform = AffineTransform.identity
    }

    private var state = State()
    private var stack: [State] = []

    /// Host-facing: product code receives a context in `View.draw(in:)` rather
    /// than constructing one. Publication paths that record outside the normal
    /// display pass construct their own.
    package init() {}

    // MARK: - Graphics state

    public var fillColor: Color {
        get { state.fillColor }
        set { state.fillColor = newValue }
    }

    public var strokeColor: Color {
        get { state.strokeColor }
        set { state.strokeColor = newValue }
    }

    public var lineWidth: Double {
        get { state.lineWidth }
        set { state.lineWidth = max(0, newValue) }
    }

    public var lineCap: LineCap {
        get { state.lineCap }
        set { state.lineCap = newValue }
    }

    public var lineJoin: LineJoin {
        get { state.lineJoin }
        set { state.lineJoin = newValue }
    }

    public var blendMode: BlendMode {
        get { state.blendMode }
        set { state.blendMode = newValue }
    }

    public var alpha: Double {
        get { state.alpha }
        set { state.alpha = min(max(0, newValue), 1) }
    }

    public var shouldAntialias: Bool {
        get { state.antialias }
        set { state.antialias = newValue }
    }

    /// Push the graphics state. Emits a canvas `save` so a clip established
    /// after this point is undone by the matching `restoreGState`.
    public func saveGState() {
        stack.append(state)
        append(PaintCommand(kind: .save))
    }

    public func restoreGState() {
        guard let previous = stack.popLast() else { return }
        state = previous
        append(PaintCommand(kind: .restore))
    }

    /// Scoped `saveGState`/`restoreGState`. Preferred over the bare pair —
    /// an early return cannot leave the stack unbalanced.
    public func withGraphicsState(_ body: () -> Void) {
        saveGState()
        body()
        restoreGState()
    }

    // MARK: - Transform

    /// The current transform. Applied to geometry as it is recorded rather
    /// than carried on each command: the rasterizer scales the whole canvas to
    /// the output, and a per-command matrix would be a second, conflicting way
    /// to say the same thing.
    public var currentTransform: AffineTransform { state.transform }

    public func translateBy(x: Double, y: Double) {
        state.transform = state.transform.translated(x: x, y: y)
    }

    public func scaleBy(x: Double, y: Double) {
        state.transform = state.transform.scaled(x: x, y: y)
    }

    public func rotateBy(degrees: Double) {
        state.transform = state.transform.rotated(degrees: degrees)
    }

    public func concatenate(_ transform: AffineTransform) {
        state.transform = state.transform.concatenating(transform)
    }

    // MARK: - Drawing

    public func fill(_ path: Path) {
        fill(path, with: .color(state.fillColor))
    }

    public func fill(_ path: Path, with shading: Shading) {
        guard !path.isEmpty else { return }
        var command = PaintCommand(kind: .path, flags: pathFlags(path, stroke: false))
        applyStyle(&command, color: fillColorFor(shading))
        encode(path: path, shading: shading, into: &command)
        append(command)
    }

    public func stroke(_ path: Path) {
        stroke(path, with: .color(state.strokeColor))
    }

    public func stroke(_ path: Path, with shading: Shading) {
        guard !path.isEmpty else { return }
        var command = PaintCommand(kind: .path, flags: pathFlags(path, stroke: true))
        applyStyle(&command, color: fillColorFor(shading, fallback: state.strokeColor))
        command.strokeWidth = Float(state.lineWidth * scalarScale)
        applyStrokeStyle(&command)
        encode(path: path, shading: shading, into: &command)
        append(command)
    }

    public func fill(_ rect: Rect, with shading: Shading) {
        var path = Path()
        path.addRect(rect)
        fill(path, with: shading)
    }

    public func fill(_ rect: Rect) {
        fill(rect, with: .color(state.fillColor))
    }

    /// Intersect the clip with `path`, scoped to the enclosing graphics state.
    public func clip(to path: Path) {
        guard !path.isEmpty else { return }
        var command = PaintCommand(kind: .clipPath, flags: pathFlags(path, stroke: false))
        applyStyle(&command, color: state.fillColor)
        let slice = PaintPayload.append(
            to: &storedRecording.payload,
            verbs: path.verbs,
            points: transformedPoints(path))
        command.payloadOffset = slice.offset
        command.payloadLength = slice.length
        append(command)
    }

    public func clip(to rect: Rect) {
        var path = Path()
        path.addRect(rect)
        clip(to: path)
    }

    /// Draw a shaped text layout. Plain `public` — text is a headline drawing
    /// operation, not publication plumbing.
    public func draw(_ layout: TextLayout, in rect: Rect) {
        guard !layout.isEmpty else { return }
        storedRecording.textLayouts.append(layout.applyingDefaultColor(state.fillColor))
        var command = PaintCommand(kind: .textLayout)
        applyStyle(&command, color: state.fillColor)
        setGeometry(&command, rect)
        // One-based index; resolved to a registry handle at registration.
        command.textLayoutHandle = UInt64(storedRecording.textLayouts.count)
        append(command)
    }

    /// Draw an image.
    ///
    /// - Parameter tint: recolours the image by its alpha, keeping its shape and
    ///   discarding its colour. This is how a symbolic icon follows the palette.
    ///   `nil` draws the image's own colours.
    /// - Parameter saturation: `1` is untouched, `0` fully grey. Combined with a
    ///   tint it desaturates first, which is how a full-colour app icon is
    ///   recoloured without flattening it to a silhouette.
    public func draw(
        _ image: ImageHandle, in rect: Rect, cornerRadius: Double = 0,
        tint: Color? = nil, saturation: Double = 1
    ) {
        var command = PaintCommand(kind: .image)
        applyStyle(&command, color: tint ?? state.fillColor)
        setGeometry(&command, rect)
        command.radius = Float(max(0, cornerRadius) * scalarScale)
        command.imageHandle = image.id
        command.saturation = Float(saturation)
        if tint != nil { command.flags.insert(.tintImage) }
        append(command)
    }

    /// Fill an axis-aligned rectangle directly, bypassing path encoding. Used
    /// by `ViewStyle` for backgrounds, which are the most common draw in the
    /// tree and always axis-aligned.
    package func fillRect(_ rect: Rect, color: Color, cornerRadius: Double) {
        var command = PaintCommand(kind: cornerRadius > 0 ? .roundedRect : .rect)
        applyStyle(&command, color: color)
        setGeometry(&command, rect)
        command.radius = Float(cornerRadius * scalarScale)
        append(command)
    }

    package func strokeRect(
        _ rect: Rect, color: Color, cornerRadius: Double, width: Double
    ) {
        var command = PaintCommand(kind: cornerRadius > 0 ? .roundedRect : .rect)
        applyStyle(&command, color: color)
        command.flags.insert(.stroke)
        setGeometry(&command, rect)
        command.radius = Float(cornerRadius * scalarScale)
        command.strokeWidth = Float(width * scalarScale)
        append(command)
    }

    // MARK: -

    private func append(_ command: PaintCommand) {
        storedRecording.commands.append(command)
    }

    private func pathFlags(_ path: Path, stroke: Bool) -> PaintCommandFlags {
        var flags: PaintCommandFlags = state.antialias ? [.antialias] : []
        if stroke { flags.insert(.stroke) }
        if path.usesEvenOddFillRule { flags.insert(.evenOddFill) }
        return flags
    }

    private func applyStyle(_ command: inout PaintCommand, color: Color) {
        command.color = color.layersColor
        command.alpha = Float(state.alpha)
        command.blend = wireBlend(state.blendMode)
        if state.antialias { command.flags.insert(.antialias) }
        else { command.flags.remove(.antialias) }
    }

    /// Carry the cap and join into the command. Only meaningful on a stroke, so
    /// only strokes call it — a filled command with these bits set would be
    /// describing something it does not do.
    private func applyStrokeStyle(_ command: inout PaintCommand) {
        switch state.lineCap {
        case .butt: break
        case .round: command.flags.insert(.capRound)
        case .square: command.flags.insert(.capSquare)
        }
        switch state.lineJoin {
        case .miter: break
        case .round: command.flags.insert(.joinRound)
        case .bevel: command.flags.insert(.joinBevel)
        }
    }

    /// Whether the current transform does something a rectangle cannot absorb.
    ///
    /// A translation or a scale maps a rectangle to a rectangle, so it folds
    /// into the geometry and the command stays a plain rect. Rotation and skew
    /// do not — folding those in leaves an axis-aligned bounding box, which is
    /// what this used to do to every image, glyph run, and rect fill under a
    /// `rotateBy`: drawn upright, at the wrong size, with no indication that
    /// the rotation had been dropped.
    private var transformNeedsCarrying: Bool {
        state.transform.b != 0 || state.transform.c != 0
    }

    private func setGeometry(_ command: inout PaintCommand, _ rect: Rect) {
        guard transformNeedsCarrying else {
            let origin = state.transform.apply(Point(x: rect.origin.x, y: rect.origin.y))
            let far = state.transform.apply(Point(
                x: rect.origin.x + rect.size.width, y: rect.origin.y + rect.size.height))
            command.x = Float(min(origin.x, far.x))
            command.y = Float(min(origin.y, far.y))
            command.w = Float(abs(far.x - origin.x))
            command.h = Float(abs(far.y - origin.y))
            return
        }

        // Geometry stays in local space and the transform rides along; the
        // rasterizer concatenates it. Scalars that would otherwise be
        // pre-scaled (radius, stroke width) stay local too — the matrix scales
        // them, and pre-scaling as well would apply it twice.
        command.x = Float(rect.origin.x)
        command.y = Float(rect.origin.y)
        command.w = Float(rect.size.width)
        command.h = Float(rect.size.height)
        command.flags.insert(.hasTransform)
        command.transformA = Float(state.transform.a)
        command.transformB = Float(state.transform.b)
        command.transformC = Float(state.transform.c)
        command.transformD = Float(state.transform.d)
        command.transformTX = Float(state.transform.tx)
        command.transformTY = Float(state.transform.ty)
    }

    /// The factor to pre-scale a local scalar by. One when the command carries
    /// its own transform, since the matrix already does it.
    private var scalarScale: Double {
        transformNeedsCarrying ? 1 : state.transform.approximateScale
    }

    private func fillColorFor(_ shading: Shading, fallback: Color? = nil) -> Color {
        if case .color(let color) = shading { return color }
        return fallback ?? state.fillColor
    }

    private func transformedPoints(_ path: Path) -> [Float] {
        guard !state.transform.isIdentity else { return path.points }
        var out = path.points
        var cursor = 0
        for verb in path.verbs {
            switch verb {
            case .arc:
                // (origin, size, angles): transform the rect, leave the angles.
                let origin = state.transform.apply(
                    Point(x: Double(out[cursor]), y: Double(out[cursor + 1])))
                out[cursor] = Float(origin.x)
                out[cursor + 1] = Float(origin.y)
                out[cursor + 2] *= Float(state.transform.a)
                out[cursor + 3] *= Float(state.transform.d)
            default:
                var i = 0
                while i < verb.floatCount {
                    let p = state.transform.apply(
                        Point(x: Double(out[cursor + i]), y: Double(out[cursor + i + 1])))
                    out[cursor + i] = Float(p.x)
                    out[cursor + i + 1] = Float(p.y)
                    i += 2
                }
            }
            cursor += verb.floatCount
        }
        return out
    }

    private func encode(path: Path, shading: Shading, into command: inout PaintCommand) {
        var scalars: [Float] = []
        var colors: [Color] = []

        switch shading {
        case .color:
            command.shading = .color
        case .linearGradient(let from, let to, let stops):
            command.shading = .linearGradient
            let a = state.transform.apply(from), b = state.transform.apply(to)
            scalars = [Float(a.x), Float(a.y), Float(b.x), Float(b.y)]
            appendStops(stops, &scalars, &colors)
        case .radialGradient(let center, let radius, let stops):
            command.shading = .radialGradient
            let c = state.transform.apply(center)
            scalars = [
                Float(c.x), Float(c.y), Float(radius * state.transform.approximateScale),
            ]
            appendStops(stops, &scalars, &colors)
        case .sweepGradient(let center, let start, let end, let stops):
            command.shading = .sweepGradient
            let c = state.transform.apply(center)
            scalars = [Float(c.x), Float(c.y), Float(start), Float(end)]
            appendStops(stops, &scalars, &colors)
        case .effect(let effect, let uniforms):
            command.shading = .effect
            command.effectHandle = effect.id
            scalars = uniforms
        }

        let slice = PaintPayload.append(
            to: &storedRecording.payload,
            verbs: path.verbs,
            points: transformedPoints(path),
            scalars: scalars,
            colors: colors.map(\.layersColor))
        command.payloadOffset = slice.offset
        command.payloadLength = slice.length
    }

    private func appendStops(
        _ stops: [GradientStop], _ scalars: inout [Float], _ colors: inout [Color]
    ) {
        for stop in stops {
            scalars.append(Float(stop.location))
            colors.append(stop.color)
        }
    }

    private func wireBlend(_ mode: BlendMode) -> PaintBlendMode {
        switch mode {
        case .srcOver: .srcOver
        case .src: .src
        case .multiply: .multiply
        case .screen: .screen
        case .plus: .plus
        case .overlay: .overlay
        case .dstIn: .dstIn
        case .dstOut: .dstOut
        }
    }
}
