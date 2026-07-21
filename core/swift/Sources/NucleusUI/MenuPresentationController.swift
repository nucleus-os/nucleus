private enum MenuMetrics {
    static let fontSize: Float = 13
    static let rowHeight: Double = 24
    static let separatorHeight: Double = 11
    static let leadingInset: Double = 12
    static let markerWidth: Double = 18
    static let glyphWidth: Double = 20
    static let shortcutGap: Double = 24
    static let trailingInset: Double = 12
    static let arrowWidth: Double = 14
    static let verticalPadding: Double = 5
    static let minimumWidth: Double = 150
    static let maximumWidth: Double = 420
    static let highlightInsetX: Double = 5
    static let cornerRadius: Double = 6
}

@MainActor
private final class MenuSeparatorView: View {
    override init() {
        super.init()
        isAccessibilityElement = true
        accessibilityRole = .separator
    }

    override func draw(in context: GraphicsContext) {
        context.fillColor = SemanticColor.separator.resolve(
            in: effectiveAppearance)
        context.fill(Rect(
            x: MenuMetrics.leadingInset,
            y: max(0, (bounds.size.height - 1) * 0.5),
            width: max(0, bounds.size.width - MenuMetrics.leadingInset * 2),
            height: 1))
    }
}

@MainActor
private final class MenuItemView: Control {
    let item: MenuItem
    private let markerLabel = Label("")
    private let glyphView = GlyphView(pointSize: MenuMetrics.fontSize)
    private let titleLabel: Label
    private let shortcutLabel = Label("")
    private let arrowLabel = Label("")
    private var itemObservation: AnyObject?
    private var submenuExpanded = false

    var onActivate: (@MainActor (MenuItem) -> Void)?

    init(item: MenuItem) {
        self.item = item
        self.titleLabel = Label(item.title)
        super.init()
        addSubview(markerLabel)
        addSubview(glyphView)
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(arrowLabel)
        markerLabel.alignment = .center
        titleLabel.fontSize = MenuMetrics.fontSize
        shortcutLabel.fontSize = MenuMetrics.fontSize
        shortcutLabel.alignment = .trailing
        arrowLabel.fontSize = MenuMetrics.fontSize
        arrowLabel.alignment = .center
        accessibilityRole = .menuItem
        onPrimaryAction { [weak self] _ in
            guard let self else { return }
            onActivate?(item)
        }
        itemObservation = item.observeChanges { [weak self] in
            self?.synchronize()
        }
        synchronize()
    }

    override var keyboardActivationKeys: Set<KeyCode> {
        [.space, .return]
    }

    var measuredTitleWidth: Double {
        titleLabel.intrinsicContentSize.width
    }

    var measuredShortcutWidth: Double {
        shortcutLabel.intrinsicContentSize.width
    }

    func setMenuHighlighted(_ highlighted: Bool) {
        isSelected = highlighted
    }

