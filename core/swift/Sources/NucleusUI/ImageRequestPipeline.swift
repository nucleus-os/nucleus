import NucleusLayers

/// Stable identity for one retained image consumer.
public struct ImageRequestID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        precondition(rawValue != 0, "image request identity zero is reserved")
        self.rawValue = rawValue
    }
}

/// Semantic source identity before host-specific icon resolution.
public enum ImageRequestSource: Hashable, Sendable {
    /// A file path or encoded `data:` URI.
    case resource(String)
    /// An XDG/platform icon name in a named theme.
    case icon(name: String, theme: String)
}

/// Immutable value passed to a host resolver off the main actor.
public struct ImageSourceQuery: Sendable, Equatable {
    public let source: ImageRequestSource
    public let targetPixelWidth: UInt32
    public let targetPixelHeight: UInt32
    public let appearance: Appearance
    public let iconThemeGeneration: UInt64

    public init(
        source: ImageRequestSource,
        targetPixelWidth: UInt32,
        targetPixelHeight: UInt32,
        appearance: Appearance,
        iconThemeGeneration: UInt64
    ) {
        self.source = source
        self.targetPixelWidth = targetPixelWidth
        self.targetPixelHeight = targetPixelHeight
        self.appearance = appearance
        self.iconThemeGeneration = iconThemeGeneration
    }
}

/// Host source resolution. The renderer remains the sole decoder.
public struct ImageSourceResolver: Sendable {
    public typealias Resolve =
        @Sendable (ImageSourceQuery) async -> String?

    private let resolveBody: Resolve

    public init(resolve: @escaping Resolve) {
        resolveBody = resolve
    }

    public func resolve(_ query: ImageSourceQuery) async -> String? {
        switch query.source {
        case .resource(let source):
            return source.isEmpty ? nil : source
        case .icon:
            return await resolveBody(query)
        }
    }

    public static let directResourcesOnly = ImageSourceResolver { _ in nil }
}

/// One immutable retained-consumer request.
public struct ImageRequest: Sendable, Equatable {
    public let id: ImageRequestID
    public let source: ImageRequestSource
    /// Point-space decode target before backing-scale conversion.
    public let targetSize: Size
    public let backingScaleFactor: BackingScaleFactor
    public let appearance: Appearance
    public let iconThemeGeneration: UInt64
    public let cancellationGeneration: UInt64

    public init(
        id: ImageRequestID,
        source: ImageRequestSource,
        targetSize: Size,
        backingScaleFactor: BackingScaleFactor = .one,
        appearance: Appearance,
        iconThemeGeneration: UInt64 = 0,
        cancellationGeneration: UInt64
    ) {
        self.id = id
        self.source = source
        self.targetSize = Size(
            width: targetSize.width.isFinite
                ? max(0, targetSize.width)
                : 0,
            height: targetSize.height.isFinite
                ? max(0, targetSize.height)
                : 0)
        self.backingScaleFactor = backingScaleFactor
        self.appearance = appearance
        self.iconThemeGeneration = iconThemeGeneration
        self.cancellationGeneration = cancellationGeneration
    }
}

public enum ImageRequestFailure: Sendable, Equatable {
    case invalidRequest
    case unresolved
    case registrationFailed
    case capacityExceeded
    case cancelled
    case shutdown
}

@MainActor
public enum ImageRequestOutcome {
    case success(ImageResource)
    case failure(ImageRequestFailure)
}

@MainActor
public struct ImageRequestResult {
    public let requestID: ImageRequestID
    public let cancellationGeneration: UInt64
    public let outcome: ImageRequestOutcome
}

public struct ImageRequestCacheLimits: Sendable, Equatable {
    public var maximumEntries: Int
    public var maximumDecodedBytes: Int
    public var maximumNegativeEntries: Int
    public var maximumInFlightRequests: Int
    public var negativeResultLifetime: Duration

    public init(
        maximumEntries: Int = 128,
        maximumDecodedBytes: Int = 64 * 1_024 * 1_024,
        maximumNegativeEntries: Int = 256,
        maximumInFlightRequests: Int = 64,
        negativeResultLifetime: Duration = .seconds(5)
    ) {
        precondition(
            maximumEntries > 0
                && maximumDecodedBytes > 0
                && maximumNegativeEntries > 0
                && maximumInFlightRequests > 0)
        self.maximumEntries = maximumEntries
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumNegativeEntries = maximumNegativeEntries
        self.maximumInFlightRequests = maximumInFlightRequests
        self.negativeResultLifetime = negativeResultLifetime
    }
}

