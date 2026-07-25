internal import NucleusRenderModel
import NucleusSkiaGraphiteBridge
import Tracy

enum ImageResourcePhase: Sendable, Equatable, Hashable {
    case registered(generation: UInt64)
    case decoding(generation: UInt64)
    case ready(generation: UInt64)
    case failed(generation: UInt64, reason: ImageDecodeFailure)

    var generation: UInt64 {
        switch self {
        case .registered(let generation),
             .decoding(let generation),
             .ready(let generation),
             .failed(let generation, _):
            generation
        }
    }
}

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

/// GPU-independent generation state and targeted invalidation graph.
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

    @discardableResult
    mutating func registerNew(
        handle: UInt64,
        source: ImageSource
    ) -> Bool {
        guard handle != 0, entries[handle] == nil else { return false }
        entries[handle] = Entry(
            source: source,
            phase: .registered(generation: 1),
            version: allocateVersion(),
            outputConsumers: [])
        return true
    }

    mutating func consume(handle: UInt64, outputID: UInt64) {
        guard entries[handle] != nil else { return }
        entries[handle]!.outputConsumers.insert(outputID)
    }

    func source(for handle: UInt64) -> ImageSource? {
        entries[handle]?.source
    }

    func phase(for handle: UInt64) -> ImageResourcePhase? {
        entries[handle]?.phase
    }

    func failure(for handle: UInt64) -> ImageDecodeFailure? {
        guard case .failed(_, let reason) = entries[handle]?.phase
        else { return nil }
        return reason
    }

    func outputRevision(_ outputID: UInt64) -> UInt64 {
        outputRevisions[outputID] ?? 0
    }

    func dependencies(for handles: [UInt64]) -> PaintImageDependencies {
        PaintImageDependencies(versions: handles.map { handle in
            guard let entry = entries[handle] else {
                return ImageDependencyVersion(
                    handle: handle,
                    version: 0,
                    phase: .registered(generation: 0))
            }
            return ImageDependencyVersion(
                handle: handle,
                version: entry.version,
                phase: entry.phase)
        })
    }

    @discardableResult
    mutating func beginDecoding(
        handle: UInt64,
        generation: UInt64
    ) -> Bool {
        guard entries[handle]?.phase
                == .registered(generation: generation)
        else { return false }
        entries[handle]!.phase = .decoding(generation: generation)
        return true
    }

    @discardableResult
    mutating func finishReady(
        handle: UInt64,
        generation: UInt64
    ) -> Set<UInt64> {
        guard entries[handle]?.phase
                == .decoding(generation: generation)
        else { return [] }
        entries[handle]!.phase = .ready(generation: generation)
        return invalidateConsumers(handle)
    }

    @discardableResult
    mutating func finishFailed(
        handle: UInt64,
        generation: UInt64,
        reason: ImageDecodeFailure
    ) -> Set<UInt64> {
        guard entries[handle]?.phase
                == .decoding(generation: generation)
        else { return [] }
        entries[handle]!.phase = .failed(
            generation: generation,
            reason: reason)
        return invalidateConsumers(handle)
    }

    @discardableResult
    mutating func failCurrent(
        handle: UInt64,
        reason: ImageDecodeFailure
    ) -> Set<UInt64> {
        guard let phase = entries[handle]?.phase else { return [] }
        entries[handle]!.phase = .failed(
            generation: phase.generation,
            reason: reason)
        return invalidateConsumers(handle)
    }

    @discardableResult
    mutating func retry(_ handle: UInt64) -> UInt64? {
        guard let entry = entries[handle] else { return nil }
        let generation = nextGeneration(after: entry.phase.generation)
        entries[handle]!.phase = .registered(generation: generation)
        invalidateConsumers(handle)
        return generation
    }

    @discardableResult
    mutating func replace(
        _ handle: UInt64,
        with source: ImageSource
    ) -> UInt64? {
        guard let entry = entries[handle] else { return nil }
        let generation = nextGeneration(after: entry.phase.generation)
        entries[handle]!.source = source
        entries[handle]!.phase = .registered(generation: generation)
        invalidateConsumers(handle)
        return generation
    }

    @discardableResult
    mutating func evict(_ handle: UInt64) -> Set<UInt64> {
        guard let entry = entries.removeValue(forKey: handle)
        else { return [] }
        let revision = allocateVersion()
        for outputID in entry.outputConsumers {
            outputRevisions[outputID] = revision
        }
        return entry.outputConsumers
    }

    mutating func removeAll() {
        entries.removeAll()
        outputRevisions.removeAll()
    }

    @discardableResult
    private mutating func invalidateConsumers(
        _ handle: UInt64
    ) -> Set<UInt64> {
        guard entries[handle] != nil else { return [] }
        let revision = allocateVersion()
        entries[handle]!.version = revision
        let consumers = entries[handle]!.outputConsumers
        for outputID in consumers {
            outputRevisions[outputID] = revision
        }
        return consumers
    }

    private func nextGeneration(after generation: UInt64) -> UInt64 {
        let next = generation &+ 1
        precondition(next != 0, "image resource generation exhausted")
        return next
    }

    private mutating func allocateVersion() -> UInt64 {
        let version = nextVersion
        nextVersion &+= 1
        precondition(nextVersion != 0, "image resource version exhausted")
        return version
    }
}

