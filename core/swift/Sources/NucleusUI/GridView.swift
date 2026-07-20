/// One grid track's sizing policy.
public enum GridTrack: Sendable, Equatable {
    case fixed(Double)
    case flexible(minimum: Double = 0, maximum: Double = .infinity, weight: Double = 1)
    case content(minimum: Double = 0, maximum: Double = .infinity)
}

/// A row-major grid with fixed, flexible, and content-sized tracks.
@MainActor
open class GridView: View, ~Sendable {
    public var columns: [GridTrack] {
        didSet {
            if columns.isEmpty { columns = [.flexible()] }
            if columns != oldValue { setNeedsLayout() }
        }
    }

    /// Explicit row policies. Rows beyond this array are content-sized.
    public var rows: [GridTrack] = [] {
        didSet { if rows != oldValue { setNeedsLayout() } }
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

    public init(columns: [GridTrack] = [.flexible()]) {
        self.columns = columns.isEmpty ? [.flexible()] : columns
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
        let result = resolve(
            availableWidth: constraints.proposedWidth,
            availableHeight: constraints.proposedHeight)
        return constraints.constrain(result.size)
    }

    open override func layout() {
        let result = resolve(
            availableWidth: max(0, frame.size.width),
            availableHeight: max(0, frame.size.height))
        var y: Double = 0
        var itemIndex = 0
        for row in result.rowSizes.indices {
            var x: Double = 0
            for column in result.columnSizes.indices {
                guard itemIndex < result.views.count else { return }
                result.views[itemIndex].arrange(in: Rect(
                    x: x, y: y,
                    width: result.columnSizes[column],
                    height: result.rowSizes[row]))
                x += result.columnSizes[column] + columnGap
                itemIndex += 1
            }
            y += result.rowSizes[row] + rowGap
        }
    }

    private struct Resolution {
        var views: [View]
        var columnSizes: [Double]
        var rowSizes: [Double]
        var size: Size
    }

    private func resolve(
        availableWidth: Double?, availableHeight: Double?
    ) -> Resolution {
        let views = arranged.filter { !$0.isHidden }
        let columnCount = max(1, columns.count)
        let rowCount = views.isEmpty
            ? 0
            : (views.count + columnCount - 1) / columnCount
        let unconstrained = views.map { $0.measure(.unconstrained) }

        var columnContent = [Double](repeating: 0, count: columnCount)
        for index in views.indices {
            columnContent[index % columnCount] = max(
                columnContent[index % columnCount],
                unconstrained[index].width)
        }
        let columnSizes = resolveTracks(
            definitions: columns,
            content: columnContent,
            available: availableWidth,
            gap: columnGap)

        var rowContent = [Double](repeating: 0, count: rowCount)
        for index in views.indices {
            let width = columnSizes[index % columnCount]
            let measured = views[index].measure(LayoutConstraints(
                minWidth: width, maxWidth: width,
                minHeight: 0, maxHeight: .infinity))
            rowContent[index / columnCount] = max(
                rowContent[index / columnCount], measured.height)
        }
        var rowDefinitions = rows
        if rowDefinitions.count < rowCount {
            rowDefinitions.append(
                contentsOf: repeatElement(
                    .content(),
                    count: rowCount - rowDefinitions.count))
        } else if rowDefinitions.count > rowCount {
            rowDefinitions.removeLast(rowDefinitions.count - rowCount)
        }
        let rowSizes = resolveTracks(
            definitions: rowDefinitions,
            content: rowContent,
            available: availableHeight,
            gap: rowGap)
        let width = columnSizes.reduce(0, +)
            + columnGap * Double(max(0, columnSizes.count - 1))
        let height = rowSizes.reduce(0, +)
            + rowGap * Double(max(0, rowSizes.count - 1))
        return Resolution(
            views: views,
            columnSizes: columnSizes,
            rowSizes: rowSizes,
            size: Size(width: width, height: height))
    }

    private struct TrackPolicy {
        var minimum: Double
        var maximum: Double
        var weight: Double
        var isFlexible: Bool
        var canShrink: Bool
    }

    private func resolveTracks(
        definitions: [GridTrack],
        content: [Double],
        available: Double?,
        gap: Double
    ) -> [Double] {
        guard !definitions.isEmpty else { return [] }
        var policies: [TrackPolicy] = []
        var sizes: [Double] = []
        for index in definitions.indices {
            let desired = index < content.count && content[index].isFinite
                ? max(0, content[index])
                : 0
            let policy = canonical(definitions[index])
            policies.append(policy)
            if policy.isFlexible {
                sizes.append(
                    available == nil
                        ? min(max(desired, policy.minimum), policy.maximum)
                        : policy.minimum)
            } else if !policy.canShrink {
                sizes.append(policy.minimum)
            } else {
                sizes.append(min(max(desired, policy.minimum), policy.maximum))
            }
        }
        guard let available, available.isFinite else { return sizes }
        let trackSpace = max(
            0,
            available - gap * Double(max(0, definitions.count - 1)))
        var free = trackSpace - sizes.reduce(0, +)

        if free > 0 {
            var active = Set(sizes.indices.filter {
                policies[$0].isFlexible && policies[$0].weight > 0 &&
                    sizes[$0] < policies[$0].maximum
            })
            while free > 0.0001, !active.isEmpty {
                let totalWeight = active.reduce(0) {
                    $0 + policies[$1].weight
                }
                let frozen = active.filter {
                    sizes[$0] + free * policies[$0].weight / totalWeight
                        >= policies[$0].maximum
                }
                if frozen.isEmpty {
                    for index in active {
                        sizes[index] += free * policies[index].weight / totalWeight
                    }
                    free = 0
                } else {
                    for index in frozen {
                        let capacity = policies[index].maximum - sizes[index]
                        sizes[index] += capacity
                        free -= capacity
                        active.remove(index)
                    }
                }
            }
        } else if free < 0 {
            var deficit = -free
            var active = Set(sizes.indices.filter {
                policies[$0].canShrink && sizes[$0] > policies[$0].minimum
            })
            while deficit > 0.0001, !active.isEmpty {
                let total = active.reduce(0) { $0 + sizes[$1] }
                guard total > 0 else { break }
                let frozen = active.filter {
                    sizes[$0] - deficit * sizes[$0] / total
                        <= policies[$0].minimum
                }
                if frozen.isEmpty {
                    for index in active {
                        sizes[index] -= deficit * sizes[index] / total
                    }
                    deficit = 0
                } else {
                    for index in frozen {
                        let capacity = sizes[index] - policies[index].minimum
                        sizes[index] -= capacity
                        deficit -= capacity
                        active.remove(index)
                    }
                }
            }
        }
        return sizes
    }

    private func canonical(_ track: GridTrack) -> TrackPolicy {
        func range(
            minimum: Double, maximum: Double
        ) -> (Double, Double) {
            let minimum = minimum.isFinite ? max(0, minimum) : 0
            let canonicalMaximum: Double
            if maximum == .infinity {
                canonicalMaximum = .infinity
            } else if maximum.isFinite {
                canonicalMaximum = max(minimum, max(0, maximum))
            } else {
                canonicalMaximum = minimum
            }
            return (minimum, canonicalMaximum)
        }

        switch track {
        case .fixed(let extent):
            let extent = extent.isFinite ? max(0, extent) : 0
            return TrackPolicy(
                minimum: extent, maximum: extent,
                weight: 0, isFlexible: false, canShrink: false)
        case .flexible(let minimum, let maximum, let weight):
            let range = range(minimum: minimum, maximum: maximum)
            return TrackPolicy(
                minimum: range.0, maximum: range.1,
                weight: weight.isFinite ? max(0, weight) : 0,
                isFlexible: true, canShrink: true)
        case .content(let minimum, let maximum):
            let range = range(minimum: minimum, maximum: maximum)
            return TrackPolicy(
                minimum: range.0, maximum: range.1,
                weight: 0, isFlexible: false, canShrink: true)
        }
    }
}
