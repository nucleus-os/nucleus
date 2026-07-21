/// Stable identity and content generation for one virtualized collection item.
///
/// Increment `revision` when configuring a retained item view would produce
/// different content. Moving an item does not change its revision.
/// Sendable type erasure for a collection item's identifier.
///
/// Construction requires the erased value itself to be `Sendable`; the
/// unchecked conformance covers only `AnyHashable`'s loss of that conformance.
public struct CollectionItemID: Hashable, @unchecked Sendable {
    private let value: AnyHashable

    public init(_ value: some Hashable & Sendable) {
        self.value = AnyHashable(value)
    }
}

public struct CollectionItem: Hashable, Sendable {
    public let id: CollectionItemID
    public let revision: UInt64

    public init(
        id: some Hashable & Sendable,
        revision: UInt64 = 0
    ) {
        self.id = CollectionItemID(id)
        self.revision = revision
    }
}

public enum CollectionSnapshotError: Error, Equatable, Sendable {
    case duplicateItemID(CollectionItemID)
}

/// An ordered, uniquely identified collection state.
public struct CollectionSnapshot: Equatable, Sendable {
    public let items: [CollectionItem]

    public init(
        items: [CollectionItem]
    ) throws(CollectionSnapshotError) {
        var seen: Set<CollectionItemID> = []
        for item in items where !seen.insert(item.id).inserted {
            throw .duplicateItemID(item.id)
        }
        self.items = items
    }

    public init(
        ids: [some Hashable & Sendable],
        revision: UInt64 = 0
    ) throws(CollectionSnapshotError) {
        try self.init(items: ids.map {
            CollectionItem(id: $0, revision: revision)
        })
    }

    private init(knownUniqueItems: [CollectionItem]) {
        items = knownUniqueItems
    }

    public static let empty = CollectionSnapshot(knownUniqueItems: [])
}

public enum CollectionSelectionMode: Sendable, Equatable {
    case none
    case single
    case multiple
}

/// The result of one collection-owned reorder.
public struct CollectionReorderResult: Sendable, Equatable {
    public let itemID: CollectionItemID
    public let sourceIndex: Int
    /// The insertion boundary in the pre-drop snapshot.
    public let insertionIndex: Int
    public let operation: DragOperation

    public init(
        itemID: CollectionItemID,
        sourceIndex: Int,
        insertionIndex: Int,
        operation: DragOperation
    ) {
        self.itemID = itemID
        self.sourceIndex = sourceIndex
        self.insertionIndex = insertionIndex
        self.operation = operation
    }
}

/// Collection-owned policy for reordering with the portable drag lifecycle.
///
/// Drops are accepted only while the snapshot generation that negotiated the
/// proposal remains current. A stale drop is rejected; collections never guess
/// how an application model changed during an asynchronous transfer.
@MainActor
public struct CollectionReorderingConfiguration {
    public let allowedOperations: Set<DragOperation>
    public let preferredOperation: DragOperation
    public let copyItem:
        (@MainActor (CollectionItem) -> CollectionItem)?
    public let didApply:
        (@MainActor (CollectionSnapshot, CollectionReorderResult) -> Void)?

    public init(
        allowedOperations: Set<DragOperation> = [.move],
        preferredOperation: DragOperation = .move,
        copyItem:
            (@MainActor (CollectionItem) -> CollectionItem)? = nil,
        didApply:
            (@MainActor (CollectionSnapshot, CollectionReorderResult) -> Void)?
            = nil
    ) {
        precondition(
            !allowedOperations.isEmpty
                && allowedOperations.isSubset(of: [.move, .copy]),
            "collection reordering supports move and copy")
        precondition(
            allowedOperations.contains(preferredOperation),
            "preferred operation must be allowed")
        precondition(
            !allowedOperations.contains(.copy) || copyItem != nil,
            "copy reordering requires an identity-producing copy closure")
        self.allowedOperations = allowedOperations
        self.preferredOperation = preferredOperation
        self.copyItem = copyItem
        self.didApply = didApply
    }
}

/// Visual state supplied separately from content configuration.
///
/// Selection/focus changes do not imply that an item's content revision
/// changed and therefore must not force a full item reconfiguration.
public struct CollectionItemState: Sendable, Equatable {
    public var isSelected: Bool
    public var isFocused: Bool

    public init(isSelected: Bool, isFocused: Bool) {
        self.isSelected = isSelected
        self.isFocused = isFocused
    }
}
