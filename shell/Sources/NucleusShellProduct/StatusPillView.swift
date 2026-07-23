public import NucleusUI

/// A rounded status pill with an accent-tinted fill, a hairline outline, and a
/// leading indicator dot — the shell bar's most repeated element.
///
/// This is the first native shell view authored entirely against NucleusUI's
/// public drawing API. It exists to prove the boundary: a product view outside
/// package `Nucleus` can express real shell chrome with no access to layers,
/// recordings, registrars, or the renderer.
@MainActor
public final class StatusPillView: View {
    public enum Indicator: Sendable, Equatable {
        case none
        /// A filled dot, for a discrete state (connected, muted, charging).
        case dot(Color)
        /// A ring filled clockwise from the top, for a continuous 0...1 value
        /// (battery level, download progress).
        case ring(Color, progress: Double)
    }

    public var accent: Color = Color(0.36, 0.60, 0.96, 1) {
        didSet { if accent != oldValue { setNeedsDisplay() } }
    }

    public var indicator: Indicator = .none {
        didSet { if indicator != oldValue { setNeedsDisplay() } }
    }

    /// Draws a subtle vertical sheen over the fill. Off for dense bars where
    /// the gradient reads as noise.
    public var isEmphasized: Bool = false {
        didSet { if isEmphasized != oldValue { setNeedsDisplay() } }
    }

    public override init() {
        super.init()
        style = ViewStyle(cornerRadius: 9)
    }

    public override var intrinsicContentSize: Size {
        Size(width: 72, height: 18)
    }

    public override func draw(in context: GraphicsContext) {
        let bounds = Rect(
            x: 0, y: 0, width: self.bounds.size.width, height: self.bounds.size.height)
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }

        let radius = min(9, bounds.size.height / 2)
        var pill = Path()
        pill.addRoundedRect(bounds, radius: radius)

        if isEmphasized {
            context.fill(pill, with: .linearGradient(
                from: Point(x: 0, y: 0),
                to: Point(x: 0, y: bounds.size.height),
                stops: [
                    GradientStop(location: 0, color: accent.opacity(0.34)),
                    GradientStop(location: 1, color: accent.opacity(0.16)),
                ]))
        } else {
            context.fillColor = accent.opacity(0.22)
            context.fill(pill)
        }

        // Hairline outline, inset by half its width so it lands inside the
        // pill rather than straddling the edge.
        var outline = Path()
        outline.addRoundedRect(
            Rect(
                x: 0.5, y: 0.5,
                width: bounds.size.width - 1, height: bounds.size.height - 1),
            radius: max(0, radius - 0.5))
        context.strokeColor = accent.opacity(0.55)
        context.lineWidth = 1
        context.stroke(outline)

        drawIndicator(in: context, bounds: bounds)
    }

    private func drawIndicator(in context: GraphicsContext, bounds: Rect) {
        let inset = bounds.size.height * 0.28
        let diameter = bounds.size.height - inset * 2
        guard diameter > 0 else { return }
        let box = Rect(x: inset, y: inset, width: diameter, height: diameter)

        switch indicator {
        case .none:
            return
        case .dot(let color):
            var dot = Path()
            dot.addEllipse(in: box)
            context.fillColor = color
            context.fill(dot)
        case .ring(let color, let progress):
            // Track plus a clockwise sweep from 12 o'clock. An arc is a path
            // verb, so the ring is one stroked path with a round cap.
            var track = Path()
            track.addEllipse(in: box)
            context.strokeColor = color.opacity(0.3)
            context.lineWidth = 1.5
            context.stroke(track)

            let clamped = min(max(0, progress), 1)
            guard clamped > 0 else { return }
            var sweep = Path()
            sweep.addArc(in: box, start: -90, sweep: 360 * clamped)
            context.strokeColor = color
            context.lineCap = .round
            context.stroke(sweep)
        }
    }
}