/// Cancels one consumer without cancelling coalesced consumers of the same
/// source.
@MainActor
public final class ImageRequestToken {
    private weak var pipeline: ImageRequestPipeline?
    private let subscriptionID: UInt64
    private var isCancelled = false

    package init(
        pipeline: ImageRequestPipeline?,
        subscriptionID: UInt64
    ) {
        self.pipeline = pipeline
        self.subscriptionID = subscriptionID
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        pipeline?.cancel(subscriptionID: subscriptionID)
        pipeline = nil
    }

    isolated deinit {
        cancel()
    }
}

/// Context-owned UI request/cache layer over `ImageResource`.
///
/// This layer resolves source identity and coalesces registration. It does not
/// decode pixels: registrations feed the existing renderer-owned
/// `ImageDecodeQueue` when published.
@MainActor
public final class ImageRequestPipeline {
    public typealias Completion =
        @MainActor (ImageRequestResult) -> Void
    public typealias Diagnostic =
        @MainActor (ImageRequestFailure, ImageRequest) -> Void
    package typealias ResourceFactory =
        @MainActor (String, Size, UInt64) -> ImageResource?

    private struct CacheKey: Hashable {
        var source: ImageRequestSource
        var pixelWidth: UInt32
        var pixelHeight: UInt32
        var appearance: UInt8
        var iconThemeGeneration: UInt64
        var resourceGeneration: UInt64
    }

    private struct CacheEntry {
        var resource: ImageResource
        var cost: Int
        var access: UInt64
    }

    private struct NegativeEntry {
        var failure: ImageRequestFailure
        var expiration: UIClock.Instant
        var access: UInt64
    }

    private struct Subscriber {
        var request: ImageRequest
        var completion: Completion
    }

    private struct InFlight {
        var work: Task<String?, Never>
        var completionTask: Task<Void, Never>?
        var subscribers: [UInt64: Subscriber]
    }

    private let resourceHostHandle: UInt64
    private let runtimeHost: LayerRuntimeHost
    private let resolver: ImageSourceResolver
    private let limits: ImageRequestCacheLimits
    private let diagnostic: Diagnostic
    private let clock: UIClock

    private var cache: [CacheKey: CacheEntry] = [:]
    private var negativeCache: [CacheKey: NegativeEntry] = [:]
    private var inFlight: [CacheKey: InFlight] = [:]
    private var keyBySubscription: [UInt64: CacheKey] = [:]
    private var cachedCost = 0
    private var nextAccess: UInt64 = 1
    private var nextSubscriptionID: UInt64 = 1
    private var resourceGeneration: UInt64 = 1
    private var isShutdown = false
    package var resourceFactory: ResourceFactory

    public init(
        resourceHostHandle: UInt64,
        runtimeHost: LayerRuntimeHost = .inMemory(),
        clock: UIClock = .continuous,
        resolver: ImageSourceResolver = .directResourcesOnly,
        limits: ImageRequestCacheLimits = ImageRequestCacheLimits(),
        diagnostic: @escaping Diagnostic = { _, _ in }
    ) {
        self.resourceHostHandle = resourceHostHandle
        self.runtimeHost = runtimeHost
        self.clock = clock
        self.resolver = resolver
        self.limits = limits
        self.diagnostic = diagnostic
        self.resourceFactory = { [runtimeHost] source, size, resourceHostHandle in
            ImageResource(
                source: source,
                decodeSize: size,
                resourceHostHandle: resourceHostHandle,
                runtimeHost: runtimeHost)
        }
        cache.reserveCapacity(limits.maximumEntries)
        negativeCache.reserveCapacity(limits.maximumNegativeEntries)
        inFlight.reserveCapacity(limits.maximumInFlightRequests)
    }

    isolated deinit {
        shutdown()
    }

