/// Actor-confined weak storage for relationship lists and indexes.
///
/// Named boxes remain appropriate when they also preserve identity, ordering,
/// teardown, or protocol metadata. This type covers the one-property case.
@MainActor
@safe final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

/// Ordered weak membership with pruning centralized at every observation.
@MainActor
@safe struct WeakObjectList<Value: AnyObject> {
    private var storage: [WeakReference<Value>] = []

    var isEmpty: Bool {
        mutating get { liveValues().isEmpty }
    }

    var count: Int {
        mutating get { liveValues().count }
    }

    var last: Value? {
        mutating get { liveValues().last }
    }

    mutating func append(_ value: Value) {
        storage.append(WeakReference(value))
    }

    mutating func remove(_ value: Value) {
        storage.removeAll { $0.value == nil || $0.value === value }
    }

    mutating func removeAll(where shouldRemove: (Value) -> Bool) {
        storage.removeAll {
            guard let value = $0.value else { return true }
            return shouldRemove(value)
        }
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func liveValues() -> [Value] {
        storage.removeAll { $0.value == nil }
        return storage.compactMap(\.value)
    }
}

/// Keyed weak membership that removes dead entries during lookup and iteration.
@MainActor
@safe struct WeakObjectMap<Key: Hashable, Value: AnyObject> {
    private var storage: [Key: WeakReference<Value>] = [:]

    mutating func insert(_ value: Value, forKey key: Key) {
        storage[key] = WeakReference(value)
    }

    mutating func value(forKey key: Key) -> Value? {
        guard let box = storage[key] else { return nil }
        guard let value = box.value else {
            storage.removeValue(forKey: key)
            return nil
        }
        return value
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        storage.removeValue(forKey: key)?.value
    }

    mutating func liveValues() -> [Value] {
        storage = storage.filter { $0.value.value != nil }
        return storage.values.compactMap(\.value)
    }

    mutating func liveEntries() -> [Key: Value] {
        storage = storage.filter { $0.value.value != nil }
        return storage.reduce(into: [:]) { entries, element in
            entries[element.key] = element.value.value
        }
    }
}
