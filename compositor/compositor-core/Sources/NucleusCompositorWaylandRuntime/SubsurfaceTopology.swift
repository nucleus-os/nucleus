/// Weak reference to a surface. Parent/child topology must never become an
/// ownership path for a resource whose wl_surface is its sole owner.
final class WeakSurfaceBox {
    weak var surface: WlSurface?

    init(_ surface: WlSurface) {
        self.surface = surface
    }
}

private enum SubsurfaceStackEntry {
    case selfContent
    case child(WeakSurfaceBox)
}

/// Pending/current topology and synchronized-commit state for one wl_surface.
/// The aggregate owns this mechanism; all wire requests mutate it through the
/// methods on `WlSurface` below.
final class SubsurfaceTopology {
    weak var parent: WlSurface?
    private(set) var x: Int32 = 0
    private(set) var y: Int32 = 0
    private var pendingPosition: (x: Int32, y: Int32)?
    var synchronized = false
    var cachedCommit: SurfaceTransaction?
    private var stack: [SubsurfaceStackEntry] = []
    private var pendingStack: [SubsurfaceStackEntry]?

    var children: [WlSurface] {
        stack.compactMap {
            if case .child(let child) = $0 {
                return child.surface
            }
            return nil
        }
    }

    func order(parentID: UInt32) -> [UInt32] {
        stack.compactMap {
            switch $0 {
            case .selfContent:
                return parentID
            case .child(let child):
                return child.surface?.objectId
            }
        }
    }

    func attach(owner: WlSurface, to parent: WlSurface) {
        self.parent = parent
        synchronized = true
        parent.subsurfaceTopology.addPendingChildOnTop(owner)
    }

    func detach(owner: WlSurface) {
        parent?.subsurfaceTopology.removeChild(owner)
        parent = nil
        pendingPosition = nil
    }

    func detachChildren(owner: WlSurface) {
        let detached = children
        stack.removeAll(keepingCapacity: false)
        pendingStack = nil
        for child in detached
        where child.subsurfaceTopology.parent === owner {
            child.subsurfaceTopology.parent = nil
            child.subsurfaceTopology.pendingPosition = nil
        }
    }

    func addPendingChildOnTop(_ child: WlSurface) {
        var next = pendingStack ?? stack
        if next.isEmpty {
            next = [.selfContent]
        }
        next.append(.child(WeakSurfaceBox(child)))
        pendingStack = next
    }

    func removeChild(_ child: WlSurface) {
        stack.removeAll { entry in
            if case .child(let candidate) = entry {
                return candidate.surface == nil
                    || candidate.surface === child
            }
            return false
        }
        pendingStack?.removeAll { entry in
            if case .child(let candidate) = entry {
                return candidate.surface == nil
                    || candidate.surface === child
            }
            return false
        }
    }

    func stagePosition(x: Int32, y: Int32) {
        pendingPosition = (x, y)
    }

    func applyPending() {
        if let pendingStack {
            stack = pendingStack
            self.pendingStack = nil
        }
        for child in children {
            child.subsurfaceTopology.applyPendingPosition()
        }
    }

    private func applyPendingPosition() {
        guard let pendingPosition else { return }
        x = pendingPosition.x
        y = pendingPosition.y
        self.pendingPosition = nil
    }

    @discardableResult
    func place(
        owner: WlSurface,
        child: WlSurface,
        relativeTo sibling: WlSurface,
        direction: WlSurface.PlaceDir
    ) -> Bool {
        guard child !== sibling else { return false }
        var next = pendingStack ?? stack
        guard let from = childIndex(child, in: next) else {
            return false
        }
        let entry = next.remove(at: from)
        let target = sibling === owner
            ? selfContentIndex(in: next)
            : childIndex(sibling, in: next)
        guard let target else { return false }
        let insertion = direction == .above ? target + 1 : target
        next.insert(entry, at: min(max(insertion, 0), next.count))
        pendingStack = next
        return true
    }

    private func childIndex(
        _ child: WlSurface,
        in stack: [SubsurfaceStackEntry]
    ) -> Int? {
        stack.firstIndex {
            if case .child(let candidate) = $0 {
                return candidate.surface === child
            }
            return false
        }
    }

    private func selfContentIndex(
        in stack: [SubsurfaceStackEntry]
    ) -> Int? {
        stack.firstIndex {
            if case .selfContent = $0 { return true }
            return false
        }
    }
}

extension WlSurface {
    var subsurfaceParent: WlSurface? {
        subsurfaceTopology.parent
    }

    var subsurfaceX: Int32 {
        subsurfaceTopology.x
    }

    var subsurfaceY: Int32 {
        subsurfaceTopology.y
    }

    var isEffectivelySync: Bool {
        guard let parent = subsurfaceParent else { return false }
        return subsurfaceTopology.synchronized
            || parent.isEffectivelySync
    }

    var subsurfaceChildren: [WlSurface] {
        subsurfaceTopology.children
    }

    var subsurfaceOrder: [UInt32] {
        subsurfaceTopology.order(parentID: objectId)
    }

    func attachAsSubsurface(to parent: WlSurface) {
        subsurfaceTopology.attach(owner: self, to: parent)
    }

    func detachFromParent() {
        subsurfaceTopology.detach(owner: self)
    }

    func detachSubsurfaceChildren() {
        subsurfaceTopology.detachChildren(owner: self)
    }

    func setSubsurfacePosition(x: Int32, y: Int32) {
        subsurfaceTopology.stagePosition(x: x, y: y)
    }

    func setSubsurfaceSync(_ sync: Bool) {
        let wasSync = isEffectivelySync
        subsurfaceTopology.synchronized = sync
        if wasSync,
            !isEffectivelySync,
            let cached = subsurfaceTopology.cachedCommit
        {
            subsurfaceTopology.cachedCommit = nil
            applyCachedSubsurfaceCommit(cached)
        }
    }

    enum PlaceDir {
        case above
        case below
    }

    @discardableResult
    func placeChild(
        _ child: WlSurface,
        relativeTo sibling: WlSurface,
        _ direction: PlaceDir
    ) -> Bool {
        subsurfaceTopology.place(
            owner: self,
            child: child,
            relativeTo: sibling,
            direction: direction)
    }

    func applyPendingSubsurfaceTopology() {
        subsurfaceTopology.applyPending()
    }

    func wouldCreateSubsurfaceCycle(parent: WlSurface) -> Bool {
        if parent === self { return true }
        var ancestor: WlSurface? = parent
        while let current = ancestor {
            if current === self { return true }
            ancestor = current.subsurfaceParent
        }
        return false
    }
}
