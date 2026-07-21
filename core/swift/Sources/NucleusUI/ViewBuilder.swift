/// Builds a list of subviews from a nested expression.
///
/// Construction only. The result of a builder is a set of views a container
/// adopts once; nothing here observes, diffs, or re-runs. A view placed inside a
/// builder is an ordinary object the surface goes on to mutate through its
/// properties — which is why a stored property can be written directly into the
/// expression and still be the thing `update()` changes later.
@MainActor
@resultBuilder
public enum ViewBuilder {
    public static func buildBlock(_ components: [View]...) -> [View] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ view: View) -> [View] {
        [view]
    }

    public static func buildExpression(_ views: [View]) -> [View] {
        views
    }

    /// An expression producing nothing — a `nil` optional view, or a statement
    /// with no result.
    public static func buildExpression(_ view: View?) -> [View] {
        view.map { [$0] } ?? []
    }

    public static func buildOptional(_ component: [View]?) -> [View] {
        component ?? []
    }

    public static func buildEither(first component: [View]) -> [View] {
        component
    }

    public static func buildEither(second component: [View]) -> [View] {
        component
    }

    public static func buildArray(_ components: [[View]]) -> [View] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ component: [View]) -> [View] {
        component
    }
}

extension View {
    /// Replace this view's subviews with the ones the builder produces.
    ///
    /// The structural counterpart to setting a property: use it once to describe
    /// what a view contains, then mutate the views themselves for everything
    /// that changes afterwards. Calling it again genuinely replaces the subtree,
    /// which is the escape hatch for structure that changes — not the update
    /// path.
    ///
    /// Views already installed and still present are kept rather than detached
    /// and re-added, so re-running a body does not disturb their identity, their
    /// first-responder status, or their cached drawing.
    public func setBody(@ViewBuilder _ body: () -> [View]) {
        let desired = body()
        for existing in childViews where !desired.contains(where: { $0 === existing }) {
            existing.removeFromSuperview()
        }
        for view in desired {
            // `addSubview` moves a view that already has a different parent, and
            // re-appends one that is already here — which would reorder it.
            if view.parentView !== self {
                addSubview(view)
            }
        }
        reorderSubviews(toMatch: desired)
    }

    /// Put `childViews` into `desired`'s order without detaching retained views.
    private func reorderSubviews(toMatch desired: [View]) {
        guard childViews.count == desired.count else { return }
        guard zip(childViews, desired).contains(where: { $0 !== $1 }) else {
            return
        }
        childViews = desired
        reindexChildren(startingAt: childViews.startIndex)
        recordMutation(.structure)
        markSubtreeNeedsLayout()
        markSubtreeNeedsDisplay()
    }
}

extension StackView {
    /// Replace this stack's arranged subviews with the ones the builder produces.
    ///
    /// A stack arranges what it is given, so its body populates
    /// `arrangedSubviews` rather than plain subviews. Views already arranged are
    /// kept — including their layers and focus — and only the order and the
    /// membership change.
    public func setArrangedBody(@ViewBuilder _ body: () -> [View]) {
        replaceArrangedSubviews(with: body())
    }
}
