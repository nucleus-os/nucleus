/// Runs layout and display as two ordered passes over a set of roots.
///
/// Layout used to happen incidentally: the publisher called `layoutIfNeeded()`
/// on each view as it walked the tree to snapshot it. That interleaves three
/// jobs with different orderings — a `layout()` writes descendant frames, so a
/// tree being snapshotted top-down was reading geometry that later nodes were
/// still free to change, and a view could be captured before its own parent had
/// finished placing it.
///
/// Here layout completes for the whole tree, then display, then whoever asked
/// reads a tree that is entirely settled. The ordering *is* the mechanism.
@MainActor
public enum LayoutScheduler {
    /// Whether any root has outstanding layout or display work.
    public static func hasPendingWork(roots: [View]) -> Bool {
        roots.contains {
            $0.needsLayout || $0.subtreeLayoutNeedsUpdate ||
                $0.needsDisplay || $0.subtreeDisplayNeedsUpdate
        }
    }

    /// Settle `roots`: all layout first, then all display. Both passes skip
    /// clean subtrees, so a steady-state frame with nothing dirty costs one
    /// flag check per root.
    public static func run(roots: [View]) {
        for root in roots {
            root.layoutIfNeeded()
        }
        // Display strictly after layout: `draw(in:)` reads `bounds`, which
        // layout may have just changed. Running them per-view interleaved is
        // what let a view paint at a stale size for one frame.
        for root in roots {
            root.displayIfNeeded()
        }
    }
}
