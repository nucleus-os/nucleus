import Testing
import NucleusUI

@MainActor
@Suite(.uiContext) struct ContainerLayoutTests {
    final class FixedView: View {
        let desired: Size

        init(_ width: Double, _ height: Double) {
            desired = Size(width: width, height: height)
            super.init()
        }

        override var intrinsicContentSize: Size { desired }
    }

    @Test func flexWrapsRowsWithIndependentGaps() {
        let flex = FlexView()
        flex.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        flex.columnGap = 10
        flex.rowGap = 7
        let views = (0..<3).map { _ in FixedView(45, 20) }
        for view in views { flex.addArrangedSubview(view) }

        flex.layoutIfNeeded()

        #expect(views[0].frame == Rect(x: 0, y: 0, width: 45, height: 20))
        #expect(views[1].frame == Rect(x: 55, y: 0, width: 45, height: 20))
        #expect(views[2].frame == Rect(x: 0, y: 27, width: 45, height: 20))
    }

    @Test func eachFlexLineResolvesGrowIndependently() {
        let flex = FlexView()
        flex.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        flex.columnGap = 10
        let first = FixedView(40, 20)
        let second = FixedView(40, 20)
        let third = FixedView(60, 20)
        first.growFactor = 1
        second.growFactor = 1
        third.growFactor = 1
        flex.addArrangedSubview(first)
        flex.addArrangedSubview(second)
        flex.addArrangedSubview(third)

        flex.layoutIfNeeded()

        #expect(first.frame.size.width == 45)
        #expect(second.frame.size.width == 45)
        #expect(third.frame.size.width == 100, "the second line owns its full width")
    }

    @Test func flexLineAlignmentIsDeterministicAtFractionalSizes() {
        let flex = FlexView()
        flex.frame = Rect(x: 0, y: 0, width: 100.5, height: 80.5)
        flex.rowGap = 3.25
        flex.lineAlignment = .spaceBetween
        let first = FixedView(60, 10.5)
        let second = FixedView(60, 10.5)
        flex.addArrangedSubview(first)
        flex.addArrangedSubview(second)

        flex.layoutIfNeeded()
        let firstResult = [first.frame, second.frame]
        flex.setNeedsLayout()
        flex.layoutIfNeeded()

        #expect([first.frame, second.frame] == firstResult)
        #expect(second.frame.origin.y + second.frame.size.height == 80.5)
    }

    @Test func gridResolvesFixedContentAndFlexibleColumns() {
        let grid = GridView(columns: [
            .fixed(20),
            .content(minimum: 10, maximum: 40),
            .flexible(minimum: 10, weight: 1),
        ])
        grid.columnGap = 5
        grid.frame = Rect(x: 0, y: 0, width: 120, height: 40)
        let first = FixedView(100, 20)
        let second = FixedView(30, 20)
        let third = FixedView(10, 20)
        grid.addArrangedSubview(first)
        grid.addArrangedSubview(second)
        grid.addArrangedSubview(third)

        grid.layoutIfNeeded()

        #expect(first.frame.size.width == 20)
        #expect(second.frame.size.width == 30)
        #expect(third.frame.size.width == 60)
        #expect(third.frame.origin.x + third.frame.size.width == 120)
    }

    @Test func gridContentRowsRemeasureAgainstResolvedColumnWidth() {
        final class WrappingView: View {
            override func measure(_ constraints: LayoutConstraints) -> Size {
                let width = constraints.proposedWidth ?? 100
                return constraints.constrain(Size(
                    width: width,
                    height: width < 50 ? 40 : 20))
            }
        }

        let grid = GridView(columns: [.flexible(), .flexible()])
        grid.rows = [.content(), .flexible()]
        grid.columnGap = 10
        grid.rowGap = 4
        grid.frame = Rect(x: 0, y: 0, width: 90, height: 100)
        let wrapping = WrappingView()
        let peer = FixedView(10, 10)
        let nextRow = FixedView(10, 15)
        grid.addArrangedSubview(wrapping)
        grid.addArrangedSubview(peer)
        grid.addArrangedSubview(nextRow)

        grid.layoutIfNeeded()

        #expect(wrapping.frame.size.width == 40)
        #expect(wrapping.frame.size.height == 40)
        #expect(nextRow.frame.origin.y == 44)
        #expect(nextRow.frame.size.height == 56, "flexible implicit row consumes remaining height")
    }

    @Test func invalidGridTracksCanonicalizeWithoutNaN() {
        let grid = GridView(columns: [
            .fixed(.nan),
            .content(minimum: -.infinity, maximum: .nan),
            .flexible(minimum: .infinity, maximum: -.infinity, weight: .nan),
        ])
        grid.frame = Rect(x: 0, y: 0, width: 90, height: 20)
        let views = (0..<3).map { _ in FixedView(10, 10) }
        for view in views { grid.addArrangedSubview(view) }

        grid.layoutIfNeeded()

        for view in views {
            #expect(view.frame.isFinite)
            #expect(view.frame.size.width >= 0)
        }
    }
}
