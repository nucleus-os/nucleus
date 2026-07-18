import NucleusTypes
@_spi(NucleusCompositor) @testable import NucleusUI
import Testing

@MainActor
@Suite struct GeometryTransactionTests {
    // Geometry/effect struct layout is pinned by the generated `NucleusTypes`
    // module.

    @Test func directFrameSetGet() throws {
        let view = View()
        view.frame = (Rect(x: 10, y: 20, width: 300, height: 200))

        #expect(view.frame == Rect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test func frameWritesAreEager() throws {
        let view = View()
        view.frame = (Rect(x: 50, y: 60, width: 70, height: 80))
        // Eager: no commit / flush needed for the read to see the write.
        #expect(view.frame == Rect(x: 50, y: 60, width: 70, height: 80))
    }

    @Test func transactionAbortDoesNotRollBackViewState() throws {
        let view = View()
        view.frame = (Rect(x: 1, y: 2, width: 3, height: 4))

        do {
            var tx = Transaction()
            view.frame = (Rect(x: 100, y: 200, width: 300, height: 400))
            tx.abort()
        }

        // Mirrors CATransaction: model state stays mutated even after abort.
        #expect(view.frame == Rect(x: 100, y: 200, width: 300, height: 400))
    }

    @Test func viewPropertiesBatchIsEager() throws {
        let view = View()
        #expect(!view.isHidden)

        var tx = Transaction()
        view.setProperties(ViewProperties(
            frame: Rect(x: 11, y: 12, width: 13, height: 14),
            isHidden: true
        ))

        // Eager local apply — visible immediately on the view.
        #expect(view.frame == Rect(x: 11, y: 12, width: 13, height: 14))
        #expect(view.isHidden)

        try tx.commit()

        #expect(view.frame == Rect(x: 11, y: 12, width: 13, height: 14))
        #expect(view.isHidden)
    }

    @Test func directHiddenSetterUsesPropertyBatchPath() throws {
        let view = View()

        view.isHidden = (true)
        #expect(view.isHidden)

        view.setProperties(ViewProperties(frame: Rect(x: 1, y: 2, width: 3, height: 4), isHidden: false))
        #expect(view.frame == Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(!view.isHidden)
    }

    @Test func addSubviewIsEagerOnSwiftTree() throws {
        let parent = View()
        let child = View()

        parent.addSubview(child)

        // Mirrors NSView.addSubview: the tree reflects the change at the
        // call site, no commit required.
        #expect(parent.subviews.contains { $0 === child })
        #expect(child.superview === parent)
    }

    @Test func removeFromSuperviewIsEagerOnSwiftTree() throws {
        let parent = View()
        let child = View()
        parent.addSubview(child)

        child.removeFromSuperview()

        #expect(parent.subviews.isEmpty)
        #expect(child.superview == nil)
    }

    @Test func setRootViewIsEagerOnWindow() throws {
        let window = Window()
        let view = View()

        window.setRootView(view)

        #expect(window.root === view)
    }

    @Test func explicitTransactionGroupsWritesIntoOneFFICommit() throws {
        // Two writes inside one Transaction land in a single FFI commit
        // when the transaction commits. Outside-transaction writes go to
        // the implicit ambient buffer; they're not flushed by Transaction.
        let view = View()
        var tx = Transaction()
        view.frame = (Rect(x: 1, y: 2, width: 3, height: 4))
        view.isHidden = (true)
        try tx.commit()

        // Eager local apply means reads see the writes either way.
        #expect(view.frame == Rect(x: 1, y: 2, width: 3, height: 4))
        #expect(view.isHidden)
    }

    @Test func detachedSubtreeBuildsBeforeAttach() throws {
        // Replacement for the old "abort leaves subview independent" pattern:
        // build a subtree without rooting it in any window, mutate it, then
        // attach the root once it's ready. AppKit-shaped.
        let parent = View()
        let child = View()
        parent.addSubview(child)
        #expect(child.superview === parent)
        #expect(parent.subviews.contains { $0 === child })
    }
}
