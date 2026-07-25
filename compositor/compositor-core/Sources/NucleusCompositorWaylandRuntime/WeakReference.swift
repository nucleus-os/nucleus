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