    fileprivate func synchronize() {
        titleLabel.text = item.title
        glyphView.name = item.glyph
        glyphView.isHidden = item.glyph == nil
        shortcutLabel.text = item.keyEquivalent?.displayText ?? ""
        arrowLabel.text = item.submenu == nil ? "" : "\u{203A}"
        isEnabled = item.isEnabled
        accessibilityLabel = item.accessibilityLabel ?? item.title
        accessibilityValue = switch item.state {
        case .off: nil
        case .on: "Checked"
        case .mixed: "Mixed"
        }
        var traits = accessibilityTraits
        traits.remove([.checked, .expanded, .disabled])
        if item.state != .off { traits.insert(.checked) }
        if submenuExpanded { traits.insert(.expanded) }
        if !item.isEnabled { traits.insert(.disabled) }
        accessibilityTraits = traits
        markerLabel.text = switch item.state {
        case .off: ""
        case .on:
            if case .radio = item.activationBehavior { "\u{2022}" } else { "\u{2713}" }
        case .mixed: "\u{2014}"
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    func setSubmenuExpanded(_ expanded: Bool) {
        guard submenuExpanded != expanded else { return }
        submenuExpanded = expanded
        synchronize()
    }

    override func controlStateDidChange() {
        super.controlStateDidChange()
        let appearance = effectiveAppearance
        let active = isSelected && isEnabled
        backgroundColor = active
            ? SemanticColor.accent.resolve(in: appearance)
            : nil
        let textColor: Color =
            if !isEnabled {
                SemanticColor.tertiaryLabel.resolve(in: appearance)
            } else if active {
                SemanticColor.accentLabel.resolve(in: appearance)
            } else {
                SemanticColor.label.resolve(in: appearance)
            }
        titleLabel.textColor = textColor
        markerLabel.textColor = textColor
        shortcutLabel.textColor = textColor
        arrowLabel.textColor = textColor
        glyphView.tint = .fixed(textColor)
    }

    override func layout() {
        let height = bounds.size.height
        let hasGlyph = !glyphView.isHidden
        let markerX = MenuMetrics.leadingInset
        markerLabel.frame = Rect(
            x: markerX, y: 0,
            width: MenuMetrics.markerWidth, height: height)
        glyphView.frame = Rect(
            x: markerX + MenuMetrics.markerWidth,
            y: max(0, (height - MenuMetrics.glyphWidth) * 0.5),
            width: hasGlyph ? MenuMetrics.glyphWidth : 0,
            height: MenuMetrics.glyphWidth)

        let arrowWidth = item.submenu == nil ? 0 : MenuMetrics.arrowWidth
        let shortcutWidth = measuredShortcutWidth
        let trailing = MenuMetrics.trailingInset + arrowWidth
        shortcutLabel.frame = Rect(
            x: max(0, bounds.size.width - trailing - shortcutWidth),
            y: 0,
            width: shortcutWidth,
            height: height)
        arrowLabel.frame = Rect(
            x: max(0, bounds.size.width - MenuMetrics.trailingInset - arrowWidth),
            y: 0,
            width: arrowWidth,
            height: height)
        let titleX = markerX + MenuMetrics.markerWidth
            + (hasGlyph ? MenuMetrics.glyphWidth : 0)
        let titleEnd = shortcutWidth > 0
            ? shortcutLabel.frame.origin.x - MenuMetrics.shortcutGap
            : bounds.size.width - trailing
        titleLabel.frame = Rect(
            x: titleX,
            y: 0,
            width: max(0, titleEnd - titleX),
            height: height)
        cornerRadius = 4
    }
}

@MainActor
private final class MenuPanelView: View {
    let menu: Menu
    var modifierFlags: EventModifierFlags = [] {
        didSet {
            if modifierFlags != oldValue { reconcile() }
        }
    }
    var onActivate: (@MainActor (MenuItem) -> Void)?
    var onContentsChange: (@MainActor () -> Void)?

    private let effectView: VisualEffectView
    private var itemViews: [MenuItemID: MenuItemView] = [:]
    private var separatorViews: [MenuItemID: MenuSeparatorView] = [:]
    private var orderedItems: [MenuItem] = []
    private var menuObservation: AnyObject?
    private var selectedID: MenuItemID?
    private var isReconciling = false

    init(menu: Menu) {
        self.menu = menu
        self.effectView = VisualEffectView(
            material: .menu,
            state: .active,
            cornerRadius: MenuMetrics.cornerRadius)
        super.init()
        cornerRadius = MenuMetrics.cornerRadius
        shadow = Shadow(
            offsetX: 0,
            offsetY: 8,
            blurRadius: 22,
            cornerRadius: MenuMetrics.cornerRadius,
            opacity: 0.30,
            color: Color(0, 0, 0, 1))
        addSubview(effectView)
        isAccessibilityElement = true
        accessibilityRole = .menu
        accessibilityLabel = "Menu"
        menuObservation = menu.observeChanges { [weak self] in
            self?.reconcile()
        }
        reconcile()
    }

    override var acceptsFirstResponder: Bool { true }

    var selectedItem: MenuItem? {
        selectedID.flatMap { id in
            orderedItems.first { $0.id == id }
        }
    }

    var selectableItems: [MenuItem] {
        orderedItems.filter { !$0.isSeparator && $0.isEnabled }
    }

    var preferredSize: Size {
        let rows = orderedItems.compactMap { itemViews[$0.id] }
        let widestTitle = rows.map(\.measuredTitleWidth).max() ?? 0
        let widestShortcut = rows.map(\.measuredShortcutWidth).max() ?? 0
        let hasGlyph = orderedItems.contains { $0.glyph != nil }
        let hasSubmenu = orderedItems.contains { $0.submenu != nil }
        let width = MenuMetrics.leadingInset
            + MenuMetrics.markerWidth
            + (hasGlyph ? MenuMetrics.glyphWidth : 0)
            + widestTitle
            + (widestShortcut > 0
                ? MenuMetrics.shortcutGap + widestShortcut
                : 0)
            + (hasSubmenu ? MenuMetrics.arrowWidth : 0)
            + MenuMetrics.trailingInset
        let height = orderedItems.reduce(
            MenuMetrics.verticalPadding * 2
        ) {
            $0 + ($1.isSeparator
                ? MenuMetrics.separatorHeight
                : MenuMetrics.rowHeight)
        }
        return Size(
            width: min(MenuMetrics.maximumWidth, max(MenuMetrics.minimumWidth, width)),
            height: height)
    }

    func item(at point: Point) -> MenuItem? {
        for item in orderedItems where !item.isSeparator && item.isEnabled {
            if itemViews[item.id]?.frame.contains(point) == true {
                return item
            }
        }
        return nil
    }

    func frame(of item: MenuItem) -> Rect? {
        itemViews[item.id]?.frame
    }

    func retainedViewID(for itemID: MenuItemID) -> ViewID? {
        itemViews[itemID]?.id
    }

    func setSelected(_ item: MenuItem?) {
        let nextID = item?.id
        guard nextID != selectedID else { return }
        selectedID = nextID
        for (id, row) in itemViews {
            row.setMenuHighlighted(id == nextID)
        }
        if let item, let row = itemViews[item.id] {
            _ = window?.makeFirstResponder(row)
        } else {
            _ = window?.makeFirstResponder(self)
        }
    }

    func setExpandedItem(_ item: MenuItem?) {
        for row in itemViews.values {
            row.setSubmenuExpanded(row.item.id == item?.id)
        }
    }

    func focusSelection() {
        if let selectedID, let row = itemViews[selectedID] {
            _ = window?.makeFirstResponder(row)
        } else {
            _ = window?.makeFirstResponder(self)
        }
    }

    func moveSelection(by delta: Int) {
        let candidates = selectableItems
        guard !candidates.isEmpty else {
            setSelected(nil)
            return
        }
        guard let selectedID,
              let index = candidates.firstIndex(where: { $0.id == selectedID })
        else {
            setSelected(delta < 0 ? candidates.last : candidates.first)
            return
        }
        let next = ((index + delta) % candidates.count + candidates.count)
            % candidates.count
        setSelected(candidates[next])
    }

    func selectBoundary(first: Bool) {
        setSelected(first ? selectableItems.first : selectableItems.last)
    }

    func selectItem(
        whoseTitleHasPrefix prefix: String,
        after current: MenuItem?
    ) -> Bool {
        let candidates = selectableItems
        guard !candidates.isEmpty else { return false }
        let start = current.flatMap { selected in
            candidates.firstIndex { $0.id == selected.id }
        } ?? -1
        for offset in 1...candidates.count {
            let candidate = candidates[(start + offset) % candidates.count]
            if candidate.title.lowercased().hasPrefix(prefix.lowercased()) {
                setSelected(candidate)
                return true
            }
        }
        return false
    }

    func item(matchingMnemonic character: Character) -> MenuItem? {
        let folded = String(character).lowercased()
        return selectableItems.first {
            $0.mnemonic.map { String($0).lowercased() == folded } == true
        }
    }

    override func layout() {
        effectView.frame = bounds
        var y = MenuMetrics.verticalPadding
        for item in orderedItems {
            if item.isSeparator {
                separatorViews[item.id]?.frame = Rect(
                    x: 0, y: y,
                    width: bounds.size.width,
                    height: MenuMetrics.separatorHeight)
                y += MenuMetrics.separatorHeight
            } else {
                itemViews[item.id]?.frame = Rect(
                    x: MenuMetrics.highlightInsetX,
                    y: y,
                    width: max(0, bounds.size.width - MenuMetrics.highlightInsetX * 2),
                    height: MenuMetrics.rowHeight)
                y += MenuMetrics.rowHeight
            }
        }
    }

    private func reconcile() {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        orderedItems = menu.visibleItems(modifiers: modifierFlags)
        var desiredViews: [View] = []
        desiredViews.reserveCapacity(orderedItems.count)
        for item in orderedItems {
            if item.isSeparator {
                let view = separatorViews[item.id] ?? {
                    let view = MenuSeparatorView()
                    separatorViews[item.id] = view
                    return view
                }()
                desiredViews.append(view)
            } else {
                let row = itemViews[item.id] ?? {
                    let row = MenuItemView(item: item)
                    row.onActivate = { [weak self] item in
                        self?.onActivate?(item)
                    }
                    itemViews[item.id] = row
                    return row
                }()
                row.synchronize()
                desiredViews.append(row)
            }
        }

        let desiredIDs = Set(desiredViews.map(ObjectIdentifier.init))
        for child in childViews where child !== effectView
            && !desiredIDs.contains(ObjectIdentifier(child))
        {
            child.removeFromSuperview()
        }
        for (index, view) in desiredViews.enumerated() {
            insertSubview(view, at: index + 1)
        }
        if let selectedID,
           !orderedItems.contains(where: {
               $0.id == selectedID && !$0.isSeparator && $0.isEnabled
           })
        {
            self.selectedID = nil
        }
        for (id, row) in itemViews {
            row.setMenuHighlighted(id == selectedID)
        }
        accessibilityChildren = desiredViews
        let size = preferredSize
        if frame.size != size {
            frame = Rect(origin: frame.origin, size: size)
        }
        setNeedsLayout()
        onContentsChange?()
    }
}

public enum MenuPresentationResult: Sendable, Equatable {
    case activated(MenuItemID)
    case cancelled
}

/// Owns one root menu and its complete submenu cascade.
@MainActor
public final class MenuPresentationController: ~Sendable {
    private struct Level {
        let menu: Menu
        let panel: MenuPanelView
        let popover: Popover
        let parentItemID: MenuItemID?
    }

    public let menu: Menu
    public private(set) var result: MenuPresentationResult?
    package static var liveCount = 0

    private weak var scene: WindowScene?
    private let clock: UIClock
    private let anchor: Rect
    private let preferredEdge: PopupEdge
    private let level: WindowLevel
    private var levels: [Level] = []
    private var finishHandler:
        (@MainActor (MenuPresentationResult) -> Void)?
    private var stickyOpeningGesture: Bool
    private var openingDragEntered = false
    private var pressedItemID: MenuItemID?
    private var pressedLevel: Int?
    private var submenuTasks: [Int: Task<Void, Never>] = [:]
    private var typeAheadTask: Task<Void, Never>?
    private var typeAhead = ""
    private var lastPointerLocation: Point?
    private var isDismissing = false

    package init(
        menu: Menu,
        scene: WindowScene,
        anchor: Rect,
        preferredEdge: PopupEdge,
        level: WindowLevel,
        stickyOpeningGesture: Bool,
        onFinish:
            (@MainActor (MenuPresentationResult) -> Void)?
    ) {
        self.menu = menu
        self.scene = scene
        self.clock = scene.uiContext.clock
        self.anchor = anchor
        self.preferredEdge = preferredEdge
        self.level = level
        self.stickyOpeningGesture = stickyOpeningGesture
        self.finishHandler = onFinish
        Self.liveCount += 1
    }

    deinit {
        for task in submenuTasks.values { task.cancel() }
        typeAheadTask?.cancel()
        MainActor.assumeIsolated {
            Self.liveCount -= 1
        }
    }

    package func begin() {
        precondition(levels.isEmpty, "a menu presentation begins once")
        menu.validateRecursively()
        guard appendLevel(
            menu: menu,
            anchor: anchor,
            preferring: preferredEdge,
            parentItemID: nil)
        else {
            finish(.cancelled)
            return
        }
    }

    public func dismiss() {
        finish(.cancelled)
    }

    package func sceneDidDisconnect() {
        finish(.cancelled)
    }

    package func displayBoundsDidChange() {
        guard !levels.isEmpty else { return }
        for level in levels {
            level.popover.place(in: scene?.displayBounds ?? .zero)
        }
        repositionSubmenus(startingAt: 1)
    }

    package func handleEvent(_ event: Event) -> EventHandling {
        guard result == nil else { return .notHandled }
        updateModifiers(event.modifierFlags)
        if event.isKeyEvent || event.type == .flagsChanged {
            return handleKeyboard(event)
        }
        switch event.type {
        case .pointerMoved, .pointerDragged, .touchMoved:
            updatePointer(at: event.location)
            if stickyOpeningGesture,
               event.type == .pointerDragged,
               hitItem(at: event.location) != nil
            {
                openingDragEntered = true
            }
            return .handled
        case .pointerDown, .touchDown:
            stickyOpeningGesture = false
            guard let hit = hitItem(at: event.location) else {
                finish(.cancelled)
                return .handled
            }
            pressedLevel = hit.level
            pressedItemID = hit.item.id
            select(hit.item, atLevel: hit.level, pointerDriven: true)
            return .handled
        case .pointerUp, .touchUp:
            defer {
                pressedItemID = nil
                pressedLevel = nil
                stickyOpeningGesture = false
                openingDragEntered = false
            }
            let hit = hitItem(at: event.location)
            if stickyOpeningGesture && !openingDragEntered {
                return .handled
            }
            if let hit,
               (openingDragEntered
                    || (pressedLevel == hit.level
                        && pressedItemID == hit.item.id))
            {
                activate(hit.item, atLevel: hit.level)
                return .handled
            }
            if hit == nil { finish(.cancelled) }
            return .handled
        case .pointerCancelled, .touchCancelled:
            pressedItemID = nil
            pressedLevel = nil
            openingDragEntered = false
            return .handled
        case .scrollWheel:
            return .handled
        default:
            return .handled
        }
    }

    package func panelCountForTesting() -> Int { levels.count }

    package func selectedItemIDForTesting() -> MenuItemID? {
        levels.last?.panel.selectedItem?.id
    }

    package func retainedViewIDForTesting(
        itemID: MenuItemID,
        level: Int = 0
    ) -> ViewID? {
        guard levels.indices.contains(level) else { return nil }
        return levels[level].panel.retainedViewID(for: itemID)
    }

    package func itemFrameInSceneForTesting(
        itemID: MenuItemID,
        level: Int = 0
    ) -> Rect? {
        guard levels.indices.contains(level),
              let item = levels[level].menu.items.first(where: {
                  $0.id == itemID
              })
        else { return nil }
        levels[level].panel.layoutIfNeeded()
        guard
              let frame = levels[level].panel.frame(of: item)
        else { return nil }
        let windowFrame = levels[level].popover.window.frame
        return Rect(
            x: windowFrame.origin.x + frame.origin.x,
            y: windowFrame.origin.y + frame.origin.y,
            width: frame.size.width,
            height: frame.size.height)
    }

    package func popoverFramesForTesting() -> [Rect] {
        levels.map(\.popover.window.frame)
    }

    private func handleKeyboard(_ event: Event) -> EventHandling {
        guard event.type == .keyDown else { return .handled }
        if let equivalent = keyEquivalent(in: menu, matching: event) {
            activate(equivalent.item, in: equivalent.menu)
            return .handled
        }
        guard let top = levels.last else { return .handled }
        let topIndex = levels.count - 1
        switch event.keyCode {
        case .upArrow:
            top.panel.moveSelection(by: -1)
            selectionDidChange(atLevel: topIndex, pointerDriven: false)
        case .downArrow:
            top.panel.moveSelection(by: 1)
            selectionDidChange(atLevel: topIndex, pointerDriven: false)
        case .home:
            top.panel.selectBoundary(first: true)
            selectionDidChange(atLevel: topIndex, pointerDriven: false)
        case .end:
            top.panel.selectBoundary(first: false)
            selectionDidChange(atLevel: topIndex, pointerDriven: false)
        case .rightArrow:
            openSelectedSubmenu(atLevel: topIndex, selectFirst: true)
        case .leftArrow:
            if topIndex > 0 { popLevels(toCount: topIndex) }
        case .escape:
            if topIndex > 0 {
                popLevels(toCount: topIndex)
            } else {
                finish(.cancelled)
            }
        case .return, .space:
            if let selected = top.panel.selectedItem {
                activate(selected, atLevel: topIndex)
            }
        default:
            handleTextKey(event, in: top.panel, level: topIndex)
        }
        return .handled
    }

    private func handleTextKey(
        _ event: Event,
        in panel: MenuPanelView,
        level: Int
    ) {
        guard let characters = event.characters,
              let character = characters.first,
              !character.isWhitespace
        else { return }
        if let mnemonic = panel.item(matchingMnemonic: character) {
            panel.setSelected(mnemonic)
            activate(mnemonic, atLevel: level)
            return
        }
        typeAhead += characters.lowercased()
        if !panel.selectItem(
            whoseTitleHasPrefix: typeAhead,
            after: panel.selectedItem)
        {
            typeAhead = characters.lowercased()
            _ = panel.selectItem(
                whoseTitleHasPrefix: typeAhead,
                after: panel.selectedItem)
        }
        selectionDidChange(atLevel: level, pointerDriven: false)
        typeAheadTask?.cancel()
        let clock = self.clock
        typeAheadTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.typeAhead = ""
        }
    }

    private func updateModifiers(_ modifiers: EventModifierFlags) {
        var changedAt: Int?
        var invalidSubmenuParent: Int?
        for index in levels.indices {
            let oldSize = levels[index].panel.preferredSize
            levels[index].panel.modifierFlags = modifiers
            if levels.indices.contains(index + 1),
               levels[index].panel.selectedItem?.id
                != levels[index + 1].parentItemID
            {
                invalidSubmenuParent = min(
                    invalidSubmenuParent ?? index,
                    index)
            }
            if levels[index].panel.preferredSize != oldSize {
                changedAt = min(changedAt ?? index, index)
            }
        }
        if let invalidSubmenuParent {
            popLevels(toCount: invalidSubmenuParent + 1)
        }
        if let changedAt {
            resizeLevel(changedAt)
            repositionSubmenus(startingAt: changedAt + 1)
        }
    }

    private func updatePointer(at location: Point) {
        defer { lastPointerLocation = location }
        guard let hitLevel = levels.lastIndex(where: {
            $0.popover.window.frame.contains(location)
        }) else {
            return
        }
        let level = levels[hitLevel]
        let local = level.popover.window.windowPoint(fromScene: location)
        guard let item = level.panel.item(at: local) else { return }
        select(
            item,
            atLevel: hitLevel,
            pointerDriven: true,
            pointerLocation: location)
    }

    private func select(
        _ item: MenuItem?,
        atLevel index: Int,
        pointerDriven: Bool,
        pointerLocation: Point? = nil
    ) {
        guard levels.indices.contains(index) else { return }
        let panel = levels[index].panel
        guard panel.selectedItem?.id != item?.id else { return }
        panel.setSelected(item)
        selectionDidChange(
            atLevel: index,
            pointerDriven: pointerDriven,
            pointerLocation: pointerLocation)
    }

    private func selectionDidChange(
        atLevel index: Int,
        pointerDriven: Bool,
        pointerLocation: Point? = nil
    ) {
        cancelSubmenuTasks(fromLevel: index)
        let selected = levels[index].panel.selectedItem
        let preservesOpenChild = pointerDriven
            && shouldPreserveOpenSubmenu(
                atLevel: index,
                currentPointerLocation: pointerLocation)
        guard let selected, selected.submenu != nil else {
            if preservesOpenChild {
                let selectedID = selected?.id
                let clock = self.clock
                submenuTasks[index] = Task { @MainActor [weak self] in
                    try? await clock.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled,
                          let self,
                          levels.indices.contains(index),
                          levels[index].panel.selectedItem?.id == selectedID
                    else { return }
                    popLevels(toCount: index + 1)
                    submenuTasks[index] = nil
                }
            } else {
                popLevels(toCount: index + 1)
            }
            return
        }
        guard pointerDriven else {
            popLevels(toCount: index + 1)
            return
        }
        let delay = preservesOpenChild ? 300 : 180
        let selectedID = selected.id
        let clock = self.clock
        submenuTasks[index] = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled,
                  let self,
                  levels.indices.contains(index),
                  levels[index].panel.selectedItem?.id == selectedID
            else { return }
            openSelectedSubmenu(atLevel: index, selectFirst: false)
            submenuTasks[index] = nil
        }
    }

