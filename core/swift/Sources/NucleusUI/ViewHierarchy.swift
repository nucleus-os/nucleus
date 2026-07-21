extension View {
    package func detachFromSwiftTree(
        clearOwningViewController: Bool = true
    ) {
        if parentView != nil || parentWindow != nil {
            notifyRetainedHierarchyWillDetach()
        }
        window?.windowScene?.cancelInputSequences(capturedBy: self)
        if let parentView {
            guard let index = parentView.childViewIndices[id] else {
                preconditionFailure("attached child is absent from its parent index")
            }
            parentView.childViews.remove(at: index)
            parentView.childViewsByID[id] = nil
            parentView.childViewIndices[id] = nil
            parentView.reindexChildren(startingAt: index)
            parentView.recordMutation(.structure)
            parentView.markSubtreeNeedsLayout()
            parentView.markSubtreeNeedsDisplay()
        }
        if let parentWindow, parentWindow.rootView === self {
            parentWindow.rootView = nil
        }
        if clearOwningViewController,
           let owningViewController,
           owningViewController.rootView === self
        {
            owningViewController.clearLoadedView()
        }
        parentView = nil
        parentWindow = nil
        if clearOwningViewController {
            owningViewController = nil
        }
    }

    package func notifyRetainedHierarchyWillDetach() {
        cancelOwnedObservations()
        if let owningViewController,
           owningViewController.rootView === self
        {
            owningViewController.cancelOwnedObservations()
        }
        retainedHierarchyWillDetach()
        for child in childViews {
            child.notifyRetainedHierarchyWillDetach()
        }
    }

    public var superview: View? { parentView }
    public var subviews: [View] { childViews }

    public var window: Window? {
        var node: View? = self
        while let current = node {
            if let window = current.parentWindow { return window }
            node = current.parentView
        }
        return nil
    }

    package func reindexChildren(startingAt start: Int) {
        guard start < childViews.endIndex else { return }
        childViewIndices.reserveCapacity(childViews.count)
        for index in start..<childViews.endIndex {
            let child = childViews[index]
            childViewsByID[child.id] = child
            childViewIndices[child.id] = index
        }
    }

    package func isDescendant(of ancestor: View) -> Bool {
        var node = parentView
        while let current = node {
            if current === ancestor { return true }
            node = current.parentView
        }
        return false
    }

    package func defaultButton() -> Button? {
        if let button = self as? Button,
           button.isDefaultButton,
           button.isEnabled,
           !button.isHidden
        {
            return button
        }
        for child in childViews {
            if let button = child.defaultButton() { return button }
        }
        return nil
    }
}
