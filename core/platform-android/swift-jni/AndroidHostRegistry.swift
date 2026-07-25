import NucleusAndroidC
import NucleusAndroidHostLifecycle

enum AndroidHostRegistry {
    private static let hosts = WeakHostRegistry<AndroidHost>()

    static func register(_ host: AndroidHost) -> UInt64 {
        hosts.register(host)
    }

    static func lookup(_ rawID: Int64) -> AndroidHost? {
        hosts.lookup(UInt64(bitPattern: rawID))
    }

    static func unregister(_ id: UInt64, host: AndroidHost) {
        hosts.unregister(id, host: host)
    }
}

struct AndroidOwnerThread {
    private let guardrail: OwnerThreadGuard

    init() {
        guardrail = OwnerThreadGuard(
            currentID: { nucleus_android_current_thread_id() },
            reportViolation: { operation in
                operation.withUTF8Buffer { bytes in
                    var terminated = unsafe Array(bytes)
                    terminated.append(0)
                    terminated.withUnsafeBytes {
                        unsafe nucleus_android_log_thread_violation(
                            $0.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                }
            })
    }

    func isCurrent(operation: StaticString) -> Bool {
        guardrail.accepts(operation)
    }
}
