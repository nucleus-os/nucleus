extension View {
    public var needsIntrinsicContentSizeUpdate: Bool {
        intrinsicContentSizeNeedsUpdate
    }

    public var needsLayout: Bool { layoutNeedsUpdate }
    public var needsDisplay: Bool { displayNeedsUpdate }

    public var growFactor: Double {
        get { storedGrowFactor }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedGrowFactor else { return }
            storedGrowFactor = value
            parentView?.setNeedsLayout()
        }
    }

    public var shrinkFactor: Double {
        get { storedShrinkFactor }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedShrinkFactor else { return }
            storedShrinkFactor = value
            parentView?.setNeedsLayout()
        }
    }

    public var layoutBasis: Double? {
        get { storedLayoutBasis }
        set {
            let value = newValue.map { $0.isFinite ? max(0, $0) : 0 }
            guard value != storedLayoutBasis else { return }
            storedLayoutBasis = value
            parentView?.setNeedsLayout()
        }
    }

    public var minimumLayoutExtent: Double {
        get { storedMinimumLayoutExtent }
        set {
            let value = newValue.isFinite ? max(0, newValue) : 0
            guard value != storedMinimumLayoutExtent else { return }
            storedMinimumLayoutExtent = value
            if storedMaximumLayoutExtent < value {
                storedMaximumLayoutExtent = value
            }
            parentView?.setNeedsLayout()
        }
    }

    public var maximumLayoutExtent: Double {
        get { storedMaximumLayoutExtent }
        set {
            let value: Double
            if newValue == .infinity {
                value = .infinity
            } else if newValue.isFinite {
                value = max(storedMinimumLayoutExtent, max(0, newValue))
            } else {
                value = storedMinimumLayoutExtent
            }
            guard value != storedMaximumLayoutExtent else { return }
            storedMaximumLayoutExtent = value
            parentView?.setNeedsLayout()
        }
    }

    package func markSubtreeNeedsLayout() {
        var node: View? = self
        while let current = node, !current.subtreeLayoutNeedsUpdate {
            current.subtreeLayoutNeedsUpdate = true
            node = current.parentView
        }
    }

    package func markSubtreeNeedsDisplay() {
        var node: View? = self
        while let current = node, !current.subtreeDisplayNeedsUpdate {
            current.subtreeDisplayNeedsUpdate = true
            node = current.parentView
        }
    }

    package func invalidateDisplay(_ rect: Rect) {
        guard let damage = normalizedDisplayDamage(rect) else { return }
        if !displayNeedsUpdate {
            pendingDisplayDamage = damage
        } else if damage == .zero {
            pendingDisplayDamage = .zero
        } else if let pendingDisplayDamage,
                  pendingDisplayDamage != .zero
        {
            self.pendingDisplayDamage = pendingDisplayDamage.union(damage)
        }
        displayNeedsUpdate = true
        parentView?.markSubtreeNeedsDisplay()
    }

    private func normalizedDisplayDamage(_ rect: Rect) -> Rect? {
        guard rect.isFinite, !rect.isEmpty,
              bounds.isFinite, !bounds.isEmpty
        else { return nil }
        let left = max(rect.origin.x, bounds.origin.x)
        let top = max(rect.origin.y, bounds.origin.y)
        let right = min(
            rect.origin.x + rect.size.width,
            bounds.origin.x + bounds.size.width)
        let bottom = min(
            rect.origin.y + rect.size.height,
            bounds.origin.y + bounds.size.height)
        guard right > left, bottom > top else { return nil }
        let clipped = Rect(
            x: left - bounds.origin.x,
            y: top - bounds.origin.y,
            width: right - left,
            height: bottom - top)
        return clipped.origin == .zero && clipped.size == bounds.size
            ? .zero
            : clipped
    }

    public func layoutIfNeeded() {
        var work: [View] = [self]
        while let view = work.popLast() {
            guard view.layoutNeedsUpdate || view.subtreeLayoutNeedsUpdate else {
                continue
            }
            if view.layoutNeedsUpdate {
                view.layoutNeedsUpdate = false
                view.intrinsicContentSizeNeedsUpdate = false
                view.layout()
            }
            view.subtreeLayoutNeedsUpdate = false
            work.append(contentsOf: view.childViews.reversed())
        }
    }

    public func displayIfNeeded() {
        var work: [View] = [self]
        while let view = work.popLast() {
            guard view.displayNeedsUpdate || view.subtreeDisplayNeedsUpdate else {
                continue
            }
            if view.displayNeedsUpdate {
                let requestedDamage = view.pendingDisplayDamage
                view.displayNeedsUpdate = false
                view.pendingDisplayDamage = nil
                let context = GraphicsContext(
                    textSystem: view.uiContext.services.textSystem)
                view.storedStyle.draw(in: context, bounds: view.bounds)
                view.draw(in: context)
                view.drawFocusRing(in: context)
                let recording = context.recording
                if recording != view.cachedRecording {
                    view.cachedRecording = recording
                    view.cachedPaintDamage =
                        requestedDamage == .zero ? nil : requestedDamage
                    view.recordMutation(.content)
                }
            }
            view.subtreeDisplayNeedsUpdate = false
            work.append(contentsOf: view.childViews.reversed())
        }
    }
}
