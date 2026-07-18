import NucleusUI
import NucleusUIEmbedder

@MainActor
final class ShellOverlayNotificationView: View, ~Sendable {
    private(set) var info: ShellOverlayNotificationInfo
    private(set) var metrics: ShellOverlayNotificationMetrics
    let backgroundEffectView: VisualEffectView
    let summaryLabel: Label
    let bodyLabel: Label
    let thumbnailView: ImageView
    let closeButton: Button
    private var dismissHandler: ((UInt32) -> Void)?

    init(info: ShellOverlayNotificationInfo, metrics: ShellOverlayNotificationMetrics = .init()) {
        self.info = info
        self.metrics = metrics.updated(showsThumbnail: info.showsThumbnail, hasBody: !info.body.isEmpty)
        self.backgroundEffectView = VisualEffectView(material: .popover, state: .active, cornerRadius: 18)
        self.summaryLabel = Label(info.summary)
        self.bodyLabel = Label(info.body)
        self.thumbnailView = ImageView(
            image: info.showsThumbnail ? ImageHandle(id: info.thumbnailHandle) : nil,
            imageSize: Size(width: 116, height: 76)
        )
        self.closeButton = Button(title: "")
        super.init()

        addSubview(backgroundEffectView)
        addSubview(thumbnailView)
        addSubview(summaryLabel)
        addSubview(bodyLabel)
        addSubview(closeButton)
        closeButton.onPress { [weak self] _ in
            guard let self else { return }
            self.dismissHandler?(self.info.id)
        }
        backgroundEffectView.layerPresentation = ViewLayerPresentation(
            role: .notification,
            backdropGroup: .notifications
        )
        layerPresentation = ViewLayerPresentation(
            role: .notification,
            actionPolicy: .default,
            creationOpacity: 0
        )
        shadow = ShellShadow.notification
        applySemanticProperties()
    }

    func update(_ info: ShellOverlayNotificationInfo, metrics: ShellOverlayNotificationMetrics? = nil) {
        self.info = info
        self.metrics = (metrics ?? self.metrics).updated(showsThumbnail: info.showsThumbnail, hasBody: !info.body.isEmpty)
        summaryLabel.text = info.summary
        bodyLabel.text = info.body
        thumbnailView.image = info.showsThumbnail ? ImageHandle(id: info.thumbnailHandle) : nil
        applySemanticProperties()
        setNeedsLayout()
    }

    func setDismissHandler(_ handler: @escaping (UInt32) -> Void) {
        dismissHandler = handler
    }

    var overlayLayerID: UInt64 {
        UInt64(info.id)
    }

    override func layout() {
        var textX = metrics.cardPad
        var summaryY = metrics.cardPad
        var bodyY = metrics.cardPad + metrics.summaryTextHeight + 6
        let thumbnailX = metrics.cardPad
        let thumbnailY = (metrics.cardH - metrics.thumbH) * 0.5

        backgroundEffectView.cornerRadius = ShellShadow.popoverCornerRadius
        backgroundEffectView.frame = (Rect(
            x: 0,
            y: 0,
            width: Double(metrics.cardW),
            height: Double(metrics.cardH)
        ))

        if info.showsThumbnail {
            textX = thumbnailX + metrics.thumbW + metrics.thumbGap
            let textH = metrics.textHeight(hasBody: !info.body.isEmpty)
            let textTop = (metrics.cardH - textH) * 0.5
            summaryY = textTop
            bodyY = textTop + metrics.summaryTextHeight + 7
        }

        summaryLabel.frame = (Rect(
            x: Double(textX),
            y: Double(summaryY),
            width: Double(max(0, metrics.cardW - textX - 40)),
            height: Double(metrics.summaryTextHeight)
        ))
        bodyLabel.frame = (Rect(
            x: Double(textX),
            y: Double(bodyY),
            width: Double(max(0, metrics.cardW - textX - 40)),
            height: Double(metrics.bodyTextHeight)
        ))
        thumbnailView.frame = (Rect(
            x: Double(thumbnailX),
            y: Double(thumbnailY),
            width: Double(metrics.thumbW),
            height: Double(metrics.thumbH)
        ))
        closeButton.frame = (Rect(
            x: Double(metrics.cardW - metrics.cardPad - 10),
            y: Double(summaryY + metrics.summaryTextHeight * 0.5 - 5),
            width: 10,
            height: 10
        ))
        let slideDistance = Double(metrics.cardW + metrics.rightMargin)
        layerPresentation.creationFrame = Rect(
            x: frame.origin.x + slideDistance,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height
        )
        thumbnailView.isHidden = (!info.showsThumbnail)
        bodyLabel.isHidden = (info.body.isEmpty)
        applySemanticProperties()
    }