/// Render-thread owner for decode, bounded upload, residency, failure
/// diagnostics, dependency versions, and targeted output invalidation.
final class ImageResourceManager {
    typealias UploadOperation =
        (nucleus.skia.RasterImage) -> nucleus.skia.Image?

    private struct Record {
        var resident: nucleus.skia.Image?
    }

    private static let maximumCompletionDrainPerFrame = 16
    private static let maximumUploadsPerFrame = 4
    private static let maximumUploadBytesPerFrame = 64 * 1024 * 1024

    private let decodeQueue: ImageDecodeQueue
    private let uploadOperation: UploadOperation
    private var records: [UInt64: Record] = [:]
    private var deferredCompletions: [ImageDecodeCompletion] = []
    private var ledger = ImageResidencyLedger()
    private(set) var failureCounts: [ImageDecodeFailure: UInt64] = [:]
    private(set) var totalFailureCount: UInt64 = 0

    init(
        recorder: nucleus.skia.Recorder,
        wakeSink: any AsyncRenderWakeSink
    ) {
        self.decodeQueue = ImageDecodeQueue(wakeSink: wakeSink)
        self.uploadOperation = { decoded in
            let resident = recorder.makeTextureImage(decoded)
            return resident.isValid() ? resident : nil
        }
    }

    init(
        decodeQueue: ImageDecodeQueue,
        uploadOperation: @escaping UploadOperation
    ) {
        self.decodeQueue = decodeQueue
        self.uploadOperation = uploadOperation
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

    func failure(for handle: UInt64) -> ImageDecodeFailure? {
        ledger.failure(for: handle)
    }

    func residency(for handle: UInt64) -> RenderImageResidency {
        switch ledger.phase(for: handle) {
        case nil:
            .unknown
        case .registered?, .decoding?:
            .pending
        case .ready?:
            .resident
        case .failed?:
            .failed
        }
    }

    @discardableResult
    func registerNew(
        handle: UInt64,
        source: ImageSource
    ) -> Bool {
        guard ledger.registerNew(handle: handle, source: source)
        else { return false }
        records[handle] = Record(resident: nil)
        return true
    }

    @discardableResult
    func retry(handle: UInt64) -> Bool {
        guard ledger.phase(for: handle) != nil else { return false }
        cancelOutstanding(handle)
        records[handle]?.resident = nil
        return ledger.retry(handle) != nil
    }

    @discardableResult
    func replace(
        handle: UInt64,
        with source: ImageSource
    ) -> Bool {
        guard ledger.phase(for: handle) != nil else { return false }
        cancelOutstanding(handle)
        records[handle]?.resident = nil
        return ledger.replace(handle, with: source) != nil
    }

    func image(
        handle: UInt64,
        source: ImageSource,
        outputID: UInt64
    ) -> nucleus.skia.Image? {
        if ledger.phase(for: handle) == nil {
            guard registerNew(handle: handle, source: source)
            else { return nil }
        }
        guard ledger.source(for: handle) == source else {
            // Preserving a handle across source identity changes is an explicit
            // mutation. Never draw the prior resident image for mismatched data.
            cancelOutstanding(handle)
            records[handle]?.resident = nil
            _ = ledger.failCurrent(
                handle: handle,
                reason: .decodeFailure)
            recordFailure(.decodeFailure)
            return nil
        }

        ledger.consume(handle: handle, outputID: outputID)
        switch ledger.phase(for: handle)! {
        case .registered(let generation):
            guard ledger.beginDecoding(
                handle: handle,
                generation: generation)
            else { return nil }
            guard decodeQueue.submit(
                handle: handle,
                generation: generation,
                source: source)
            else {
                _ = finishFailure(
                    handle: handle,
                    generation: generation,
                    reason: .decodeFailure)
                return nil
            }
            return nil
        case .decoding, .failed:
            return nil
        case .ready:
            guard let resident = records[handle]?.resident,
                  resident.isValid()
            else { return nil }
            return resident
        }
    }

    /// Process a bounded amount of terminal and upload work at the top of a
    /// frame. Stale completions are dropped by `(handle, generation)` identity;
    /// dropping a stale success releases its immutable raster image here.
    @discardableResult
    func drainCompletions() -> Set<UInt64> {
        deferredCompletions.append(contentsOf: decodeQueue.drain(
            maxCount: Self.maximumCompletionDrainPerFrame))

        var changed: Set<UInt64> = []
        var uploads = 0
        var uploadBytes = 0
        var consumed = 0

        for completion in deferredCompletions {
            guard ledger.phase(for: completion.handle)?.generation
                    == completion.generation,
                  case .decoding? = ledger.phase(for: completion.handle)
            else {
                consumed += 1
                continue
            }

            switch completion.result {
            case .failure(let reason):
                changed.formUnion(finishFailure(
                    handle: completion.handle,
                    generation: completion.generation,
                    reason: reason))
                consumed += 1
            case .success(let decoded):
                let bytes = decodedByteCount(decoded)
                let exceedsBudget =
                    uploads >= Self.maximumUploadsPerFrame
                    || (uploadBytes > 0
                        && (uploadBytes >= Self.maximumUploadBytesPerFrame
                            || bytes > Self.maximumUploadBytesPerFrame - uploadBytes))
                if exceedsBudget {
                    break
                }
                if let resident = uploadOperation(decoded.image),
                   resident.isValid()
                {
                    records[completion.handle]?.resident = resident
                    changed.formUnion(ledger.finishReady(
                        handle: completion.handle,
                        generation: completion.generation))
                } else {
                    changed.formUnion(finishFailure(
                        handle: completion.handle,
                        generation: completion.generation,
                        reason: .uploadFailure))
                }
                uploads += 1
                uploadBytes += bytes
                consumed += 1
            }
        }
        if consumed > 0 {
            deferredCompletions.removeFirst(consumed)
        }
        return changed
    }

    func dependencies(
        for handles: [UInt64]
    ) -> PaintImageDependencies {
        ledger.dependencies(for: handles)
    }

    func evict(_ handle: UInt64) {
        cancelOutstanding(handle)
        records[handle] = nil
        ledger.evict(handle)
    }

    func shutdown() {
        decodeQueue.shutdown()
        deferredCompletions.removeAll()
        records.removeAll()
        ledger.removeAll()
    }

    private func cancelOutstanding(_ handle: UInt64) {
        decodeQueue.cancel(handle: handle)
        deferredCompletions.removeAll { $0.handle == handle }
    }

    @discardableResult
    private func finishFailure(
        handle: UInt64,
        generation: UInt64,
        reason: ImageDecodeFailure
    ) -> Set<UInt64> {
        guard ledger.phase(for: handle)
                == .decoding(generation: generation)
        else { return [] }
        let changed = ledger.finishFailed(
            handle: handle,
            generation: generation,
            reason: reason)
        recordFailure(reason)
        return changed
    }

    private func recordFailure(_ reason: ImageDecodeFailure) {
        failureCounts[reason, default: 0] &+= 1
        totalFailureCount &+= 1
        Trace.plot(
            "swift.renderer.image_decode.failures",
            totalFailureCount)
    }

    private func decodedByteCount(_ decoded: DecodedImage) -> Int {
        let pixels = Int(decoded.width).multipliedReportingOverflow(
            by: Int(decoded.height))
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : bytes.partialValue
    }
}
