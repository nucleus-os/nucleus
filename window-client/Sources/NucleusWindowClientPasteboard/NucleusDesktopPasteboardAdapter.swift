import Foundation
import Glibc
public import NucleusUI
public import NucleusWindowClientRuntime
@_spi(NucleusWindowClientImplementation) public import NucleusWindowClientWayland
public import WaylandClientDispatch

public struct NucleusDesktopTransferLimits: Sendable, Equatable {
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

struct NucleusDesktopPasteboardResourceCounts: Equatable {
    var offers: Int
    var sources: Int
    var devices: Int
    var transfers: Int
}

@MainActor
@safe public final class NucleusDesktopPasteboardAdapter: PasteboardAdapter {
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
    @safe private final class Offer: ExtDataControlOfferV1Events {
        let proxy: WaylandProxy<ExtDataControlOfferV1Client>
        private(set) var mimeTypes: Set<String> = []

        init(proxy: WaylandProxy<ExtDataControlOfferV1Client>) throws {
            self.proxy = proxy
            try proxy.installListener(self)
        }

        var preferredMIMEType: String? {
            NucleusDesktopPasteboardAdapter.preferredPlainTextMIMEType(
                in: mimeTypes)
        }

        func offer(
            _ proxy: WaylandBorrowedProxy<ExtDataControlOfferV1Client>,
            mime_type: String
        ) {
            mimeTypes.insert(mime_type)
        }
    }

    @MainActor
    @safe private final class Source: ExtDataControlSourceV1Events {
        let proxy: WaylandProxy<ExtDataControlSourceV1Client>
        let payload: [UInt8]
        weak var adapter: NucleusDesktopPasteboardAdapter?

        init(
            proxy: WaylandProxy<ExtDataControlSourceV1Client>,
            payload: [UInt8],
            adapter: NucleusDesktopPasteboardAdapter
        ) throws {
            self.proxy = proxy
            self.payload = payload
            self.adapter = adapter
            try proxy.installListener(self)
        }

        func send(
            _ proxy: WaylandBorrowedProxy<ExtDataControlSourceV1Client>,
            mime_type: String,
            fd: consuming WaylandClientOwnedFileDescriptor
        ) {
            let descriptor = fd.take()
            guard let adapter else {
                if descriptor >= 0 { _ = Glibc.close(descriptor) }
                return
            }
            adapter.source(
                self, send: mime_type, owning: descriptor)
        }

        func cancelled(
            _ proxy: WaylandBorrowedProxy<ExtDataControlSourceV1Client>
        ) {
            adapter?.sourceWasCancelled(self)
        }
    }

    private let client: NucleusDesktopConnection
    private let manager: WaylandProxy<ExtDataControlManagerV1Client>
    private var device: WaylandProxy<ExtDataControlDeviceV1Client>?
    private let limits: NucleusDesktopTransferLimits
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
        client: NucleusDesktopConnection,
        seat: NucleusDesktopSeat,
        limits: NucleusDesktopTransferLimits = NucleusDesktopTransferLimits(),
        pollSetDidChange: @escaping @MainActor () -> Void = {},
        diagnosticHandler: @escaping DiagnosticHandler = { _, _ in }
    ) {
        guard let manager = client.dataControl,
            let device = try? manager.getDataDevice(seat: seat.protocolSeat)
        else {
            return nil
        }
        self.client = client
        self.manager = manager
        self.device = device
        self.limits = limits
        self.pollSetDidChange = pollSetDidChange
        self.diagnosticHandler = diagnosticHandler
        do {
            try device.installListener(self)
        } catch {
            try? device.destroy()
            return nil
        }
    }

    public var pollDescriptors: [NucleusDesktopTransferPollDescriptor] {
        transferExecutor.pollDescriptors
    }

    public var activeTransferCount: Int {
        transferExecutor.activeTransferCount
    }