    private func applySemanticProperties() {
        isAccessibilityElement = true
        accessibilityLabel = [info.appName, info.summary, info.body]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        accessibilityRole = .window
        accessibilityChildren = [summaryLabel, bodyLabel, thumbnailView, closeButton]

        summaryLabel.accessibilityProperties = .init(
            isElement: true,
            label: info.summary,
            role: .staticText
        )
        bodyLabel.accessibilityProperties = .init(
            isElement: !info.body.isEmpty,
            label: info.body,
            role: .staticText
        )
        thumbnailView.accessibilityProperties = .init(
            isElement: info.showsThumbnail,
            label: info.showsThumbnail ? "Notification thumbnail" : nil,
            role: .image,
            traits: info.showsThumbnail ? [.image] : []
        )
        closeButton.accessibilityProperties = .init(
            isElement: true,
            label: "Dismiss notification",
            role: .button,
            traits: [.button]
        )

        let appearance = effectiveAppearance
        summaryLabel.fontSize = metrics.summarySize
        summaryLabel.textColor = SemanticColor.label.resolve(in: appearance)
        bodyLabel.fontSize = metrics.bodySize
        bodyLabel.textColor = SemanticColor.secondaryLabel.resolve(in: appearance)
        thumbnailView.cornerRadius = 10
        closeButton.glyph = .close
        closeButton.foregroundColor = SemanticColor.tertiaryLabel.resolve(in: appearance)
    }
}

struct ShellOverlayNotificationMetrics: Sendable, Equatable {
    var cardW: Float
    var cardH: Float
    var cardGap: Float
    var rightMargin: Float
    var topMargin: Float
    var cardPad: Float
    var summarySize: Float
    var bodySize: Float
    var summaryTextHeight: Float
    var bodyTextHeight: Float
    var thumbGap: Float
    var thumbW: Float
    var thumbH: Float

    init(showsThumbnail: Bool = false, hasBody: Bool = false) {
        let cardPad: Float = 18
        let summarySize: Float = 15
        let bodySize: Float = 13
        let summaryLayout = TextLayout(text: "Hg", font: .systemFont(ofSize: summarySize))
        let bodyLayout = TextLayout(text: "Hg", font: .systemFont(ofSize: bodySize))
        let summaryTextHeight = Float(summaryLayout.intrinsicSize.height)
        let bodyTextHeight = Float(bodyLayout.intrinsicSize.height)
        let thumbH: Float = 76
        let textH = summaryTextHeight + (hasBody ? bodyTextHeight + 7 : 0)
        self.cardW = showsThumbnail ? 424 : 380
        self.cardH = showsThumbnail ? cardPad * 2 + max(thumbH, textH) : cardPad * 2 + textH
        self.cardGap = 10
        self.rightMargin = 16
        self.topMargin = 16
        self.cardPad = cardPad
        self.summarySize = summarySize
        self.bodySize = bodySize
        self.summaryTextHeight = summaryTextHeight
        self.bodyTextHeight = bodyTextHeight
        self.thumbGap = 14
        self.thumbW = 116
        self.thumbH = thumbH
    }

    func textHeight(hasBody: Bool) -> Float {
        summaryTextHeight + (hasBody ? bodyTextHeight + 7 : 0)
    }

    func updated(showsThumbnail: Bool, hasBody: Bool) -> ShellOverlayNotificationMetrics {
        ShellOverlayNotificationMetrics(showsThumbnail: showsThumbnail, hasBody: hasBody)
    }
}

@MainActor
final class ShellOverlayNotificationListView: StackView, ~Sendable {
    var frameInfo: ShellOverlayFrameInfo?
    private var dismissHandler: ((UInt32) -> Void)?

    init() {
        super.init(axis: .vertical, spacing: 0, alignment: .trailing)
        hidesHiddenArrangedSubviews = false
    }

    func setDismissHandler(_ handler: @escaping (UInt32) -> Void) {
        dismissHandler = handler
        for case let notification as ShellOverlayNotificationView in arrangedSubviews {
            notification.setDismissHandler(handler)
        }
    }

    func setNotifications(_ notifications: [ShellOverlayNotificationView]) {
        for view in arrangedSubviews where !notifications.contains(where: { $0 === view }) {
            removeArrangedSubview(view)
        }
        for notification in notifications where !arrangedSubviews.contains(where: { $0 === notification }) {
            notification.alphaValue = 1
            addArrangedSubview(notification)
        }
        if let dismissHandler {
            for notification in notifications {
                notification.setDismissHandler(dismissHandler)
            }
        }
        setNeedsLayout()
    }

    override func layout() {
        guard let frameInfo else {
            return
        }
        let region = frameInfo.overlayRegionInPoints
        let regionX = Float(region.origin.x)
        let regionY = Float(region.origin.y)
        let regionW = max(1, Float(region.size.width))
        var activeOffset: Float = 0

        for case let notification as ShellOverlayNotificationView in arrangedSubviews {
            let metrics = ShellOverlayNotificationMetrics(
                showsThumbnail: notification.info.showsThumbnail,
                hasBody: !notification.info.body.isEmpty
            )
            notification.update(notification.info, metrics: metrics)
            let x = regionX + regionW - metrics.cardW - metrics.rightMargin
            if !isArrangedSubviewExiting(notification) {
                notification.frame = Rect(
                    x: Double(x),
                    y: Double(regionY + metrics.topMargin + activeOffset),
                    width: Double(metrics.cardW),
                    height: Double(metrics.cardH)
                )
            }
            activeOffset += metrics.cardH + metrics.cardGap
        }
    }
}
