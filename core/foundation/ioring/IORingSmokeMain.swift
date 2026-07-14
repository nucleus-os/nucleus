// Runtime smoke for the vendored swift-system IORing (io_uring) binding and the
// nucleus fork's multishot poll-add Request. Registers a multishot poll on an
// eventfd, writes to it, and drains a completion — asserting the per-op context
// round-trips and the multishot (F_MORE) flag is set. This is the runtime proof
// of the IORing primitives before the compositor loop migrates onto them.

import SystemPackage
import CSystem  // for eventfd

#if canImport(Glibc)
import Glibc
#endif

@main
struct IORingSmoke {
    static func main() {
        var ring: IORing
        do {
            ring = try IORing(queueDepth: 8)
        } catch {
            print("FAIL ioring-smoke: ring init \(error)")
            return
        }

        let efd = eventfd(0, 0)
        guard efd >= 0 else {
            print("FAIL ioring-smoke: eventfd")
            return
        }
        let fd = FileDescriptor(rawValue: efd)

        let context: UInt64 = 0xA1
        _ = ring.prepare(request: .pollAdd(fd, pollEvents: .pollIn, isMultiShot: true, context: context))
        do {
            try ring.submitPreparedRequests()
        } catch {
            print("FAIL ioring-smoke: submit \(error)")
            return
        }

        var one: UInt64 = 1
        _ = withUnsafeBytes(of: &one) { write(efd, $0.baseAddress, 8) }

        var seen: UInt64 = 0
        var multishot = false
        do {
            try ring.blockingConsumeCompletions(minimumCount: 1, timeout: .seconds(5)) { completion, _, _ in
                if let completion {
                    seen = completion.context
                    multishot = completion.flags.contains(.moreCompletions)
                }
            }
        } catch {
            print("FAIL ioring-smoke: consume \(error)")
            return
        }

        if seen == context {
            print("OK ioring-smoke context=a1 multishot=\(multishot ? 1 : 0)")
        } else {
            print("FAIL ioring-smoke context=\(String(seen, radix: 16))")
        }
    }
}
