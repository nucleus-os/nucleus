/// Stable identity for one retained menu item.
///
/// Construction requires the erased value itself to be `Sendable`; the
/// unchecked conformance covers only `AnyHashable`'s loss of that conformance.
public struct MenuItemID: Hashable, @unchecked Sendable {
    private let value: AnyHashable

    public init(_ value: some Hashable & Sendable) {
        self.value = AnyHashable(value)
    }
}

/// The state marker drawn in a checkable menu row.
public enum MenuItemState: Sendable, Equatable {
    case off
    case on
    case mixed
}

/// What activation does to an item's retained state before invoking its command.
public enum MenuItemActivationBehavior: Sendable, Equatable {
    case command
    case toggle
    case radio(group: MenuItemID)
}

/// A physical shortcut displayed by a menu item and matched while the menu is open.
public struct MenuKeyEquivalent: Sendable, Equatable {
    public var keyCode: KeyCode
    public var modifiers: EventModifierFlags
    public var displayText: String

    public init(
        keyCode: KeyCode,
        modifiers: EventModifierFlags = [],
        displayText: String
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.displayText = displayText
    }

    package func matches(_ event: Event) -> Bool {
        event.type == .keyDown
            && event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.shortcutModifiers)
                == modifiers.intersection(Self.shortcutModifiers)
    }

    private static let shortcutModifiers: EventModifierFlags = [
        .shift, .control, .option, .command,
    ]
}

@MainActor
private final class MenuChangeSubscription {
    private weak var source: (any MenuChangeSource)?
    private let id: UInt64

    init(source: any MenuChangeSource, id: UInt64) {
        self.source = source
        self.id = id
    }

    deinit {
        MainActor.assumeIsolated {
            source?.removeChangeObserver(id)
        }
    }
}

@MainActor
private protocol MenuChangeSource: AnyObject {
    func removeChangeObserver(_ id: UInt64)
}

/// One retained row in a `Menu`.
///
/// Properties are mutable so command validation can update one row without
/// replacing its identity, view, accessibility node, or submenu.
@MainActor
public final class MenuItem: ~Sendable, MenuChangeSource {
    public let id: MenuItemID
    public let isSeparator: Bool

    public var title: String {
        didSet { if title != oldValue { changed() } }
    }
    public var glyph: String? {
        didSet { if glyph != oldValue { changed() } }
    }
    public var keyEquivalent: MenuKeyEquivalent? {
        didSet { if keyEquivalent != oldValue { changed() } }
    }
    public var isEnabled: Bool {
        didSet { if isEnabled != oldValue { changed() } }
    }
    public var isHidden: Bool {
        didSet { if isHidden != oldValue { changed() } }
    }
    public var state: MenuItemState {
        didSet { if state != oldValue { changed() } }
    }
    public var activationBehavior: MenuItemActivationBehavior {
        didSet { if activationBehavior != oldValue { changed() } }
    }
    public var submenu: Menu? {
        didSet { if submenu !== oldValue { changed() } }
    }
    public var accessibilityLabel: String? {
        didSet { if accessibilityLabel != oldValue { changed() } }
    }

    /// An alternate replaces the preceding ordinary item while these modifiers
    /// are held. Alternates remain retained while absent from the visible panel.
    public var isAlternate: Bool {
        didSet { if isAlternate != oldValue { changed() } }
    }
    public var alternateModifiers: EventModifierFlags {
        didSet { if alternateModifiers != oldValue { changed() } }
    }

    /// Explicit mnemonic. Matching is case-insensitive and precedes type-ahead.
    public var mnemonic: Character? {
        didSet { if mnemonic != oldValue { changed() } }
    }

    /// Runs immediately before presentation and again immediately before
    /// activation. It updates this retained item in place.
    public var validation: (@MainActor (MenuItem) -> Void)?
    public var action: @MainActor () -> Void

    private var nextObserverID: UInt64 = 1
    private var changeObservers: [UInt64: @MainActor () -> Void] = [:]

    public init(
        id: some Hashable & Sendable,
        title: String,
        glyph: String? = nil,
        keyEquivalent: MenuKeyEquivalent? = nil,
        isEnabled: Bool = true,
        isHidden: Bool = false,
        state: MenuItemState = .off,
        activationBehavior: MenuItemActivationBehavior = .command,
        submenu: Menu? = nil,
        accessibilityLabel: String? = nil,
        isAlternate: Bool = false,
        alternateModifiers: EventModifierFlags = .option,
        mnemonic: Character? = nil,
        validation: (@MainActor (MenuItem) -> Void)? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = MenuItemID(id)
        self.isSeparator = false
        self.title = title
        self.glyph = glyph
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
        self.isHidden = isHidden
        self.state = state
        self.activationBehavior = activationBehavior
        self.submenu = submenu
        self.accessibilityLabel = accessibilityLabel
        self.isAlternate = isAlternate
        self.alternateModifiers = alternateModifiers
        self.mnemonic = mnemonic
        self.validation = validation
        self.action = action
    }