    var resourceCounts: NucleusDesktopPasteboardResourceCounts {
        let deviceCount: Int
        if device != nil {
            deviceCount = 1
        } else {
            deviceCount = 0
        }
        return NucleusDesktopPasteboardResourceCounts(
            offers: offers.count,
            sources: sources.count,
            devices: deviceCount,
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
        result: NucleusWindowClientPollResult,
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
        let proxy: WaylandProxy<ExtDataControlSourceV1Client>
        do {
            proxy = try manager.createDataSource()
        } catch {
            throw .transport("failed to create a Wayland data-control source")
        }

        let source: Source
        do {
            source = try Source(
                proxy: proxy,
                payload: payload,
                adapter: self)
        } catch {
            try? proxy.destroy()
            throw .transport("failed to listen to a Wayland data-control source")
        }
        let sourceKey = proxy.identity
        sources[sourceKey] = source
        for mime in mimeTypes {
            do {
                try proxy.offer(mime_type: mime)
            } catch {
                sources.removeValue(forKey: sourceKey)
                source.adapter = nil
                try? proxy.destroy()
                throw .transport("failed to advertise a Wayland selection type")
            }
        }
        do {
            try device.setSelection(source: proxy)
        } catch {
            sources.removeValue(forKey: sourceKey)
            source.adapter = nil
            try? proxy.destroy()
            throw .transport("failed to set the Wayland selection")
        }
        selectedSourceKey = sourceKey
        try flush(operation: "write-selection")
    }

    public func clear() async throws(PasteboardFailure) {
        guard !isShutdown, let device else { throw .unavailable }
        do {
            try device.setSelection(source: nil)
        } catch {
            throw .transport("failed to clear the Wayland selection")
        }
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
            try? offer.proxy.destroy()
        }
        offers.removeAll()
        for source in sources.values {
            source.adapter = nil
            try? source.proxy.destroy()
        }
        sources.removeAll()
        selectedSourceKey = nil
        if let device {
            try? device.destroy()
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
            continuation.resume(
                returning: .failure(
                    .transport("pasteboard adapter is unavailable")))
            return
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard unsafe pipe2(&descriptors, O_CLOEXEC | O_NONBLOCK) == 0 else {
            continuation.resume(
                returning: .failure(
                    .transport(
                        "failed to create selection pipe: "
                            + (unsafe String(cString: strerror(errno))))))
            return
        }
        let readDescriptor = TransferFileDescriptor(owning: descriptors[0])
        let writeDescriptor = TransferFileDescriptor(owning: descriptors[1])
        do {
            try offer.proxy.receive(
                mime_type: mime,
                fd: WaylandClientOwnedFileDescriptor(writeDescriptor.release()))
        } catch {
            continuation.resume(
                returning: .failure(
                    .transport("failed to request the Wayland selection payload")))
            return
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
                    + (unsafe String(cString: strerror(errno))))
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
        let sourceKey = source.proxy.identity
        if selectedSourceKey == sourceKey {
            selectedSourceKey = nil
        }
        guard sources.removeValue(forKey: sourceKey) != nil else { return }
        source.adapter = nil
        try? source.proxy.destroy()
    }

    private func flush(
        operation: String
    ) throws(PasteboardFailure) {
        let result = client.flush()
        guard result < 0, errno != EAGAIN else { return }
        throw .transport(
            "\(operation) flush failed: "
                + (unsafe String(cString: strerror(errno))))
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
        NucleusWindowClientMonotonicClock.nowNanoseconds()
    }
}

extension NucleusDesktopPasteboardAdapter: ExtDataControlDeviceV1Events {
    public func dataOffer(
        _ proxy: WaylandBorrowedProxy<ExtDataControlDeviceV1Client>,
        id: WaylandProxy<ExtDataControlOfferV1Client>
    ) {
        do {
            offers[id.identity] = try Offer(proxy: id)
        } catch {
            try? id.destroy()
        }
    }

    public func selection(
        _ proxy: WaylandBorrowedProxy<ExtDataControlDeviceV1Client>,
        id: WaylandBorrowedProxy<ExtDataControlOfferV1Client>?
    ) {
        let rawID: UInt?
        if let id {
            rawID = id.identity
        } else {
            rawID = nil
        }
        let replacement = rawID.flatMap { offers[$0] }
        let oldOffer = activeOffer
        activeOffer = replacement
        if let oldOffer, oldOffer !== replacement {
            offers.removeValue(forKey: oldOffer.proxy.identity)
            try? oldOffer.proxy.destroy()
        }
        if rawID == nil {
            activeOffer = nil
        }
    }

    public func finished(
        _ proxy: WaylandBorrowedProxy<ExtDataControlDeviceV1Client>
    ) {
        shutdown()
        diagnosticHandler(
            "data-control-device",
            .transport("compositor finished the data-control device"))
    }

    public func primarySelection(
        _ proxy: WaylandBorrowedProxy<ExtDataControlDeviceV1Client>,
        id: WaylandBorrowedProxy<ExtDataControlOfferV1Client>?
    ) {
        let rawID: UInt?
        if let id {
            rawID = id.identity
        } else {
            rawID = nil
        }
        guard let rawID,
            let offer = offers.removeValue(forKey: rawID)
        else { return }
        try? offer.proxy.destroy()
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
