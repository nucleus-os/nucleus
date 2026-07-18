import NucleusUI
import NucleusUIEmbedder

struct ShellOverlayHotkeyEntry: Sendable, Equatable {
    var key: String
    var description: String

    init(key: String, description: String) {
        self.key = key
        self.description = description
    }
}

let shellOverlayHotkeyEntries: [ShellOverlayHotkeyEntry] = [
    .init(key: "Super + T", description: "Launch Kitty"),
    .init(key: "Super + F", description: "Launch Foot"),
    .init(key: "Super + S", description: "Launch Sublime Text"),
    .init(key: "Super + C", description: "Launch Chrome"),
    .init(key: "Super + Q", description: "Close Window"),
    .init(key: "", description: ""),
    .init(key: "Ctrl+Alt + Arrow", description: "Tile Half"),
    .init(key: "Ctrl+Alt + U/I/J/K", description: "Tile Quarter"),
    .init(key: "Ctrl+Alt + Return", description: "Maximize"),
    .init(key: "", description: ""),
    .init(key: "Super + P", description: "Screenshot to ~/Pictures"),
    .init(key: "Super + /", description: "Toggle This Overlay"),
    .init(key: "Ctrl+Alt + Backspace", description: "Exit Compositor"),
]

struct ShellOverlayHotkeyMetrics: Sendable, Equatable {
    var backingScaleFactor: BackingScaleFactor
    var fontSize: Float
    var titleSize: Float
    var footerSize: Float
    var hairlineWidth: Float
    var lineH: Float
    var pad: Float
    var colGap: Float
    var keyColW: Float
    var sepY: Float
    var rowStartY: Float
    var rowTextHeight: Float
    var rowBaselineOffset: Float
    var titleTextHeight: Float
    var titleBaselineOffset: Float
    var footerTextHeight: Float
    var footerBaselineOffset: Float

    init(backingScaleFactor: BackingScaleFactor = .one) {
        self.backingScaleFactor = backingScaleFactor
        fontSize = 14
        titleSize = 20
        footerSize = 11
        hairlineWidth = Float(backingScaleFactor.singlePixelLength)
        let rowLayout = TextLayout(text: "Hg", font: .systemFont(ofSize: fontSize))
        let titleLayout = TextLayout(text: "Nucleus Keybindings", font: .systemFont(ofSize: titleSize))
        let footerLayout = TextLayout(text: "Press Esc or click outside controls to dismiss", font: .systemFont(ofSize: footerSize))
        rowTextHeight = Float(rowLayout.intrinsicSize.height)
        rowBaselineOffset = Float(rowLayout.firstBaselineOffsetFromTop)
        titleTextHeight = Float(titleLayout.intrinsicSize.height)
        titleBaselineOffset = Float(titleLayout.firstBaselineOffsetFromTop)
        footerTextHeight = Float(footerLayout.intrinsicSize.height)
        footerBaselineOffset = Float(footerLayout.firstBaselineOffsetFromTop)
        lineH = max(24, rowTextHeight + 6)
        pad = 28
        colGap = 24
        keyColW = 200
        sepY = pad + titleTextHeight + 8
        rowStartY = sepY + 8 + (lineH - rowTextHeight) * 0.5 + rowBaselineOffset
    }
}

@MainActor
final class ShellOverlayHotkeyRowView: Control, ~Sendable {
    let entry: ShellOverlayHotkeyEntry
    let keyLabel: Label
    let descriptionLabel: Label
    private(set) var metrics: ShellOverlayHotkeyMetrics
    private var boxWidth: Float = 0
    private var textBaselineY: Float = 0
    private var rowFrame: Rect = Rect(x: 0, y: 0, width: 0, height: 0)

    init(entry: ShellOverlayHotkeyEntry, metrics: ShellOverlayHotkeyMetrics) {
        self.entry = entry
        self.metrics = metrics
        self.keyLabel = Label(entry.key)
        self.descriptionLabel = Label(entry.description)
        super.init()
        addSubview(keyLabel)
        addSubview(descriptionLabel)
        isEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "\(entry.key), \(entry.description)"
        accessibilityRole = .staticText
        accessibilityTraits = []
        accessibilityChildren = [keyLabel, descriptionLabel]
    }

    func update(metrics: ShellOverlayHotkeyMetrics) {
        self.metrics = metrics
        setNeedsDisplay()
        setNeedsLayout()
    }

    func place(boxWidth: Float, baselineY: Float) {
        self.boxWidth = boxWidth
        let rowX = metrics.pad - 8
        let rowH = max(metrics.lineH * 0.92, metrics.rowTextHeight + 4)
        let rowY = baselineY - metrics.rowBaselineOffset - (rowH - metrics.rowTextHeight) * 0.5
        let rowW = boxWidth - rowX * 2
        rowFrame = Rect(x: Double(rowX), y: Double(rowY), width: Double(rowW), height: Double(rowH))
        textBaselineY = baselineY - rowY
        self.frame = rowFrame
        setNeedsLayout()
    }