    private init(separatorID: MenuItemID) {
        self.id = separatorID
        self.isSeparator = true
        self.title = ""
        self.glyph = nil
        self.keyEquivalent = nil
        self.isEnabled = false
        self.isHidden = false
        self.state = .off
        self.activationBehavior = .command
        self.submenu = nil
        self.accessibilityLabel = nil
        self.isAlternate = false
        self.alternateModifiers = []
        self.mnemonic = nil
        self.validation = nil
        self.action = {}
    }

    public static func separator(
        id: some Hashable & Sendable
    ) -> MenuItem {
        MenuItem(separatorID: MenuItemID(id))
    }

    package func validate() {
        guard !isSeparator else { return }
        validation?(self)
    }

    package func observeChanges(
        _ observer: @escaping @MainActor () -> Void
    ) -> AnyObject {
        let id = nextObserverID
        nextObserverID &+= 1
        precondition(nextObserverID != 0, "menu observer identity exhausted")
        changeObservers[id] = observer
        return MenuChangeSubscription(source: self, id: id)
    }

    fileprivate func removeChangeObserver(_ id: UInt64) {
        changeObservers[id] = nil
    }

    private func changed() {
        for observer in Array(changeObservers.values) {
            observer()
        }
    }
}

/// A retained, portable desktop menu model.
@MainActor
public final class Menu: ~Sendable, MenuChangeSource {
    public var items: [MenuItem] {
        didSet {
            preconditionUniqueItems()
            observeItems()
            changed()
        }
    }

    private var nextObserverID: UInt64 = 1
    private var changeObservers: [UInt64: @MainActor () -> Void] = [:]
    private var itemObservations: [AnyObject] = []

    public init(items: [MenuItem]) {
        self.items = items
        preconditionUniqueItems()
        observeItems()
    }

    package func visibleItems(
        modifiers: EventModifierFlags
    ) -> [MenuItem] {
        var result: [MenuItem] = []
        for item in items where !item.isHidden {
            guard item.isAlternate else {
                result.append(item)
                continue
            }
            let required = item.alternateModifiers
            guard modifiers.intersection(required) == required else {
                continue
            }
            if let previous = result.last, !previous.isSeparator {
                result.removeLast()
            }
            result.append(item)
        }
        return result
    }

    package func validateRecursively() {
        preconditionValidHierarchy()
        var visited: Set<ObjectIdentifier> = []
        validateRecursively(visited: &visited)
    }

    private func validateRecursively(
        visited: inout Set<ObjectIdentifier>
    ) {
        guard visited.insert(ObjectIdentifier(self)).inserted else { return }
        for item in items {
            item.validate()
            item.submenu?.validateRecursively(visited: &visited)
        }
    }

    private func preconditionValidHierarchy() {
        var menusOnPath: Set<ObjectIdentifier> = []
        var itemIDs: Set<MenuItemID> = []
        validateHierarchy(
            menusOnPath: &menusOnPath,
            itemIDs: &itemIDs)
    }

    private func validateHierarchy(
        menusOnPath: inout Set<ObjectIdentifier>,
        itemIDs: inout Set<MenuItemID>
    ) {
        let identity = ObjectIdentifier(self)
        precondition(
            menusOnPath.insert(identity).inserted,
            "a menu hierarchy cannot contain a submenu cycle")
        defer { menusOnPath.remove(identity) }
        for item in items {
            precondition(
                itemIDs.insert(item.id).inserted,
                "menu item identities must be unique within a hierarchy")
            item.submenu?.validateHierarchy(
                menusOnPath: &menusOnPath,
                itemIDs: &itemIDs)
        }
    }

    package func observeChanges(
        _ observer: @escaping @MainActor () -> Void
    ) -> AnyObject {
        let id = nextObserverID
        nextObserverID &+= 1
        precondition(nextObserverID != 0, "menu observer identity exhausted")
        changeObservers[id] = observer
        return MenuChangeSubscription(source: self, id: id)
    }

    fileprivate func removeChangeObserver(_ id: UInt64) {
        changeObservers[id] = nil
    }

    private func changed() {
        for observer in Array(changeObservers.values) {
            observer()
        }
    }

    private func preconditionUniqueItems() {
        precondition(
            Set(items.map(\.id)).count == items.count,
            "menu item identities must be unique within one menu")
    }

    private func observeItems() {
        itemObservations = items.map { item in
            item.observeChanges { [weak self] in
                self?.changed()
            }
        }
    }
}

extension View {
    /// Lazily produce a retained menu for a secondary click.
    public var contextMenuProvider: (@MainActor () -> Menu)? {
        get { storedContextMenuProvider }
        set { storedContextMenuProvider = newValue }
    }
}
