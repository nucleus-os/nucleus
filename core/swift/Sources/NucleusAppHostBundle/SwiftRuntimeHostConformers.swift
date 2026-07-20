// The Swift-native runtime host-bundle conformers — context-id allocation, the
// display-link present-report source, and IOSurface bind/lifecycle.
//
// They are pure logic (an id allocator, a monotonic-clock present report,
// an identity bind, no-op lifecycle). `nucleus_app_host_bundle_install_production`
// constructs them directly alongside the `SwiftResourceHost`-backed conformers.

import NucleusTypes
import NucleusAppHostProtocols
import Glibc
import Synchronization

// MARK: - Context-id allocation

/// Reserve/release layers context ids, skipping the well-known ids (0, the root
/// context `1`, the shell-overlay context `62`, and the compositor context `63`)
/// and reusing released ids. The
/// protocol is `Sendable`; the compositor drives it single-threaded, but a lock
/// keeps it correct under the contract.
final class SwiftContextIDAllocator: ContextIDAllocator {
    private static let rootContextID: UInt32 = 1
    private static let shellOverlayContextID: UInt32 = 62
    private static let compositorContextID: UInt32 = 63

    private struct State {
        var reserved = Set<UInt32>()
        var reusable = [UInt32]()
        var nextReserved: UInt32 = 2
    }

    private let state = Mutex(State())

    private func isWellKnown(_ id: UInt32) -> Bool {
        id == 0
            || id == Self.rootContextID
            || id == Self.shellOverlayContextID
            || id == Self.compositorContextID
    }

    func reserve() throws(ContextIDError) -> UInt32 {
        let reservedID: UInt32? = state.withLock { state in
            while let id = state.reusable.popLast() {
                if isWellKnown(id) { continue }
                if state.reserved.contains(id) { continue }
                state.reserved.insert(id)
                return id
            }
            while state.nextReserved != 0 {
                let id = state.nextReserved
                state.nextReserved =
                    state.nextReserved == UInt32.max
                        ? 0 : state.nextReserved &+ 1
                if isWellKnown(id) { continue }
                if state.reserved.contains(id) { continue }
                state.reserved.insert(id)
                return id
            }
            return nil
        }
        guard let reservedID else {
            throw ContextIDError.contextIDExhausted
        }
        return reservedID
    }

    func release(_ id: UInt32) {
        state.withLock { state in
            if isWellKnown(id) { return }
            guard state.reserved.remove(id) != nil else { return }
            state.reusable.append(id)
        }
    }
}

// MARK: - Display-link present report

/// A present-report source predicting one frame (16.667 ms) ahead of the monotonic
/// clock. Per-output present-id
/// machinery is dormant here (`nextPresentId` is always 1).
@MainActor
final class SwiftDisplayLinkSource: DisplayLinkSource {
    private static let frameIntervalNs: UInt64 = 16_666_667

    func query(contextID: UInt32) throws(DisplayLinkError) -> NucleusTypes.PresentReport {
        if contextID == 0 { throw DisplayLinkError.invalidArgument }
        let predicted = saturatingAdd(monotonicNowNs(), Self.frameIntervalNs)
        return NucleusTypes.PresentReport(
            predictedPresentationNs: predicted,
            targetPresentationNs: predicted,
            nextPresentId: 1)
    }

    private func monotonicNowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    private func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : sum
    }
}

// MARK: - IOSurface bind + lifecycle

/// Identity binder: IOSurface ids are externally managed, so binding returns the
/// id unchanged (rejecting 0).
@MainActor
final class SwiftIOSurfaceBinder: IOSurfaceBinder {
    func bind(iosurfaceID: UInt64) throws(IOSurfaceBindError) -> UInt64 {
        if iosurfaceID == 0 { throw IOSurfaceBindError.invalidArgument }
        return iosurfaceID
    }
}

/// IOSurface handles are externally lifetime-managed; retain/release are no-ops.
final class SwiftIOSurfaceLifecycle: IOSurfaceLifecycle {
    func retain(handle: UInt64) {}
    func release(handle: UInt64) {}
}
