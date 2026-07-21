import Glibc
import NucleusShellLoop
import NucleusShellWayland
import NucleusUI
import WaylandClientC
import WaylandClientDispatch
import WaylandProtocolsC

public struct ShellDataTransferLimits: Sendable, Equatable {
    public var maximumBytes: Int
    public var transferTimeoutNanoseconds: UInt64

    public init(
        maximumBytes: Int = 8 * 1024 * 1024,
        transferTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        precondition(maximumBytes >= 0)
        precondition(transferTimeoutNanoseconds > 0)
        self.maximumBytes = maximumBytes
        self.transferTimeoutNanoseconds = transferTimeoutNanoseconds
    }
}

struct ShellPasteboardResourceCounts: Equatable {
    var offers: Int
    var sources: Int
    var devices: Int
    var transfers: Int
}

@MainActor
public final class ShellWaylandPasteboardAdapter: PasteboardAdapter {
    public typealias DiagnosticHandler =
        @MainActor @Sendable (_ operation: String, _ failure: PasteboardFailure) -> Void

    /// The protocol treats MIME strings as opaque. This exact order makes
    /// negotiation stable across source offer order and compositor versions.
    public nonisolated static let preferredPlainTextMIMETypes = [
        "text/plain;charset=utf-8",
        "text/plain;charset=UTF-8",
        "UTF8_STRING",
        "text/plain",
    ]

    public nonisolated static func preferredPlainTextMIMEType<S: Sequence>(
        in mimeTypes: S
    ) -> String? where S.Element == String {
        let available = Set(mimeTypes)
        return preferredPlainTextMIMETypes.first { available.contains($0) }
    }

    @MainActor
    private final class Offer: ExtDataControlOfferV1Events {
        let proxy: OpaquePointer
        private(set) var mimeTypes: Set<String> = []

        init(proxy: OpaquePointer) {
            self.proxy = proxy
            ExtDataControlOfferV1Client.addListener(proxy, owner: self)
        }

        var preferredMIMEType: String? {
            ShellWaylandPasteboardAdapter.preferredPlainTextMIMEType(
                in: mimeTypes)
        }

        nonisolated func offer(
            _ proxy: OpaquePointer,
            mime_type: UnsafePointer<CChar>?
        ) {
            guard let mime_type else { return }
            let value = String(cString: mime_type)
            _ = MainActor.assumeIsolated {
                mimeTypes.insert(value)
            }
        }
    }

    @MainActor
    private final class Source: ExtDataControlSourceV1Events {
        let proxy: OpaquePointer
        let payload: [UInt8]
        weak var adapter: ShellWaylandPasteboardAdapter?

        init(
            proxy: OpaquePointer,
            payload: [UInt8],
            adapter: ShellWaylandPasteboardAdapter
        ) {
            self.proxy = proxy
            self.payload = payload
            self.adapter = adapter
            ExtDataControlSourceV1Client.addListener(proxy, owner: self)
        }

        nonisolated func send(
            _ proxy: OpaquePointer,
            mime_type: UnsafePointer<CChar>?,
            fd: Int32
        ) {
            let mime = mime_type.map(String.init(cString:))
            MainActor.assumeIsolated {
                guard let adapter else {
                    if fd >= 0 { _ = Glibc.close(fd) }
                    return
                }
                adapter.source(self, send: mime, owning: fd)
            }
        }

        nonisolated func cancelled(_ proxy: OpaquePointer) {
            MainActor.assumeIsolated {
                adapter?.sourceWasCancelled(self)
            }
        }
    }

    private let client: ShellWaylandClient
    private let manager: OpaquePointer
    private var device: OpaquePointer?
    private let limits: ShellDataTransferLimits
    private let diagnosticHandler: DiagnosticHandler
    private let pollSetDidChange: @MainActor () -> Void
    private lazy var transferExecutor = DataTransferExecutor(
        pollSetDidChange: pollSetDidChange
    ) {
        [weak self] operation, failure in
        self?.diagnosticHandler(
            operation,
            Self.pasteboardFailure(from: failure))
    }

    private var offers: [UInt: Offer] = [:]
    private var activeOffer: Offer?
    private var sources: [UInt: Source] = [:]
    private var selectedSourceKey: UInt?
    private var readRequestTokens: [UInt64: UInt64] = [:]
    private var readRequestSequence: UInt64 = 1
    private var isShutdown = false

    public init?(
        client: ShellWaylandClient,
        seat: ShellSeat,
        limits: ShellDataTransferLimits = ShellDataTransferLimits(),
        pollSetDidChange: @escaping @MainActor () -> Void = {},
        diagnosticHandler: @escaping DiagnosticHandler = { _, _ in }
    ) {
        guard let manager = client.proxy(.dataControl),
              let device = ext_data_control_manager_v1_get_data_device(
                manager,
                seat.protocolSeat)
        else {
            return nil
        }
        self.client = client
        self.manager = manager
        self.device = device
        self.limits = limits
        self.pollSetDidChange = pollSetDidChange
        self.diagnosticHandler = diagnosticHandler
        ExtDataControlDeviceV1Client.addListener(device, owner: self)
    }

