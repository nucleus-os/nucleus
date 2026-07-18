import Testing
import NucleusUI

/// The view builder describes *construction*. The property these tests exist to
/// pin is that it never becomes an update mechanism: a view written into a body
/// is the same object afterwards, so a surface mutates it through its properties
/// rather than by re-describing it.
@MainActor
@Suite struct ViewBuilderTests {
    @Test func aBodyInstallsItsViewsInOrder() {
        let root = View()
        let first = Label("one")
        let second = Label("two")

        root.setBody {
            first
            second
        }

        #expect(root.subviews.count == 2)
        #expect(root.subviews[0] === first)
        #expect(root.subviews[1] === second)
        #expect(first.superview === root)
    }

    @Test func nestedBodiesBuildATree() {
        let root = View()
        let inner = View()
        let leaf = Label("leaf")
        inner.setBody { leaf }
        root.setBody { inner }

        #expect(root.subviews.count == 1)
        #expect(root.subviews[0] === inner)
        #expect(inner.subviews[0] === leaf)
    }

    /// The heart of the authoring decision. A stored property placed in a body
    /// stays the object the surface holds, so updating means setting a property
    /// — no diffing, no re-description.
    @Test func aViewInABodyIsTheSameObjectTheSurfaceMutates() {
        final class Widget: View {
            let label = Label("initial")

            override init() {
                super.init()
                setBody { label }
            }

            func update(_ text: String) {
                label.text = text
            }
        }

        let widget = Widget()
        #expect(widget.subviews[0] === widget.label)

        widget.update("changed")
        #expect(widget.label.text == "changed")
        #expect(widget.subviews[0] === widget.label, "still the same object")
    }

    // MARK: - Control flow

    @Test func anOptionalViewContributesNothingWhenNil() {
        let root = View()
        let shown = Label("shown")
        let hidden: Label? = nil

        root.setBody {
            shown
            hidden
        }
        #expect(root.subviews.count == 1)
    }

    @Test func aConditionalPicksOneBranch() {
        let root = View()
        let yes = Label("yes")
        let no = Label("no")
        let flag = true

        root.setBody {
            if flag { yes } else { no }
        }
        #expect(root.subviews.count == 1)
        #expect(root.subviews[0] === yes)
    }

    @Test func aLoopContributesEveryIteration() {
        let root = View()
        let rows = (0..<4).map { Label("\($0)") }

        root.setBody {
            for row in rows { row }
        }
        #expect(root.subviews.count == 4)
        #expect(root.subviews[3] === rows[3])
    }

    @Test func anArrayExpressionSplicesIn() {
        let root = View()
        let rows = (0..<3).map { Label("\($0)") }
        let trailing = Label("last")

        root.setBody {
            rows
            trailing
        }
        #expect(root.subviews.count == 4)
        #expect(root.subviews[3] === trailing)
    }

    @Test func anEmptyBodyRemovesEverything() {
        let root = View()
        root.setBody { Label("gone") }
        #expect(root.subviews.count == 1)

        root.setBody { }
        #expect(root.subviews.isEmpty)
    }

    // MARK: - Rebuilding

    /// Rebuilding is the escape hatch for structure that genuinely changes. A
    /// view present in both bodies is kept rather than detached and re-added —
    /// otherwise a rebuild would drop its layer, its focus, and its cached
    /// drawing for no reason.
    @Test func rebuildingKeepsViewsThatAreStillPresent() {
        let root = View()
        let kept = Label("kept")
        let dropped = Label("dropped")
        let added = Label("added")

        root.setBody {
            kept
            dropped
        }
        root.setBody {
            kept
            added
        }

        #expect(root.subviews.count == 2)
        #expect(root.subviews.contains { $0 === kept })
        #expect(root.subviews.contains { $0 === added })
        #expect(!root.subviews.contains { $0 === dropped })
        #expect(dropped.superview == nil, "and the dropped one really left")
    }

    /// A kept view does not lose keyboard focus to a rebuild.
    @Test func rebuildingDoesNotDisturbFocus() {
        let root = View()
        root.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        let field = TextField(string: "typed")
        let other = Label("other")
        let window = Window(title: "Body")
        window.setContentView(root)
        window.orderFront()

        withExtendedLifetime(window) {
            root.setBody { field }
            #expect(window.makeFirstResponder(field))

            root.setBody {
                field
                other
            }
            #expect(window.firstResponder === field, "focus survived the rebuild")
            #expect(field.stringValue == "typed", "and so did its contents")
        }
    }

    @Test func rebuildingReordersWithoutReplacing() {
        let root = View()
        let first = Label("one")
        let second = Label("two")

        root.setBody {
            first
            second
        }
        root.setBody {
            second
            first
        }

        #expect(root.subviews[0] === second)
        #expect(root.subviews[1] === first)
    }

    // MARK: - Stacks

    @Test func aStackBodyPopulatesArrangedSubviews() {
        let stack = StackView(axis: .vertical, spacing: 4, alignment: .fill)
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        let first = Label("one")
        let second = Label("two")

        stack.setArrangedBody {
            first
            second
        }

        #expect(stack.arrangedSubviews.count == 2)
        #expect(stack.arrangedSubviews[0] === first)
        #expect(stack.subviews.contains { $0 === first }, "arranged views are subviews too")

        stack.layoutIfNeeded()
        #expect(second.frame.origin.y > first.frame.origin.y, "and they lay out")
    }

    @Test func aStackBodyRebuildsAndReorders() {
        let stack = StackView(axis: .vertical)
        stack.frame = Rect(x: 0, y: 0, width: 100, height: 200)
        let kept = Label("kept")
        let dropped = Label("dropped")

        stack.setArrangedBody {
            kept
            dropped
        }
        stack.setArrangedBody { kept }

        #expect(stack.arrangedSubviews.count == 1)
        #expect(stack.arrangedSubviews[0] === kept)
        #expect(dropped.superview == nil)
    }

    @Test func aStackBodyOrdersFromTheExpression() {
        let stack = StackView(axis: .vertical)
        let first = Label("one")
        let second = Label("two")

        stack.setArrangedBody {
            first
            second
        }
        stack.setArrangedBody {
            second
            first
        }

        #expect(stack.arrangedSubviews[0] === second)
        #expect(stack.arrangedSubviews[1] === first)
    }
}