    @discardableResult
    public func request(
        _ request: ImageRequest,
        completion: @escaping Completion
    ) -> ImageRequestToken {
        guard !isShutdown else {
            complete(
                request,
                outcome: .failure(.shutdown),
                with: completion)
            return ImageRequestToken(pipeline: nil, subscriptionID: 0)
        }
        let key = cacheKey(for: request)
        guard key.pixelWidth > 0, key.pixelHeight > 0,
              resourceHostHandle != 0
        else {
            diagnostic(.invalidRequest, request)
            complete(
                request,
                outcome: .failure(.invalidRequest),
                with: completion)
            return ImageRequestToken(pipeline: nil, subscriptionID: 0)
        }

        let access = takeAccess()
        if var entry = cache[key] {
            entry.access = access
            cache[key] = entry
            complete(
                request,
                outcome: .success(entry.resource),
                with: completion)
            return ImageRequestToken(pipeline: nil, subscriptionID: 0)
        }
        if var negative = negativeCache[key] {
            if negative.expiration > clock.now {
                negative.access = access
                negativeCache[key] = negative
                complete(
                    request,
                    outcome: .failure(negative.failure),
                    with: completion)
                return ImageRequestToken(pipeline: nil, subscriptionID: 0)
            }
            negativeCache[key] = nil
        }

        if case .resource(let source) = request.source {
            finishDirect(
                key: key,
                source: source,
                request: request,
                completion: completion)
            return ImageRequestToken(pipeline: nil, subscriptionID: 0)
        }

        let subscriptionID = takeSubscriptionID()
        let subscriber = Subscriber(
            request: request,
            completion: completion)
        keyBySubscription[subscriptionID] = key
        if var pending = inFlight[key] {
            pending.subscribers[subscriptionID] = subscriber
            inFlight[key] = pending
            return ImageRequestToken(
                pipeline: self,
                subscriptionID: subscriptionID)
        }

        guard inFlight.count < limits.maximumInFlightRequests else {
            keyBySubscription[subscriptionID] = nil
            diagnostic(.capacityExceeded, request)
            complete(
                request,
                outcome: .failure(.capacityExceeded),
                with: completion)
            return ImageRequestToken(pipeline: nil, subscriptionID: 0)
        }

        let query = ImageSourceQuery(
            source: request.source,
            targetPixelWidth: key.pixelWidth,
            targetPixelHeight: key.pixelHeight,
            appearance: request.appearance,
            iconThemeGeneration: request.iconThemeGeneration)
        let resolver = self.resolver
        let work: Task<String?, Never> = Task.detached(
            priority: .userInitiated
        ) {
            guard !Task.isCancelled else {
                return Optional<String>.none
            }
            return await resolver.resolve(query)
        }
        inFlight[key] = InFlight(
            work: work,
            completionTask: nil,
            subscribers: [subscriptionID: subscriber])
        let completionTask = Task { @MainActor [weak self] in
            let source = await work.value
            guard !Task.isCancelled else { return }
            self?.finish(key: key, resolvedSource: source)
        }
        inFlight[key]?.completionTask = completionTask
        return ImageRequestToken(
            pipeline: self,
            subscriptionID: subscriptionID)
    }

    public func handleMemoryPressure() {
        cache.removeAll(keepingCapacity: true)
        negativeCache.removeAll(keepingCapacity: true)
        cachedCost = 0
    }

    /// Separates registrations from a replaced renderer/resource host
    /// generation. Outstanding work is cancelled because it names the old host.
    public func invalidateHostResources() {
        resourceGeneration &+= 1
        precondition(
            resourceGeneration != 0,
            "image resource generation exhausted")
        cancelInFlight(with: .cancelled)
        handleMemoryPressure()
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelInFlight(with: .shutdown)
        handleMemoryPressure()
    }

    public var cachedEntryCount: Int { cache.count }
    public var cachedDecodedByteCost: Int { cachedCost }
    public var negativeEntryCount: Int { negativeCache.count }
    public var inFlightRequestCount: Int { inFlight.count }
    public var consumerCount: Int { keyBySubscription.count }

    package func cancel(subscriptionID: UInt64) {
        guard let key = keyBySubscription.removeValue(
            forKey: subscriptionID),
            var pending = inFlight[key]
        else { return }
        pending.subscribers[subscriptionID] = nil
        if pending.subscribers.isEmpty {
            pending.work.cancel()
            pending.completionTask?.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = pending
        }
    }

    private func finish(
        key: CacheKey,
        resolvedSource: String?
    ) {
        guard let pending = inFlight.removeValue(forKey: key) else {
            return
        }
        for subscriptionID in pending.subscribers.keys {
            keyBySubscription[subscriptionID] = nil
        }
        guard !isShutdown else { return }

        let representative = pending.subscribers.values.first?.request
        let resource = resolvedSource.flatMap {
            resourceFactory(
                $0,
                Size(
                    width: Double(key.pixelWidth),
                    height: Double(key.pixelHeight)),
                resourceHostHandle)
        }
        if let resource {
            insert(resource, for: key)
            for subscriber in pending.subscribers.values {
                complete(
                    subscriber.request,
                    outcome: .success(resource),
                    with: subscriber.completion)
            }
            return
        }

        let failure: ImageRequestFailure =
            resolvedSource == nil ? .unresolved : .registrationFailed
        insertNegative(failure, for: key)
        if let representative {
            diagnostic(failure, representative)
        }
        for subscriber in pending.subscribers.values {
            complete(
                subscriber.request,
                outcome: .failure(failure),
                with: subscriber.completion)
        }
    }