    override func layout() {
        let appearance = effectiveAppearance
        let rowX = Float(rowFrame.origin.x)
        keyLabel.fontSize = metrics.fontSize
        keyLabel.textColor = SemanticColor.accentLabel.resolve(in: appearance)
        keyLabel.placeBaseline(
            at: Double(textBaselineY),
            x: Double(metrics.pad - rowX),
            width: Double(metrics.keyColW)
        )
        descriptionLabel.fontSize = metrics.fontSize
        descriptionLabel.textColor = SemanticColor.secondaryLabel.resolve(in: appearance)
        descriptionLabel.placeBaseline(
            at: Double(textBaselineY),
            x: Double(metrics.pad + metrics.keyColW + metrics.colGap - rowX),
            width: max(0, rowFrame.size.width - Double(metrics.keyColW + metrics.colGap + metrics.pad))
        )
    }
}

@MainActor
final class ShellOverlayHotkeyView: View, ~Sendable {
    let backgroundEffectView: VisualEffectView
    let separatorView: View
    let titleLabel: Label
    let footerLabel: Label
    private(set) var rowViews: [ShellOverlayHotkeyRowView]
    private(set) var metrics: ShellOverlayHotkeyMetrics
    private(set) var visible: Bool = true
    private let entries: [ShellOverlayHotkeyEntry]
    private var lastFrameInfo: ShellOverlayFrameInfo?

    init(entries: [ShellOverlayHotkeyEntry] = shellOverlayHotkeyEntries) {
        self.entries = entries
        self.metrics = ShellOverlayHotkeyMetrics()
        self.backgroundEffectView = VisualEffectView(material: .hudWindow, state: .active, cornerRadius: 18)
        self.separatorView = View()
        self.titleLabel = Label("Nucleus Keybindings")
        self.footerLabel = Label("Press Esc or click outside controls to dismiss")
        self.rowViews = []
        super.init()
        backgroundEffectView.layerPresentation = ViewLayerPresentation(
            role: .hotkeyOverlay,
            backdropGroup: .hotkeyOverlay
        )
        addSubview(backgroundEffectView)
        addSubview(separatorView)
        addSubview(titleLabel)
        addSubview(footerLabel)
        shadow = ShellShadow.hotkeyOverlay
        for entry in entries where !entry.key.isEmpty {
            let row = ShellOverlayHotkeyRowView(entry: entry, metrics: metrics)
            addSubview(row)
            rowViews.append(row)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Keyboard shortcuts"
        accessibilityRole = .window
        accessibilityChildren = [titleLabel] + rowViews + [footerLabel]
    }

    func update(visible: Bool) {
        self.visible = visible
        isHidden = (!visible)
        setNeedsLayout()
        setNeedsDisplay()
    }

    var overlayLayerID: UInt64 {
        UInt64.max - 1
    }

    func updateFrame(_ frame: ShellOverlayFrameInfo) {
        guard lastFrameInfo != frame else {
            return
        }
        lastFrameInfo = frame
        metrics = ShellOverlayHotkeyMetrics(backingScaleFactor: frame.backingScaleFactor)
        let region = frame.overlayRegionInPoints
        let regionX = Float(region.origin.x)
        let regionY = Float(region.origin.y)
        let regionW = max(1, Float(region.size.width))
        let regionH = max(1, Float(region.size.height))
        let boxW = metrics.keyColW + 200 + metrics.pad * 2
        let boxH = (metrics.titleTextHeight + metrics.lineH) + entries.reduce(Float(0)) { height, entry in
            height + (entry.key.isEmpty ? metrics.lineH * 0.3 : metrics.lineH)
        } + metrics.footerTextHeight + metrics.pad * 2
        let x = regionX + (regionW - boxW) / 2
        let y = regionY + (regionH - boxH) / 2

        self.frame = Rect(x: Double(x), y: Double(y), width: Double(boxW), height: Double(boxH))
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layout() {
        let bounds = self.bounds
        let boxWidth = Float(bounds.size.width)
        let appearance = effectiveAppearance
        let separatorY = metrics.sepY
        backgroundEffectView.cornerRadius = ShellShadow.popoverCornerRadius
        backgroundEffectView.frame = (Rect(
            x: 0,
            y: 0,
            width: bounds.size.width,
            height: bounds.size.height
        ))
        separatorView.frame = Rect(
            x: Double(metrics.pad),
            y: Double(separatorY),
            width: Double(max(0, boxWidth - metrics.pad * 2)),
            height: Double(metrics.hairlineWidth)
        )
        separatorView.backgroundColor = SemanticColor.separator.resolve(in: appearance)
        titleLabel.fontSize = metrics.titleSize
        titleLabel.textColor = SemanticColor.label.resolve(in: appearance)
        titleLabel.placeBaseline(
            at: Double(metrics.pad + metrics.titleBaselineOffset),
            x: Double(metrics.pad),
            width: Double(max(0, boxWidth - metrics.pad * 2))
        )
        footerLabel.fontSize = metrics.footerSize
        footerLabel.textColor = SemanticColor.tertiaryLabel.resolve(in: appearance).opacity(0.46)
        footerLabel.placeBaseline(
            at: bounds.size.height - Double(metrics.pad * 0.5) - Double(metrics.footerTextHeight - metrics.footerBaselineOffset),
            x: Double(metrics.pad),
            width: Double(max(0, boxWidth - metrics.pad * 2))
        )

        var y = metrics.rowStartY
        var rowIndex = 0
        for entry in entries {
            if entry.key.isEmpty {
                y += metrics.lineH * 0.3
                continue
            }
            let row = rowViews[rowIndex]
            row.update(metrics: metrics)
            row.place(boxWidth: boxWidth, baselineY: y)
            rowIndex += 1
            y += metrics.lineH
        }
    }
}