    public var pollDescriptors: [ShellDataTransferPollDescriptor] {
        transferExecutor.pollDescriptors
    }

    public var activeTransferCount: Int {
        transferExecutor.activeTransferCount
    }

    var resourceCounts: ShellPasteboardResourceCounts {
        ShellPasteboardResourceCounts(
            offers: offers.count,
            sources: sources.count,
            devices: device == nil ? 0 : 1,
            transfers: transferExecutor.activeTransferCount)
    }

    public func nanosecondsUntilTransferDeadline(
        nowNanoseconds: UInt64
    ) -> UInt64? {
        transferExecutor.nanosecondsUntilDeadline(
            nowNanoseconds: nowNanoseconds)
    }

    public func processPollResult(
        token: UInt64,
        result: ShellPollResult,
        nowNanoseconds: UInt64
    ) {
        transferExecutor.processPollResult(
            token: token,
            result: result,
            nowNanoseconds: nowNanoseconds)
    }

    public func expireTransfers(nowNanoseconds: UInt64) {
        transferExecutor.expireTransfers(nowNanoseconds: nowNanoseconds)
    }

    public func readString() async throws(PasteboardFailure) -> String? {
        guard !isShutdown, let activeOffer else {
            if isShutdown { throw .unavailable }
            return nil
        }
        guard let mime = activeOffer.preferredMIMEType else {
            return nil
        }

        let requestID = nextReadRequestID()
        let result: Result<[UInt8], DataTransferFailure> =
            await withTaskCancellationHandler {
                if Task.isCancelled {
                    return .failure(.cancelled)
                }
                return await withCheckedContinuation { continuation in
                    startRead(
                        requestID: requestID,
                        offer: activeOffer,
                        mime: mime,
                        continuation: continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelRead(requestID: requestID)
                }
            }
        let bytes: [UInt8]
        do {
            bytes = try result.get()
        } catch let failure {
            throw Self.pasteboardFailure(from: failure)
        }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw .transport("selection payload was not valid UTF-8")
        }
        return string
    }

    public func writeString(
        _ string: String
    ) async throws(PasteboardFailure) {
        let payload = Array(string.utf8)
        guard payload.count <= limits.maximumBytes else {
            throw .transport(
                "selection exceeded \(limits.maximumBytes) byte limit")
        }
        try publish(
            payload: payload,
            mimeTypes: Self.preferredPlainTextMIMETypes)
    }

    func publish(payload: [UInt8], mimeTypes: [String])
        throws(PasteboardFailure)
    {
        guard !isShutdown, let device else { throw .unavailable }
        guard let proxy = ext_data_control_manager_v1_create_data_source(manager)
        else {
            throw .transport("failed to create a Wayland data-control source")
        }

        let source = Source(
            proxy: proxy,
            payload: payload,
            adapter: self)
        let sourceKey = key(proxy)
        sources[sourceKey] = source
        for mime in mimeTypes {
            mime.withCString {
                ext_data_control_source_v1_offer(proxy, $0)
            }
        }
        ext_data_control_device_v1_set_selection(device, proxy)
        selectedSourceKey = sourceKey
        try flush(operation: "write-selection")
    }

    public func clear() async throws(PasteboardFailure) {
        guard !isShutdown, let device else { throw .unavailable }
        ext_data_control_device_v1_set_selection(device, nil)
        selectedSourceKey = nil
        try flush(operation: "clear-selection")
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        transferExecutor.shutdown()
        readRequestTokens.removeAll()
        activeOffer = nil
        for offer in offers.values {
            ext_data_control_offer_v1_destroy(offer.proxy)
        }
        offers.removeAll()
        for source in sources.values {
            source.adapter = nil
            ext_data_control_source_v1_destroy(source.proxy)
        }
        sources.removeAll()
        selectedSourceKey = nil
        if let device {
            ext_data_control_device_v1_destroy(device)
            self.device = nil
        }
    }

    isolated deinit {
        shutdown()
    }