    private func finishDirect(
        key: CacheKey,
        source: String,
        request: ImageRequest,
        completion: Completion
    ) {
        guard !source.isEmpty,
              let resource = resourceFactory(
                source,
                Size(
                    width: Double(key.pixelWidth),
                    height: Double(key.pixelHeight)),
                resourceHostHandle)
        else {
            let failure: ImageRequestFailure = source.isEmpty
                ? .unresolved
                : .registrationFailed
            insertNegative(failure, for: key)
            diagnostic(failure, request)
            complete(
                request,
                outcome: .failure(failure),
                with: completion)
            return
        }
        insert(resource, for: key)
        complete(
            request,
            outcome: .success(resource),
            with: completion)
    }

    private func cacheKey(for request: ImageRequest) -> CacheKey {
        let scale = Double(request.backingScaleFactor.value)
        let isIcon: Bool
        switch request.source {
        case .resource:
            isIcon = false
        case .icon:
            isIcon = true
        }
        return CacheKey(
            source: request.source,
            pixelWidth: ImageResource.pixelBound(
                request.targetSize.width * scale),
            pixelHeight: ImageResource.pixelBound(
                request.targetSize.height * scale),
            appearance: isIcon && request.appearance == .dark ? 1 : 0,
            iconThemeGeneration:
                isIcon ? request.iconThemeGeneration : 0,
            resourceGeneration: resourceGeneration)
    }

    private func insert(_ resource: ImageResource, for key: CacheKey) {
        let cost = decodedCost(
            width: key.pixelWidth,
            height: key.pixelHeight)
        guard cost <= limits.maximumDecodedBytes else { return }
        while cache.count >= limits.maximumEntries
            || cachedCost > limits.maximumDecodedBytes - cost
        {
            guard evictLeastRecentlyUsed() else { break }
        }
        cache[key] = CacheEntry(
            resource: resource,
            cost: cost,
            access: takeAccess())
        cachedCost += cost
    }

    private func insertNegative(
        _ failure: ImageRequestFailure,
        for key: CacheKey
    ) {
        if negativeCache.count >= limits.maximumNegativeEntries,
           let oldest = negativeCache.min(by: {
               $0.value.access < $1.value.access
           })?.key
        {
            negativeCache[oldest] = nil
        }
        negativeCache[key] = NegativeEntry(
            failure: failure,
            expiration: clock.now.advanced(
                by: limits.negativeResultLifetime),
            access: takeAccess())
    }

    private func evictLeastRecentlyUsed() -> Bool {
        guard let oldest = cache.min(by: {
            $0.value.access < $1.value.access
        }) else { return false }
        cachedCost -= oldest.value.cost
        cache[oldest.key] = nil
        return true
    }

    private func decodedCost(width: UInt32, height: UInt32) -> Int {
        let pixels = UInt64(width) * UInt64(height)
        let bytes = pixels.multipliedReportingOverflow(by: 4)
        guard !bytes.overflow else { return Int.max }
        return Int(clamping: bytes.partialValue)
    }

    private func cancelInFlight(with failure: ImageRequestFailure) {
        let pending = inFlight
        inFlight.removeAll(keepingCapacity: true)
        keyBySubscription.removeAll(keepingCapacity: true)
        for request in pending.values {
            request.work.cancel()
            request.completionTask?.cancel()
            for subscriber in request.subscribers.values {
                complete(
                    subscriber.request,
                    outcome: .failure(failure),
                    with: subscriber.completion)
            }
        }
    }

    private func complete(
        _ request: ImageRequest,
        outcome: ImageRequestOutcome,
        with completion: Completion
    ) {
        completion(ImageRequestResult(
            requestID: request.id,
            cancellationGeneration: request.cancellationGeneration,
            outcome: outcome))
    }

    private func takeAccess() -> UInt64 {
        let access = nextAccess
        nextAccess &+= 1
        precondition(nextAccess != 0, "image cache access generation exhausted")
        return access
    }

    private func takeSubscriptionID() -> UInt64 {
        let value = nextSubscriptionID
        nextSubscriptionID &+= 1
        precondition(
            nextSubscriptionID != 0,
            "image request subscription identity exhausted")
        return value
    }
}