    private func shouldPreserveOpenSubmenu(
        atLevel index: Int,
        currentPointerLocation: Point?
    ) -> Bool {
        guard levels.indices.contains(index + 1),
              let previous = lastPointerLocation,
              let current = currentPointerLocation
        else { return false }
        let child = levels[index + 1].popover.window.frame
        let parent = levels[index].popover.window.frame
        let edgeX = child.origin.x >= parent.origin.x
            ? child.origin.x
            : child.origin.x + child.size.width
        let upper = Point(x: edgeX, y: child.origin.y - 10)
        let lower = Point(
            x: edgeX,
            y: child.origin.y + child.size.height + 10)
        return point(current, liesInTriangle: previous, upper, lower)
    }

    private func point(
        _ point: Point,
        liesInTriangle a: Point,
        _ b: Point,
        _ c: Point
    ) -> Bool {
        func sign(_ p1: Point, _ p2: Point, _ p3: Point) -> Double {
            (p1.x - p3.x) * (p2.y - p3.y)
                - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = sign(point, a, b)
        let d2 = sign(point, b, c)
        let d3 = sign(point, c, a)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    private func openSelectedSubmenu(
        atLevel index: Int,
        selectFirst: Bool
    ) {
        guard levels.indices.contains(index),
              let item = levels[index].panel.selectedItem,
              let submenu = item.submenu
        else { return }
        submenu.validateRecursively()
        if levels.indices.contains(index + 1),
           levels[index + 1].parentItemID == item.id
        {
            levels[index].panel.setExpandedItem(item)
            if selectFirst {
                levels[index + 1].panel.selectBoundary(first: true)
            }
            return
        }
        popLevels(toCount: index + 1)
        guard let row = levels[index].panel.frame(of: item) else { return }
        let childHeight = submenu.visibleItems(
            modifiers: levels[index].panel.modifierFlags
        ).reduce(MenuMetrics.verticalPadding * 2) {
            $0 + ($1.isSeparator
                ? MenuMetrics.separatorHeight
                : MenuMetrics.rowHeight)
        }
        let parentFrame = levels[index].popover.window.frame
        let desiredTop = parentFrame.origin.y + row.origin.y
            - MenuMetrics.verticalPadding
        let anchor = Rect(
            x: parentFrame.origin.x + parentFrame.size.width - 10,
            y: desiredTop + childHeight * 0.5 - row.size.height * 0.5,
            width: 1,
            height: row.size.height)
        guard appendLevel(
            menu: submenu,
            anchor: anchor,
            preferring: .trailing,
            parentItemID: item.id)
        else { return }
        levels[index].panel.setExpandedItem(item)
        if selectFirst {
            levels.last?.panel.selectBoundary(first: true)
        }
    }

    private func appendLevel(
        menu: Menu,
        anchor: Rect,
        preferring edge: PopupEdge,
        parentItemID: MenuItemID?
    ) -> Bool {
        guard let scene else { return false }
        let panel = scene.uiContext.construct {
            MenuPanelView(menu: menu)
        }
        panel.modifierFlags = levels.last?.panel.modifierFlags ?? []
        panel.frame = Rect(origin: .zero, size: panel.preferredSize)
        panel.onActivate = { [weak self, weak panel] item in
            guard let self, let panel,
                  let index = levels.firstIndex(where: { $0.panel === panel })
            else { return }
            activate(item, atLevel: index)
        }
        panel.onContentsChange = { [weak self, weak panel] in
            guard let self, let panel,
                  let index = levels.firstIndex(where: { $0.panel === panel })
            else { return }
            resizeLevel(index)
            repositionSubmenus(startingAt: index + 1)
        }
        let popover = scene.uiContext.construct {
            Popover(
                content: panel,
                anchor: anchor,
                preferring: edge,
                dismissal: [],
                focusBehavior: .key,
                level: level)
        }
        popover.onDismiss = { [weak self, weak popover] in
            guard let self, !isDismissing, let popover,
                  let index = levels.firstIndex(where: {
                      $0.popover === popover
                  })
            else { return }
            if index == 0 {
                finish(.cancelled)
            } else {
                levels.removeSubrange(index...)
            }
        }
        levels.append(Level(
            menu: menu,
            panel: panel,
            popover: popover,
            parentItemID: parentItemID))
        scene.present(popover)
        panel.layoutIfNeeded()
        _ = popover.window.makeFirstResponder(panel)
        return true
    }

    private func resizeLevel(_ index: Int) {
        guard levels.indices.contains(index) else { return }
        let panel = levels[index].panel
        let size = panel.preferredSize
        panel.frame = Rect(origin: .zero, size: size)
        levels[index].popover.setContentSize(size)
    }

    private func repositionSubmenus(startingAt start: Int) {
        guard start < levels.count else { return }
        for index in max(1, start)..<levels.count {
            guard let parentItemID = levels[index].parentItemID,
                  let item = levels[index - 1].menu.items.first(where: {
                      $0.id == parentItemID
                  }),
                  let row = levels[index - 1].panel.frame(of: item)
            else { continue }
            let parentFrame = levels[index - 1].popover.window.frame
            let childSize = levels[index].panel.preferredSize
            let desiredTop = parentFrame.origin.y + row.origin.y
                - MenuMetrics.verticalPadding
            levels[index].popover.anchor = Rect(
                x: parentFrame.origin.x + parentFrame.size.width - 10,
                y: desiredTop + childSize.height * 0.5
                    - row.size.height * 0.5,
                width: 1,
                height: row.size.height)
        }
    }

    private func popLevels(toCount count: Int) {
        guard count < levels.count else { return }
        cancelSubmenuTasks(fromLevel: max(0, count - 1))
        if count > 0 {
            levels[count - 1].panel.setExpandedItem(nil)
        }
        guard let scene else {
            levels.removeSubrange(count...)
            return
        }
        let firstVictim = levels[count].popover
        levels.removeSubrange(count...)
        isDismissing = true
        scene.dismiss(firstVictim)
        isDismissing = false
        if let top = levels.last {
            scene.makeKey(top.popover.window)
            top.panel.focusSelection()
        }
    }

    private func activate(_ item: MenuItem, atLevel index: Int) {
        guard levels.indices.contains(index) else { return }
        activate(item, in: levels[index].menu)
    }

    private func activate(_ item: MenuItem, in ownerMenu: Menu) {
        item.validate()
        guard !item.isSeparator, !item.isHidden, item.isEnabled else { return }
        if item.submenu != nil,
           let index = levels.firstIndex(where: { $0.menu === ownerMenu })
        {
            levels[index].panel.setSelected(item)
            openSelectedSubmenu(atLevel: index, selectFirst: true)
            return
        }
        switch item.activationBehavior {
        case .command:
            break
        case .toggle:
            item.state = item.state == .on ? .off : .on
        case let .radio(group):
            for sibling in ownerMenu.items {
                if case let .radio(siblingGroup) = sibling.activationBehavior,
                   siblingGroup == group
                {
                    sibling.state = sibling === item ? .on : .off
                }
            }
        }
        let action = item.action
        finish(.activated(item.id))
        action()
    }

    private func keyEquivalent(
        in menu: Menu,
        matching event: Event
    ) -> (item: MenuItem, menu: Menu)? {
        for item in menu.visibleItems(modifiers: event.modifierFlags) {
            if item.keyEquivalent?.matches(event) == true {
                item.validate()
                if item.isEnabled && !item.isHidden {
                    return (item, menu)
                }
            }
            if item.isEnabled,
               let submenu = item.submenu,
               let match = keyEquivalent(in: submenu, matching: event)
            {
                return match
            }
        }
        return nil
    }

    private func hitItem(
        at scenePoint: Point
    ) -> (level: Int, item: MenuItem)? {
        guard let index = levels.lastIndex(where: {
            $0.popover.window.frame.contains(scenePoint)
        }) else { return nil }
        let local = levels[index].popover.window.windowPoint(
            fromScene: scenePoint)
        guard let item = levels[index].panel.item(at: local) else {
            return nil
        }
        return (index, item)
    }

    private func cancelSubmenuTasks(fromLevel level: Int) {
        for key in submenuTasks.keys where key >= level {
            submenuTasks[key]?.cancel()
            submenuTasks[key] = nil
        }
    }

    private func finish(_ result: MenuPresentationResult) {
        guard self.result == nil else { return }
        self.result = result
        cancelSubmenuTasks(fromLevel: 0)
        typeAheadTask?.cancel()
        typeAheadTask = nil
        let handler = finishHandler
        finishHandler = nil
        let root = levels.first?.popover
        levels.removeAll(keepingCapacity: false)
        if let scene, let root {
            isDismissing = true
            scene.dismiss(root)
            isDismissing = false
        }
        scene?.menuPresentationDidFinish(self)
        handler?(result)
    }
}
