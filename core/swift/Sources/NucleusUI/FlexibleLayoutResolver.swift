/// Shared freeze-and-redistribute flex sizing for stack and wrapping layouts.
@MainActor
package enum FlexibleLayoutResolver {
    package static func resolve(
        _ proposed: [Double], views: [View], available: Double
    ) -> [Double] {
        precondition(proposed.count == views.count)
        var sizes = proposed
        let available = available.isFinite
            ? max(0, available)
            : sizes.enumerated().reduce(0) {
                $0 + clamp($1.element, for: views[$1.offset])
            }
        for index in sizes.indices {
            sizes[index] = clamp(sizes[index], for: views[index])
        }
        let free = available - sizes.reduce(0, +)
        guard abs(free) > 0.0001 else { return sizes }

        if free > 0 {
            var remaining = free
            var active = Set(sizes.indices.filter {
                views[$0].growFactor > 0 &&
                    sizes[$0] < views[$0].maximumLayoutExtent
            })
            while remaining > 0.0001, !active.isEmpty {
                let totalGrow = active.reduce(0) {
                    $0 + views[$1].growFactor
                }
                guard totalGrow > 0 else { break }
                let frozen = active.filter {
                    sizes[$0] + remaining * views[$0].growFactor / totalGrow
                        >= views[$0].maximumLayoutExtent
                }
                if frozen.isEmpty {
                    for index in active {
                        sizes[index] += remaining
                            * views[index].growFactor / totalGrow
                    }
                    remaining = 0
                } else {
                    for index in frozen {
                        let capacity = max(
                            0, views[index].maximumLayoutExtent - sizes[index])
                        sizes[index] += capacity
                        remaining -= capacity
                        active.remove(index)
                    }
                }
            }
        } else {
            var remainingDeficit = -free
            var active = Set(sizes.indices.filter {
                views[$0].shrinkFactor > 0 &&
                    sizes[$0] > views[$0].minimumLayoutExtent
            })
            while remainingDeficit > 0.0001, !active.isEmpty {
                let totalWeight = active.reduce(0) {
                    $0 + views[$1].shrinkFactor * sizes[$1]
                }
                guard totalWeight > 0 else { break }
                let frozen = active.filter {
                    let weight = views[$0].shrinkFactor * sizes[$0]
                    let reduction = remainingDeficit * weight / totalWeight
                    return sizes[$0] - reduction <= views[$0].minimumLayoutExtent
                }
                if frozen.isEmpty {
                    for index in active {
                        let weight = views[index].shrinkFactor * sizes[index]
                        sizes[index] -= remainingDeficit * weight / totalWeight
                    }
                    remainingDeficit = 0
                } else {
                    for index in frozen {
                        let capacity = max(
                            0, sizes[index] - views[index].minimumLayoutExtent)
                        sizes[index] -= capacity
                        remainingDeficit -= capacity
                        active.remove(index)
                    }
                }
            }
        }
        return sizes
    }

    package static func clamp(_ extent: Double, for view: View) -> Double {
        let extent = extent.isFinite ? max(0, extent) : view.minimumLayoutExtent
        return min(
            max(extent, view.minimumLayoutExtent),
            view.maximumLayoutExtent)
    }
}
