/// A wrapping, gap-aware flex container.
///
/// Children keep explicit `layoutBasis`, `growFactor`, `shrinkFactor`,
/// `minimumLayoutExtent`, and `maximumLayoutExtent` policies on the child.
@MainActor
open class FlexView: View, ~Sendable {
    public enum Direction: Sendable, Equatable {
        case row
        case column
    }

    public enum Wrap: Sendable, Equatable {
        case noWrap
        case wrap
    }

    public enum ItemAlignment: Sendable, Equatable {
        case leading
        case center
        case trailing
        case stretch
        case firstBaseline
        case lastBaseline
    }

    public enum LineAlignment: Sendable, Equatable {
        case leading
        case center
        case trailing
        case stretch
        case spaceBetween
    }

    public var direction: Direction = .row {
        didSet { if direction != oldValue { setNeedsLayout() } }
    }
    public var wrap: Wrap = .wrap {
        didSet { if wrap != oldValue { setNeedsLayout() } }
    }
    public var itemAlignment: ItemAlignment = .stretch {
        didSet { if itemAlignment != oldValue { setNeedsLayout() } }
    }
    public var lineAlignment: LineAlignment = .leading {
        didSet { if lineAlignment != oldValue { setNeedsLayout() } }
    }

    private var storedRowGap: Double = 0
    public var rowGap: Double {
        get { storedRowGap }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedRowGap else { return }
            storedRowGap = value
            setNeedsLayout()
        }
    }

    private var storedColumnGap: Double = 0
    public var columnGap: Double {
        get { storedColumnGap }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedColumnGap else { return }
            storedColumnGap = value
            setNeedsLayout()
        }
    }

    private var arranged: [View] = []

    public override init() {
        super.init()
    }

    public var arrangedSubviews: [View] { arranged }

    public func addArrangedSubview(_ view: View) {
        guard !arranged.contains(where: { $0 === view }) else { return }
        addSubview(view)
        arranged.append(view)
        setNeedsLayout()
    }

    public func removeArrangedSubview(_ view: View) {
        guard let index = arranged.firstIndex(where: { $0 === view }) else { return }
        arranged.remove(at: index)
        view.removeFromSuperview()
        setNeedsLayout()
    }

    public func replaceArrangedSubviews(with views: [View]) {
        let incoming = Set(views.map(ObjectIdentifier.init))
        let existing = Set(arranged.map(ObjectIdentifier.init))
        for view in arranged where !incoming.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
        }
        for view in views where !existing.contains(ObjectIdentifier(view)) {
            addSubview(view)
        }
        arranged = views
        setNeedsLayout()
    }

    open override func measure(_ constraints: LayoutConstraints) -> Size {
        let mainLimit = mainMaximum(in: constraints)
        let lines = makeLines(mainLimit: mainLimit, forLayout: false)
        let main = lines.map(\.naturalMain).max() ?? 0
        let cross = lines.reduce(0) { $0 + $1.naturalCross }
            + crossGap * Double(max(0, lines.count - 1))
        return constraints.constrain(size(main: main, cross: cross))
    }

    open override func layout() {
        let availableMain = max(0, main(frame.size))
        let availableCross = max(0, cross(frame.size))
        var lines = makeLines(
            mainLimit: wrap == .wrap ? availableMain : .infinity,
            forLayout: true)
        guard !lines.isEmpty else { return }

        for index in lines.indices {
            let gaps = mainGap * Double(max(0, lines[index].views.count - 1))
            lines[index].mainSizes = FlexibleLayoutResolver.resolve(
                lines[index].mainSizes,
                views: lines[index].views,
                available: max(0, availableMain - gaps))
        }

        var lineCrossSizes = lines.map(\.naturalCross)
        let minimumGapTotal = crossGap * Double(max(0, lines.count - 1))
        let usedCross = lineCrossSizes.reduce(0, +) + minimumGapTotal
        var crossOrigin: Double = 0
        var resolvedCrossGap = crossGap
        let surplus = max(0, availableCross - usedCross)
        switch lineAlignment {
        case .leading:
            break
        case .center:
            crossOrigin = surplus / 2
        case .trailing:
            crossOrigin = surplus
        case .stretch:
            if !lineCrossSizes.isEmpty {
                let addition = surplus / Double(lineCrossSizes.count)
                lineCrossSizes = lineCrossSizes.map { $0 + addition }
            }
        case .spaceBetween:
            if lines.count > 1 {
                resolvedCrossGap = max(
                    0,
                    (availableCross - lineCrossSizes.reduce(0, +))
                        / Double(lines.count - 1))
            }
        }

        var lineCursor = crossOrigin
        for lineIndex in lines.indices {
            let line = lines[lineIndex]
            let lineCross = lineCrossSizes[lineIndex]
            let baselineOffsets = itemBaselineOffsets(
                line: line, lineCross: lineCross)
            var itemCursor: Double = 0
            for itemIndex in line.views.indices {
                let view = line.views[itemIndex]
                let itemMain = line.mainSizes[itemIndex]
                let preferredCross = cross(line.measured[itemIndex])
                let itemCross = itemAlignment == .stretch
                    ? lineCross
                    : min(preferredCross, lineCross)
                let itemCrossOffset = baselineOffsets?[itemIndex]
                    ?? alignmentOffset(itemCross: itemCross, lineCross: lineCross)
                let rect = frame(
                    mainOrigin: itemCursor,
                    crossOrigin: lineCursor + itemCrossOffset,
                    main: itemMain,
                    cross: itemCross)
                view.arrange(in: rect)
                itemCursor += itemMain + mainGap
            }
            lineCursor += lineCross + resolvedCrossGap
        }
    }

    private struct Line {
        var views: [View]
        var measured: [Size]
        var mainSizes: [Double]
        var naturalMain: Double
        var naturalCross: Double
    }

    private func makeLines(mainLimit: Double, forLayout: Bool) -> [Line] {
        let visible = arranged.filter { !$0.isHidden }
        guard !visible.isEmpty else { return [] }
        let finiteLimit = mainLimit.isFinite ? max(0, mainLimit) : .infinity
        let measurement: LayoutConstraints = switch direction {
        case .row:
            LayoutConstraints(
                maxWidth: .infinity,
                maxHeight: forLayout ? max(0, frame.size.height) : .infinity)
        case .column:
            LayoutConstraints(
                maxWidth: forLayout ? max(0, frame.size.width) : .infinity,
                maxHeight: .infinity)
        }

        var result: [Line] = []
        var views: [View] = []
        var measured: [Size] = []
        var mainSizes: [Double] = []
        var used: Double = 0
        var crossMaximum: Double = 0

        func finishLine() {
            guard !views.isEmpty else { return }
            result.append(Line(
                views: views,
                measured: measured,
                mainSizes: mainSizes,
                naturalMain: used,
                naturalCross: crossMaximum))
            views.removeAll(keepingCapacity: true)
            measured.removeAll(keepingCapacity: true)
            mainSizes.removeAll(keepingCapacity: true)
            used = 0
            crossMaximum = 0
        }

        for view in visible {
            let measuredSize = view.measure(measurement)
            let extent = FlexibleLayoutResolver.clamp(
                view.layoutBasis ?? main(measuredSize), for: view)
            let addition = (views.isEmpty ? 0 : mainGap) + extent
            if wrap == .wrap, !views.isEmpty,
               finiteLimit.isFinite, used + addition > finiteLimit
            {
                finishLine()
            }
            if !views.isEmpty { used += mainGap }
            views.append(view)
            measured.append(measuredSize)
            mainSizes.append(extent)
            used += extent
            crossMaximum = max(crossMaximum, cross(measuredSize))
        }
        finishLine()
        return result
    }

    private func itemBaselineOffsets(line: Line, lineCross: Double) -> [Double]? {
        guard direction == .row,
              itemAlignment == .firstBaseline || itemAlignment == .lastBaseline
        else { return nil }
        var positions: [Double] = []
        for index in line.views.indices {
            let itemCross = min(cross(line.measured[index]), lineCross)
            let size = Size(width: line.mainSizes[index], height: itemCross)
            let metrics = (line.views[index] as? any LayoutBaselineProviding)?
                .layoutBaselines(for: size)
            let position: Double
            if itemAlignment == .firstBaseline {
                position = metrics?.firstFromTop ?? itemCross
            } else if itemAlignment == .lastBaseline {
                position = itemCross - (metrics?.lastFromBottom ?? 0)
            } else {
                position = 0
            }
            positions.append(position)
        }
        let reference = positions.max() ?? 0
        return positions.map { max(0, reference - $0) }
    }

    private func alignmentOffset(itemCross: Double, lineCross: Double) -> Double {
        switch itemAlignment {
        case .leading, .stretch, .firstBaseline, .lastBaseline:
            0
        case .center:
            max(0, (lineCross - itemCross) / 2)
        case .trailing:
            max(0, lineCross - itemCross)
        }
    }

    private var mainGap: Double {
        direction == .row ? columnGap : rowGap
    }

    private var crossGap: Double {
        direction == .row ? rowGap : columnGap
    }

    private func mainMaximum(in constraints: LayoutConstraints) -> Double {
        direction == .row ? constraints.maxWidth : constraints.maxHeight
    }

    private func main(_ size: Size) -> Double {
        direction == .row ? size.width : size.height
    }

    private func cross(_ size: Size) -> Double {
        direction == .row ? size.height : size.width
    }

    private func size(main: Double, cross: Double) -> Size {
        direction == .row
            ? Size(width: main, height: cross)
            : Size(width: cross, height: main)
    }

    private func frame(
        mainOrigin: Double, crossOrigin: Double,
        main: Double, cross: Double
    ) -> Rect {
        direction == .row
            ? Rect(
                x: mainOrigin, y: crossOrigin,
                width: main, height: cross)
            : Rect(
                x: crossOrigin, y: mainOrigin,
                width: cross, height: main)
    }
}
