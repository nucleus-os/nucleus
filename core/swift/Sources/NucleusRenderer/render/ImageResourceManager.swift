internal import NucleusRenderModel
import NucleusSkiaGraphiteBridge

/// Explicit lifecycle of one renderer image resource. CPU decode and Graphite
/// residency are distinct states and distinct C++ types; no draw path can
/// observe a decoded-but-not-resident image.
enum ImageResourcePhase: Sendable, Equatable, Hashable {
    case registered
    case decoding
    case decoded
    case uploading
    case resident
    case failed
    case evicted
}

/// Platform-host visibility into the renderer-owned image lifecycle.
///
/// Hosts use this only for acceptance/lifecycle decisions. Draw code continues
/// to consume the stronger `nucleus.skia.Image` type, so observing residency
/// cannot bypass the decode/upload boundary.
@_spi(NucleusPlatform)
public enum RenderImageResidency: Sendable, Equatable {
    case unknown
    case pending
    case resident
    case failed
}

struct ImageDependencyVersion: Sendable, Equatable, Hashable {
    var handle: UInt64
    var version: UInt64
    var phase: ImageResourcePhase
}

struct PaintImageDependencies: Sendable, Equatable, Hashable {
    var versions: [ImageDependencyVersion] = []
}

/// GPU-independent residency state and invalidation graph. Resource transitions
/// update only outputs that actually consumed that handle.
struct ImageResidencyLedger {
    struct Entry: Sendable, Equatable {
        var source: ImageSource
        var phase: ImageResourcePhase
        var version: UInt64
        var outputConsumers: Set<UInt64>
    }

    private(set) var entries: [UInt64: Entry] = [:]
    private(set) var outputRevisions: [UInt64: UInt64] = [:]
    private var nextVersion: UInt64 = 1

    mutating func register(handle: UInt64, source: ImageSource) {
        if let entry = entries[handle] {
            precondition(
                entry.source == source,
                "an image handle cannot change source before eviction")
            return
        }
        entries[handle] = Entry(
            source: source,
            phase: .registered,
            version: allocateVersion(),
            outputConsumers: [])
    }

    mutating func consume(handle: UInt64, outputID: UInt64) {
        precondition(entries[handle] != nil)
        entries[handle]!.outputConsumers.insert(outputID)
    }

    func phase(for handle: UInt64) -> ImageResourcePhase? {
        entries[handle]?.phase
    }

    func outputRevision(_ outputID: UInt64) -> UInt64 {
        outputRevisions[outputID] ?? 0
    }

    func dependencies(for handles: [UInt64]) -> PaintImageDependencies {
        PaintImageDependencies(versions: handles.map { handle in
            guard let entry = entries[handle] else {
                return ImageDependencyVersion(
                    handle: handle, version: 0, phase: .registered)
            }
            return ImageDependencyVersion(
                handle: handle,
                version: entry.version,
                phase: entry.phase)
        })
    }

    @discardableResult
    mutating func transition(
        handle: UInt64,
        to phase: ImageResourcePhase,
        changesVisibleContent: Bool = false
    ) -> Set<UInt64> {
        guard let current = entries[handle]?.phase else { return [] }
        precondition(Self.allowsTransition(from: current, to: phase))
        entries[handle]!.phase = phase
        guard changesVisibleContent else { return [] }
        let revision = allocateVersion()
        entries[handle]!.version = revision
        let consumers = entries[handle]!.outputConsumers
        for outputID in consumers {
            outputRevisions[outputID] = revision
        }
        return consumers
    }

    @discardableResult
    mutating func evict(_ handle: UInt64) -> Set<UInt64> {
        guard let entry = entries[handle] else { return [] }
        let consumers = entry.outputConsumers
        if entry.phase == .resident {
            let revision = allocateVersion()
            for outputID in consumers {
                outputRevisions[outputID] = revision
            }
        }
        entries[handle] = nil
        return consumers
    }

    mutating func removeAll() {
        entries.removeAll()
        outputRevisions.removeAll()
    }

    private static func allowsTransition(
        from: ImageResourcePhase,
        to: ImageResourcePhase
    ) -> Bool {
        switch (from, to) {
        case (.registered, .decoding),
             (.decoding, .decoded),
             (.decoding, .failed),
             (.decoded, .uploading),
             (.uploading, .resident),
             (.uploading, .failed):
            true
        default:
            false
        }
    }

