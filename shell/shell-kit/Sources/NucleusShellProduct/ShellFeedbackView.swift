public import NucleusUI

/// Shell-owned transient feedback presented on a privileged layer surface.
@MainActor
public final class ShellFeedbackView: View {
    public let backgroundEffectView: VisualEffectView
    public let titleLabel: Label
    public let bodyLabel: Label
    private var actionButtons: [Button] = []

    public override init() {
        backgroundEffectView = VisualEffectView(
            material: .popover,
            state: .active,
            cornerRadius: 14)
        titleLabel = Label("")
        bodyLabel = Label("")
        super.init()
        addSubview(backgroundEffectView)
        addSubview(titleLabel)
        addSubview(bodyLabel)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.numberOfLines = 20
        bodyLabel.lineBreakMode = .byWordWrapping
        isAccessibilityElement = true
        accessibilityRole = .window
    }

    public func showHotkeys(_ descriptions: [String]) {
        removeActionButtons()
        titleLabel.text = "Nucleus Keybindings"
        bodyLabel.text = descriptions.joined(separator: "\n")
        bodyLabel.isHidden = false
        accessibilityLabel = "Keyboard shortcuts"
        accessibilityChildren = [titleLabel, bodyLabel]
        setNeedsLayout()
    }

    public func showWindowMenu(
        capabilities: UInt32,
        perform: @escaping @MainActor (UInt32) -> Void
    ) {
        removeActionButtons()
        titleLabel.text = "Window"
        bodyLabel.isHidden = true
        let commands: [(UInt32, String, UInt32)] = [
            (1, "Minimize", 1 << 1),
            (2, "Zoom", 1 << 2),
            (4, "Move", 1 << 4),
            (5, "Resize", 1 << 5),
            (3, "Enter Full Screen", 1 << 3),
            (0, "Close", 1 << 0),
        ]
        for (verb, title, requiredCapability) in commands
        where capabilities & requiredCapability != 0
        {
            let button = Button(title: title)
            button.onPress { _ in perform(verb) }
            addSubview(button)
            actionButtons.append(button)
        }
        accessibilityLabel = "Window menu"
        accessibilityChildren = [titleLabel] + actionButtons
        setNeedsLayout()
    }

    public override func layout() {
        backgroundEffectView.frame = bounds
        let inset = 16.0
        titleLabel.frame = Rect(
            x: inset,
            y: inset,
            width: max(0, bounds.size.width - inset * 2),
            height: 24)
        if actionButtons.isEmpty {
            bodyLabel.frame = Rect(
                x: inset,
                y: 48,
                width: max(0, bounds.size.width - inset * 2),
                height: max(0, bounds.size.height - 64))
        } else {
            var y = 48.0
            for button in actionButtons {
                button.frame = Rect(
                    x: inset,
                    y: y,
                    width: max(0, bounds.size.width - inset * 2),
                    height: 30)
                y += 34
            }
        }
    }

    private func removeActionButtons() {
        for button in actionButtons {
            button.removeFromSuperview()
        }
        actionButtons.removeAll(keepingCapacity: true)
    }
}