    private func startRead(
        requestID: UInt64,
        offer: Offer,
        mime: String,
        continuation:
            CheckedContinuation<Result<[UInt8], DataTransferFailure>, Never>
    ) {
        guard !isShutdown else {
            continuation.resume(returning: .failure(
                .transport("pasteboard adapter is unavailable")))
            return
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe2(&descriptors, O_CLOEXEC | O_NONBLOCK) == 0 else {
            continuation.resume(returning: .failure(.transport(
                "failed to create selection pipe: "
                    + String(cString: strerror(errno)))))
            return
        }
        let readDescriptor = TransferFileDescriptor(owning: descriptors[0])
        let writeDescriptor = TransferFileDescriptor(owning: descriptors[1])
        mime.withCString {
            ext_data_control_offer_v1_receive(
                offer.proxy,
                $0,
                writeDescriptor.rawValue)
        }
        let deadline = monotonicNowNanoseconds().saturatingAdd(
            limits.transferTimeoutNanoseconds)
        let token = transferExecutor.installRead(
            owning: readDescriptor,
            operation: "read-selection",
            byteLimit: limits.maximumBytes,
            deadlineNanoseconds: deadline
        ) { [weak self] result in
            self?.readRequestTokens.removeValue(forKey: requestID)
            continuation.resume(returning: result)
        }
        readRequestTokens[requestID] = token
        do {
            try flush(operation: "read-selection")
        } catch let failure {
            transferExecutor.failRead(
                token: token,
                failure: .transport(String(describing: failure)))
        }
    }

    private func nextReadRequestID() -> UInt64 {
        let result = readRequestSequence
        readRequestSequence &+= 1
        precondition(readRequestSequence != 0, "pasteboard read id exhausted")
        return result
    }

    private func cancelRead(requestID: UInt64) {
        guard let token = readRequestTokens.removeValue(forKey: requestID)
        else { return }
        transferExecutor.cancelRead(token: token)
    }

    private func source(
        _ source: Source,
        send mime: String?,
        owning fileDescriptor: Int32
    ) {
        guard fileDescriptor >= 0 else {
            diagnosticHandler(
                "serve-selection",
                .transport("compositor supplied an invalid transfer descriptor"))
            return
        }
        let statusFlags = fcntl(fileDescriptor, F_GETFL)
        let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
        guard statusFlags >= 0,
              descriptorFlags >= 0,
              fcntl(fileDescriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0,
              fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else {
            let failure = PasteboardFailure.transport(
                "failed to configure selection descriptor: "
                    + String(cString: strerror(errno)))
            _ = Glibc.close(fileDescriptor)
            diagnosticHandler("serve-selection", failure)
            return
        }
        let descriptor = TransferFileDescriptor(owning: fileDescriptor)
        guard !isShutdown,
              let mime,
              Self.preferredPlainTextMIMETypes.contains(mime)
        else {
            return
        }
        _ = transferExecutor.installWrite(
            owning: descriptor,
            operation: "serve-selection",
            payload: source.payload,
            deadlineNanoseconds: monotonicNowNanoseconds().saturatingAdd(
                limits.transferTimeoutNanoseconds))
    }

    private func sourceWasCancelled(_ source: Source) {
        let sourceKey = key(source.proxy)
        if selectedSourceKey == sourceKey {
            selectedSourceKey = nil
        }
        guard sources.removeValue(forKey: sourceKey) != nil else { return }
        source.adapter = nil
        ext_data_control_source_v1_destroy(source.proxy)
    }

    private func flush(
        operation: String
    ) throws(PasteboardFailure) {
        let result = client.flush()
        guard result < 0, errno != EAGAIN else { return }
        throw .transport(
            "\(operation) flush failed: " + String(cString: strerror(errno)))
    }

    private func key(_ proxy: OpaquePointer) -> UInt {
        UInt(bitPattern: proxy)
    }

    private nonisolated static func pasteboardFailure(
        from failure: DataTransferFailure
    ) -> PasteboardFailure {
        switch failure {
        case .cancelled:
            .cancelled
        case .transport(let message):
            .transport(message)
        }
    }

    private func monotonicNowNanoseconds() -> UInt64 {
        var time = timespec()
        _ = clock_gettime(CLOCK_MONOTONIC, &time)
        let seconds = UInt64(max(0, time.tv_sec))
        let nanoseconds = UInt64(max(0, time.tv_nsec))
        return seconds.saturatingMultiply(1_000_000_000)
            .saturatingAdd(nanoseconds)
    }
}

extension ShellWaylandPasteboardAdapter: ExtDataControlDeviceV1Events {
    public nonisolated func dataOffer(
        _ proxy: OpaquePointer,
        id: OpaquePointer?
    ) {
        guard let id else { return }
        let rawID = UInt(bitPattern: id)
        MainActor.assumeIsolated {
            guard let id = OpaquePointer(bitPattern: rawID) else { return }
            offers[rawID] = Offer(proxy: id)
        }
    }

    public nonisolated func selection(
        _ proxy: OpaquePointer,
        id: OpaquePointer?
    ) {
        let rawID = id.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated {
            let replacement = rawID.flatMap { offers[$0] }
            let oldOffer = activeOffer
            activeOffer = replacement
            if let oldOffer, oldOffer !== replacement {
                offers.removeValue(forKey: key(oldOffer.proxy))
                ext_data_control_offer_v1_destroy(oldOffer.proxy)
            }
            if rawID == nil {
                activeOffer = nil
            }
        }
    }

    public nonisolated func finished(_ proxy: OpaquePointer) {
        MainActor.assumeIsolated {
            shutdown()
            diagnosticHandler(
                "data-control-device",
                .transport("compositor finished the data-control device"))
        }
    }

    public nonisolated func primarySelection(
        _ proxy: OpaquePointer,
        id: OpaquePointer?
    ) {
        let rawID = id.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated {
            guard let rawID,
                  let offer = offers.removeValue(forKey: rawID)
            else { return }
            ext_data_control_offer_v1_destroy(offer.proxy)
        }
    }
}

extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    func saturatingMultiply(_ other: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: other)
        return result.overflow ? .max : result.partialValue
    }
}
