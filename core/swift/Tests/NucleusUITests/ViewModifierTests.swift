import Testing
import NucleusUI

/// Chainable configuration. The contract is narrow on purpose: a modifier sets
/// the property of the same name, returns `self`, and does nothing else — so
/// these tests mostly check that setting through a modifier and setting the
/// property directly are indistinguishable.
@MainActor
@Suite(.uiContext) struct ViewModifierTests {
    // MARK: - Sugar, not a second API

    /// The property is always reachable directly. A modifier that did something
    /// its property could not would be a second way to configure a view, which
    /// is what the authoring model rules out.
    @Test func aModifierAndItsPropertyAgree() {
        let byModifier = View().cornerRadius(6).opacity(0.5).hidden(true)

        let byProperty = View()
        byProperty.cornerRadius = 6
        byProperty.alphaValue = 0.5
        byProperty.isHidden = true

        #expect(byModifier.cornerRadius == byProperty.cornerRadius)
        #expect(byModifier.alphaValue == byProperty.alphaValue)
        #expect(byModifier.isHidden == byProperty.isHidden)
    }

    @Test func modifiersReturnTheSameObject() {
        let view = View()
        #expect(view.cornerRadius(4) === view)
        #expect(view.width(10).height(20) === view)
    }

    /// Chaining on a subclass keeps the subclass type, so subclass modifiers
    /// remain reachable after a `View` modifier.
    @Test func chainingPreservesTheConcreteType() {
        let label = Label("hi").cornerRadius(2).text("bye")
        #expect(label.text == "bye")
        #expect(label.cornerRadius == 2)
    }

    // MARK: - Geometry

    @Test func sizingModifiersSetTheFrame() {
        let view = View().size(width: 30, height: 12)
        #expect(view.frame.size == Size(width: 30, height: 12))

        view.width(40)
        #expect(view.frame.size == Size(width: 40, height: 12))
        view.height(8)
        #expect(view.frame.size == Size(width: 40, height: 8))
    }

    /// Sizing does not move the view: only the size changes.
    @Test func sizingLeavesTheOriginAlone() {
        let view = View()
        view.frame = Rect(x: 5, y: 7, width: 1, height: 1)
        view.size(width: 30, height: 12)
        #expect(view.frame.origin == Point(x: 5, y: 7))
    }

    @Test func flexModifiersSetTheirFactors() {
        let view = View().grow(2).shrink(0).basis(44)
        #expect(view.growFactor == 2)
        #expect(view.shrinkFactor == 0)
        #expect(view.layoutBasis == 44)

        view.basis(nil)
        #expect(view.layoutBasis == nil)
    }

    // MARK: - The escape hatch

    /// Present so the modifier list never has to grow for a one-off.
    @Test func configureReachesAnythingElse() {
        let field = TextField().configure { $0.caretColor = Color(1, 0, 0, 1) }
        #expect(field.caretColor == Color(1, 0, 0, 1))
    }

    @Test func configureSeesTheConcreteType() {
        let label = Label("x").configure { $0.numberOfLines = 3 }
        #expect(label.numberOfLines == 3)
    }

    // MARK: - Per-type modifiers

    @Test func labelModifiersSetTextProperties() {
        let label = Label()
            .text("Nucleus")
            .font(.systemFont(ofSize: 11))
            .numberOfLines(2)
            .lineBreakMode(.byWordWrapping)

        #expect(label.text == "Nucleus")
        #expect(label.font.pointSize == 11)
        #expect(label.numberOfLines == 2)
        #expect(label.lineBreakMode == .byWordWrapping)
    }

    @Test func stackModifiersSetArrangement() {
        let stack = StackView()
            .axis(.horizontal)
            .spacing(6)
            .alignment(.center)
            .distribution(.fillEqually)
            .padding(4)

        #expect(stack.axis == .horizontal)
        #expect(stack.spacing == 6)
        #expect(stack.alignment == .center)
        #expect(stack.distribution == .fillEqually)
        #expect(stack.layoutMargins == EdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
    }

    @Test func textFieldModifiersSetEntryBehaviour() {
        let field = TextField()
            .placeholder("Password")
            .secure()
            .maximumLength(64)

        #expect(field.placeholderString == "Password")
        #expect(field.isSecure)
        #expect(field.maximumLength == 64)
    }

    /// Secure entry still overrides a configured content type, whichever way it
    /// was set — a modifier cannot route around the guarantee.
    @Test func secureEntryStillWinsOverAContentTypeModifier() {
        let field = TextField().contentType(.email).secure()
        #expect(field.textInputContentType == .password)
    }

    @Test func buttonModifiersSetTitleAndEnablement() {
        let button = Button(title: "old").title("new").enabled(false)
        #expect(button.title == "new")
        #expect(!button.isEnabled)
    }

    @Test func callbackModifiersInstallHandlers() {
        var submitted = 0
        let field = TextField(string: "x").onSubmit { _ in submitted += 1 }
        _ = field.handleEvent(Event(type: .keyDown, keyCode: .return))
        #expect(submitted == 1)
    }

    // MARK: - In a body

    /// What the whole phase is for: structure and configuration in one
    /// expression, with the views still ordinary objects afterwards.
    @Test func modifiersReadAsOneExpressionInABody() {
        final class Bar: View {
            let clock = Label("00:00")
            let spacer = View()
            let battery = Label("100%")

            override init() {
                super.init()
                setBody {
                    StackView()
                        .axis(.horizontal)
                        .spacing(8)
                        .padding(4)
                        .configure {
                            $0.setArrangedBody {
                                clock.textColor(Color(1, 1, 1, 1))
                                spacer.grow(1)
                                battery.numberOfLines(1)
                            }
                        }
                }
            }
        }

        let bar = Bar()
        bar.frame = Rect(x: 0, y: 0, width: 300, height: 26)
        bar.layoutIfNeeded()

        let stack = bar.subviews[0]
        #expect(stack.subviews.count == 3)
        #expect(bar.spacer.growFactor == 1)

        // Still ordinary objects: updating is a property set, not a rebuild.
        bar.clock.text = "12:34"
        #expect(bar.clock.text == "12:34")
        #expect(bar.subviews[0].subviews[0] === bar.clock)
    }
}