    private mutating func allocateVersion() -> UInt64 {
        let version = nextVersion
        nextVersion &+= 1
        precondition(nextVersion != 0, "image resource version exhausted")
        return version
    }
}

/// Render-thread owner for decode, upload, residency, dependency versions, and
/// targeted output invalidation.
final class ImageResourceManager {
    private struct Record {
        var decoded: nucleus.skia.RasterImage?
        var resident: nucleus.skia.Image?
    }

    private let recorder: nucleus.skia.Recorder
    private let decodeQueue: ImageDecodeQueue
    private var records: [UInt64: Record] = [:]
    private var ledger = ImageResidencyLedger()

    init(recorder: nucleus.skia.Recorder, wakeSink: any AsyncRenderWakeSink) {
        self.recorder = recorder
        self.decodeQueue = ImageDecodeQueue(wakeSink: wakeSink)
    }

    var completionToFrameDemandNanoseconds: UInt64? {
        decodeQueue.completionToFrameDemandNanoseconds
    }

    func outputRevision(_ outputID: UInt64) -> UInt64 {
        ledger.outputRevision(outputID)
    }

    func phase(for handle: UInt64) -> ImageResourcePhase? {
        ledger.phase(for: handle)
    }

    func residency(for handle: UInt64) -> RenderImageResidency {
        switch ledger.phase(for: handle) {
        case nil:
            .unknown
        case .registered?, .decoding?, .decoded?, .uploading?:
            .pending
        case .resident?:
            .resident
        case .failed?, .evicted?:
            .failed
        }
    }

    func image(
        handle: UInt64,
        source: ImageSource,
        outputID: UInt64
    ) -> nucleus.skia.Image? {
        ensureRecord(handle: handle, source: source)
        ledger.consume(handle: handle, outputID: outputID)
        if let resident = records[handle]!.resident, resident.isValid() {
            return resident
        }
        switch ledger.phase(for: handle)! {
        case .registered:
            ledger.transition(handle: handle, to: .decoding)
            if decodeQueue.hasWorkers,
               decodeQueue.submit(handle: handle, source: source)
            {
                return nil
            }
            adopt(
                ImageDecodeQueue.decode(source),
                handle: handle)
            return records[handle]?.resident
        case .decoding, .decoded, .uploading, .failed, .evicted:
            return nil
        case .resident:
            return records[handle]?.resident
        }
    }

    /// Adopt every worker result before output render-gating reads targeted
    /// revisions. Returns the outputs whose visible dependencies changed.
    @discardableResult
    func drainCompletions() -> Set<UInt64> {
        var changed: Set<UInt64> = []
        for result in decodeQueue.drain() {
            changed.formUnion(adopt(result.image, handle: result.handle))
        }
        return changed
    }

    func dependencies(for handles: [UInt64]) -> PaintImageDependencies {
        ledger.dependencies(for: handles)
    }

    func evict(_ handle: UInt64) {
        decodeQueue.cancel(handle: handle)
        records[handle] = nil
        ledger.evict(handle)
    }

    func shutdown() {
        decodeQueue.shutdown()
        records.removeAll()
        ledger.removeAll()
    }

    private func ensureRecord(handle: UInt64, source: ImageSource) {
        ledger.register(handle: handle, source: source)
        if records[handle] == nil {
            records[handle] = Record(decoded: nil, resident: nil)
        }
    }

    @discardableResult
    private func adopt(
        _ decoded: nucleus.skia.RasterImage,
        handle: UInt64
    ) -> Set<UInt64> {
        guard records[handle] != nil,
              ledger.phase(for: handle) == .decoding
        else { return [] }
        guard decoded.isValid() else {
            ledger.transition(handle: handle, to: .failed)
            return []
        }
        records[handle]!.decoded = decoded
        ledger.transition(handle: handle, to: .decoded)
        ledger.transition(handle: handle, to: .uploading)
        let resident = recorder.makeTextureImage(decoded)
        records[handle]!.decoded = nil
        guard resident.isValid() else {
            ledger.transition(handle: handle, to: .failed)
            return []
        }
        records[handle]!.resident = resident
        return ledger.transition(
            handle: handle,
            to: .resident,
            changesVisibleContent: true)
    }
}
