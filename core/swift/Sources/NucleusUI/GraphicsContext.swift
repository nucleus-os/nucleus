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

    /// Runtime effects may sample outside the invalidated region, so the
    /// renderer must rebuild the complete backing for those recordings. Every
    /// other command is replayed from the beginning under an outer damage clip,
    /// preserving save/restore, clip, and destination-blend semantics.
    package var supportsLocalizedDamage: Bool {
        !commands.contains {
            $0.shading == .effect || $0.effectHandle != 0
        }
    }

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
    private let textSystem: TextSystem

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
    package init(textSystem: TextSystem) {
        self.textSystem = textSystem
    }

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
        set { state.lineWidth = newValue.isFinite ? max(0, newValue) : 0 }
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
        set { state.alpha = newValue.isFinite ? min(max(0, newValue), 1) : 1 }
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

    /// The current local-to-recording transform. Every paint operation carries
    /// a snapshot of this transform while keeping its geometry local. The
    /// renderer composes backing scale and this matrix exactly once.
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
        let shading = canonicalShading(shading, fallback: state.fillColor)
        applyStyle(&command, color: fillColorFor(shading))
        guard applyCurrentTransform(to: &command),
              encode(path: path, shading: shading, into: &command)
        else { return }
        append(command)
    }

    public func stroke(_ path: Path) {
        stroke(path, with: .color(state.strokeColor))
    }

    public func stroke(_ path: Path, with shading: Shading) {
        guard !path.isEmpty else { return }
        var command = PaintCommand(kind: .path, flags: pathFlags(path, stroke: true))
        let shading = canonicalShading(shading, fallback: state.strokeColor)
        applyStyle(&command, color: fillColorFor(shading, fallback: state.strokeColor))
        guard let strokeWidth = finiteFloat(state.lineWidth) else { return }
        command.strokeWidth = strokeWidth
        applyStrokeStyle(&command)
        guard applyCurrentTransform(to: &command),
              encode(path: path, shading: shading, into: &command)
        else { return }
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
        var command = PaintCommand(kind: .clipPath, flags: pathFlags(path, stroke: false))
        applyStyle(&command, color: state.fillColor)
        guard applyCurrentTransform(to: &command),
              let points = narrow(path.points)
        else { return }
        let slice = PaintPayload.append(
            to: &storedRecording.payload,
            verbs: path.verbs,
            points: points)
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
        guard !layout.isEmpty, rect.isFinite, !rect.isEmpty else { return }
        guard layout.hasBackendResource(in: textSystem) else {
            // A host/backend failure is recoverable, but invisible text is not
            // diagnosable. Render an unmistakable missing-text box while
            // TextSystem reports the underlying issue through its diagnostic
            // policy.
            fill(rect, with: .color(Color(1, 0, 1, 0.35)))
            return
        }
        storedRecording.textLayouts.append(layout.applyingDefaultColor(state.fillColor))
        var command = PaintCommand(kind: .textLayout)
        applyStyle(&command, color: state.fillColor)
        guard setGeometry(&command, rect) else {
            storedRecording.textLayouts.removeLast()
            return
        }
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
        guard rect.isFinite, !rect.isEmpty, image.id != 0 else { return }
        var command = PaintCommand(kind: .image)
        applyStyle(&command, color: tint ?? state.fillColor)
        guard setGeometry(&command, rect) else { return }
        command.radius = finiteNonnegativeFloat(cornerRadius) ?? 0
        command.imageHandle = image.id
        command.saturation = Float(
            saturation.isFinite ? min(max(0, saturation), 1) : 1)
        if tint != nil { command.flags.insert(.tintImage) }
        append(command)
    }

    /// Fill an axis-aligned rectangle directly, bypassing path encoding. Used
    /// by `ViewStyle` for backgrounds, which are the most common draw in the
    /// tree and always axis-aligned.
    package func fillRect(_ rect: Rect, color: Color, cornerRadius: Double) {
        guard rect.isFinite, !rect.isEmpty else { return }
        var command = PaintCommand(kind: cornerRadius > 0 ? .roundedRect : .rect)
        applyStyle(&command, color: color)
        guard setGeometry(&command, rect) else { return }
        command.radius = finiteNonnegativeFloat(cornerRadius) ?? 0
        append(command)
    }

    package func strokeRect(
        _ rect: Rect, color: Color, cornerRadius: Double, width: Double
    ) {
        guard rect.isFinite, !rect.isEmpty else { return }
        var command = PaintCommand(kind: cornerRadius > 0 ? .roundedRect : .rect)
        applyStyle(&command, color: color)
        command.flags.insert(.stroke)
        guard setGeometry(&command, rect),
              let strokeWidth = finiteNonnegativeFloat(width)
        else { return }
        command.radius = finiteNonnegativeFloat(cornerRadius) ?? 0
        command.strokeWidth = strokeWidth
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
        command.color = canonicalColor(color).layersColor
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

    private func setGeometry(_ command: inout PaintCommand, _ rect: Rect) -> Bool {
        guard rect.isFinite, !rect.isEmpty,
              let x = finiteFloat(rect.origin.x),
              let y = finiteFloat(rect.origin.y),
              let width = finiteFloat(rect.size.width),
              let height = finiteFloat(rect.size.height)
        else { return false }
        command.x = x
        command.y = y
        command.w = width
        command.h = height
        return applyCurrentTransform(to: &command)
    }

    /// Paint geometry always stays in its authored coordinate space. This one
    /// boundary snapshots the complete local-to-recording matrix for paths,
    /// clips, gradients, images, text, and rectangle primitives alike.
    private func applyCurrentTransform(to command: inout PaintCommand) -> Bool {
        guard state.transform.isFinite,
              let a = finiteFloat(state.transform.a),
              let b = finiteFloat(state.transform.b),
              let c = finiteFloat(state.transform.c),
              let d = finiteFloat(state.transform.d),
              let tx = finiteFloat(state.transform.tx),
              let ty = finiteFloat(state.transform.ty)
        else { return false }
        command.flags.insert(.hasTransform)
        command.transformA = a
        command.transformB = b
        command.transformC = c
        command.transformD = d
        command.transformTX = tx
        command.transformTY = ty
        return true
    }

    private func fillColorFor(_ shading: Shading, fallback: Color? = nil) -> Color {
        if case .color(let color) = shading { return color }
        return fallback ?? state.fillColor
    }

    private func encode(
        path: Path, shading: Shading, into command: inout PaintCommand
    ) -> Bool {
        var scalars: [Float] = []
        var colors: [Color] = []

        switch shading {
        case .color:
            command.shading = .color
        case .linearGradient(let from, let to, let stops):
            command.shading = .linearGradient
            guard let geometry = narrow([from.x, from.y, to.x, to.y]) else { return false }
            scalars = geometry
            appendStops(stops, &scalars, &colors)
        case .radialGradient(let center, let radius, let stops):
            command.shading = .radialGradient
            guard let geometry = narrow([center.x, center.y, radius]) else { return false }
            scalars = geometry
            appendStops(stops, &scalars, &colors)
        case .sweepGradient(let center, let start, let end, let stops):
            command.shading = .sweepGradient
            guard let geometry = narrow([center.x, center.y, start, end]) else { return false }
            scalars = geometry
            appendStops(stops, &scalars, &colors)
        case .effect(let effect, let uniforms):
            command.shading = .effect
            command.effectHandle = effect.id
            scalars = uniforms
        }

        guard let points = narrow(path.points) else { return false }
        let slice = PaintPayload.append(
            to: &storedRecording.payload,
            verbs: path.verbs,
            points: points,
            scalars: scalars,
            colors: colors.map(\.layersColor))
        command.payloadOffset = slice.offset
        command.payloadLength = slice.length
        return true
    }

    private func appendStops(
        _ stops: [GradientStop], _ scalars: inout [Float], _ colors: inout [Color]
    ) {
        for stop in stops {
            scalars.append(Float(stop.location))
            colors.append(stop.color)
        }
    }

    /// Normalize all caller-provided gradient data before it reaches the wire.
    /// Stops are clamped and sorted by location; equal locations preserve input
    /// order, defining a deterministic hard transition.
    private func canonicalShading(_ shading: Shading, fallback: Color) -> Shading {
        func stops(_ input: [GradientStop]) -> [GradientStop]? {
            guard input.count >= 2 else { return nil }
            var result: [(index: Int, stop: GradientStop)] = []
            result.reserveCapacity(input.count)
            for (index, stop) in input.enumerated() {
                guard stop.location.isFinite else { return nil }
                result.append((
                    index,
                    GradientStop(
                        location: min(max(0, stop.location), 1),
                        color: canonicalColor(stop.color))))
            }
            result.sort {
                if $0.stop.location == $1.stop.location {
                    return $0.index < $1.index
                }
                return $0.stop.location < $1.stop.location
            }
            return result.map(\.stop)
        }

        switch shading {
        case .color(let color):
            return .color(canonicalColor(color))
        case .linearGradient(let from, let to, let input):
            guard from.isFinite, to.isFinite, let stops = stops(input) else {
                return .color(canonicalColor(fallback))
            }
            return .linearGradient(from: from, to: to, stops: stops)
        case .radialGradient(let center, let radius, let input):
            guard center.isFinite, radius.isFinite, radius > 0,
                  let stops = stops(input)
            else { return .color(canonicalColor(fallback)) }
            return .radialGradient(center: center, radius: radius, stops: stops)
        case .sweepGradient(let center, let start, let end, let input):
            guard center.isFinite, start.isFinite, end.isFinite,
                  let stops = stops(input)
            else { return .color(canonicalColor(fallback)) }
            return .sweepGradient(center: center, start: start, end: end, stops: stops)
        case .effect(let effect, let uniforms):
            guard effect.id != 0, uniforms.allSatisfy(\.isFinite) else {
                return .color(canonicalColor(fallback))
            }
            return .effect(effect, uniforms: uniforms)
        }
    }

    private func canonicalColor(_ color: Color) -> Color {
        func component(_ value: Float) -> Float {
            value.isFinite ? min(max(0, value), 1) : 0
        }
        return Color(
            component(color.r), component(color.g),
            component(color.b), component(color.a))
    }

    private func finiteFloat(_ value: Double) -> Float? {
        guard value.isFinite else { return nil }
        let narrowed = Float(value)
        return narrowed.isFinite ? narrowed : nil
    }

    private func finiteNonnegativeFloat(_ value: Double) -> Float? {
        guard value.isFinite else { return nil }
        return finiteFloat(max(0, value))
    }

    private func narrow(_ values: [Double]) -> [Float]? {
        var result: [Float] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let narrowed = finiteFloat(value) else { return nil }
            result.append(narrowed)
        }
        return result
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
