import ColliderCore
import ColliderPlatformC
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct DownloadProgress: Sendable {
    public let digest: ArtifactDigest
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(
        digest: ArtifactDigest,
        receivedBytes: Int64,
        expectedBytes: Int64?
    ) {
        self.digest = digest
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }
}

public actor ColliderDownloads {
    private let cacheRoot: FilePath
    private let delegate: DownloadDelegate
    private let session: URLSession

    public init(
        cacheRoot: FilePath? = nil,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) {
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot()
        let delegate = DownloadDelegate(progress: progress)
        self.delegate = delegate
        session = URLSession(
            configuration: Self.configuration(),
            delegate: delegate,
            delegateQueue: nil)
    }

    package init(
        cacheRoot: FilePath,
        configuration: URLSessionConfiguration,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) {
        self.cacheRoot = cacheRoot
        let delegate = DownloadDelegate(progress: progress)
        self.delegate = delegate
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil)
    }

    public func shutdown() async {
        await delegate.invalidate(session)
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    public func download(
        _ specification: DownloadSpec,
        to candidate: FilePath
    ) async throws {
        if FileManager.default.fileExists(atPath: candidate.string) {
            if try digest(file: candidate) == specification.expectedDigest {
                return
            }
            try FileManager.default.removeItem(atPath: candidate.string)
        }
        let state = statePaths(for: specification.expectedDigest)
        try FileManager.default.createDirectory(
            atPath: state.directory.string,
            withIntermediateDirectories: true)
        let lock = try DownloadLock(path: state.directory.appending("lock"))
        defer { withExtendedLifetime(lock) {} }
        var lastError: (any Error)?
        for attempt in 0...specification.maximumRetries {
            do {
                defer {
                    try? FileManager.default.removeItem(
                        atPath: state.transfer.string)
                }
                let partial = try loadPartial(specification, paths: state)
                let result = try await transfer(
                    specification,
                    partial: partial,
                    paths: state)
                try consume(
                    result,
                    specification: specification,
                    priorPartial: partial,
                    paths: state,
                    candidate: candidate)
                return
            } catch {
                lastError = error
                guard attempt < specification.maximumRetries, isTransient(error) else {
                    if isTerminal(error) { discardPartial(state) }
                    try? FileManager.default.removeItem(atPath: candidate.string)
                    throw error
                }
            }
        }
        throw lastError ?? DownloadFailure.missingResponse
    }

    private func transfer(
        _ specification: DownloadSpec,
        partial: PartialMetadata?,
        paths: DownloadStatePaths
    ) async throws -> TransferResult {
        try? FileManager.default.removeItem(atPath: paths.transfer.string)
        var request = URLRequest(url: specification.url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = TimeInterval(specification.inactivityTimeoutSeconds)
        if let partial {
            request.setValue("bytes=\(partial.receivedBytes)-", forHTTPHeaderField: "Range")
            request.setValue(partial.validator, forHTTPHeaderField: "If-Range")
        }
        let task = session.dataTask(with: request)
        return try await withThrowingTaskGroup(
            of: TransferResult.self,
            returning: TransferResult.self
        ) { group in
            group.addTask {
                try await self.delegate.run(
                    task: task,
                    specification: specification,
                    transfer: paths.transfer)
            }
            group.addTask {
                try await ContinuousClock().sleep(
                    for: .seconds(specification.requestTimeoutSeconds))
                task.cancel()
                throw DownloadFailure.requestTimedOut
            }
            guard let first = try await group.next() else {
                throw DownloadFailure.missingResponse
            }
            group.cancelAll()
            return first
        }
    }

    private func consume(
        _ result: TransferResult,
        specification: DownloadSpec,
        priorPartial: PartialMetadata?,
        paths: DownloadStatePaths,
        candidate: FilePath
    ) throws {
        defer { try? FileManager.default.removeItem(atPath: paths.transfer.string) }
        guard result.status == 200 || result.status == 206 else {
            throw DownloadFailure.httpStatus(result.status)
        }
        try validateCommon(result, specification: specification)
        if result.transportInterrupted {
            try preserveInterruptedTransfer(
                result,
                specification: specification,
                priorPartial: priorPartial,
                paths: paths)
        }
        try validateContentLength(result)
        switch result.status {
        case 200:
            if priorPartial != nil { discardPartial(paths) }
            try complete(
                source: paths.transfer,
                result: result,
                specification: specification,
                paths: paths,
                candidate: candidate)
        case 206:
            guard let priorPartial else {
                throw DownloadFailure.unexpectedPartialResponse
            }
            let updated = try appendPartial(
                result,
                prior: priorPartial,
                specification: specification,
                paths: paths)
            if updated.receivedBytes == updated.totalSize {
                try complete(
                    source: paths.partial,
                    result: result,
                    specification: specification,
                    paths: paths,
                    candidate: candidate)
            } else {
                throw DownloadFailure.incompleteTransfer(
                    received: updated.receivedBytes,
                    expected: updated.totalSize)
            }
        default:
            throw DownloadFailure.httpStatus(result.status)
        }
    }

    private func validateCommon(
        _ result: TransferResult,
        specification: DownloadSpec
    ) throws {
        guard result.finalURL.scheme?.lowercased() == "https",
              result.finalURL.user == nil,
              result.finalURL.password == nil
        else { throw DownloadFailure.redirectRejected }
        if result.finalURL != specification.url,
           let finalOrigin = origin(of: result.finalURL),
           !specification.permittedRedirectOrigins.contains(finalOrigin)
        {
            throw DownloadFailure.redirectRejected
        }
        if let encoding = result.contentEncoding,
           encoding.lowercased() != "identity" {
            throw DownloadFailure.contentEncoding(encoding)
        }
        guard let mediaType = result.mediaType?.lowercased(),
              specification.acceptedMediaTypes.contains(where: {
                  $0.lowercased() == mediaType
              })
        else { throw DownloadFailure.mediaType(result.mediaType ?? "<missing>") }
        let size = try fileSize(result.file)
        guard size <= specification.maximumResponseSize else {
            throw DownloadFailure.sizeExceeded
        }
    }

    private func validateContentLength(_ result: TransferResult) throws {
        let size = try fileSize(result.file)
        guard let contentLength = result.contentLength else {
            throw DownloadFailure.missingContentLength
        }
        guard contentLength == size else {
            throw DownloadFailure.contentLengthMismatch(
                declared: contentLength,
                received: size)
        }
    }

    private func preserveInterruptedTransfer(
        _ result: TransferResult,
        specification: DownloadSpec,
        priorPartial: PartialMetadata?,
        paths: DownloadStatePaths
    ) throws {
        let received = try fileSize(result.file)
        guard specification.resumption == .validatorRequired,
              result.status == 200,
              priorPartial == nil,
              received > 0,
              let total = result.contentLength,
              received < total,
              total <= specification.maximumResponseSize,
              result.etag != nil || result.lastModified != nil
        else {
            throw DownloadFailure.interruptedTransfer
        }
        try? FileManager.default.removeItem(atPath: paths.partial.string)
        try copyFile(result.file, to: paths.partial)
        try writeJSON(
            PartialMetadata(
                originalURL: specification.url,
                finalURL: result.finalURL,
                etag: result.etag,
                lastModified: result.lastModified,
                receivedBytes: received,
                totalSize: total),
            to: paths.metadata)
        throw DownloadFailure.incompleteTransfer(
            received: received,
            expected: total)
    }

    private func appendPartial(
        _ result: TransferResult,
        prior: PartialMetadata,
        specification: DownloadSpec,
        paths: DownloadStatePaths
    ) throws -> PartialMetadata {
        let segmentSize = try fileSize(result.file)
        guard let range = parseContentRange(result.contentRange),
              range.start == prior.receivedBytes,
              range.end >= range.start,
              range.total == prior.totalSize,
              range.total <= specification.maximumResponseSize,
              range.end - range.start + 1 == segmentSize,
              matchingValidator(result, prior: prior)
        else { throw DownloadFailure.invalidRangeResponse }
        try appendFile(result.file, to: paths.partial)
        let received = try fileSize(paths.partial)
        guard received == range.end + 1, received <= range.total else {
            throw DownloadFailure.invalidRangeResponse
        }
        let updated = PartialMetadata(
            originalURL: prior.originalURL,
            finalURL: result.finalURL,
            etag: prior.etag,
            lastModified: prior.lastModified,
            receivedBytes: received,
            totalSize: range.total)
        try writeJSON(updated, to: paths.metadata)
        return updated
    }

    private func complete(
        source: FilePath,
        result: TransferResult,
        specification: DownloadSpec,
        paths: DownloadStatePaths,
        candidate: FilePath
    ) throws {
        let size = try fileSize(source)
        guard size <= specification.maximumResponseSize else {
            throw DownloadFailure.sizeExceeded
        }
        try FileManager.default.createDirectory(
            atPath: candidate.removingLastComponent().string,
            withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: candidate.string)
        try copyFile(source, to: candidate)
        let actual = try digest(file: candidate)
        guard actual == specification.expectedDigest else {
            try? FileManager.default.removeItem(atPath: candidate.string)
            throw DownloadFailure.digestMismatch(
                expected: specification.expectedDigest,
                actual: actual)
        }
        try writeJSON(
            DownloadManifest(
                originalURL: CredentialScrubber.url(specification.url),
                finalURL: CredentialScrubber.url(result.finalURL),
                redirects: result.redirects.map(CredentialScrubber.url),
                etag: result.etag,
                lastModified: result.lastModified,
                responseSize: size,
                digest: actual,
                status: "verified"),
            to: paths.manifest)
        try? FileManager.default.removeItem(atPath: paths.partial.string)
        try? FileManager.default.removeItem(atPath: paths.metadata.string)
    }

    private func loadPartial(
        _ specification: DownloadSpec,
        paths: DownloadStatePaths
    ) throws -> PartialMetadata? {
        guard specification.resumption == .validatorRequired,
              let data = try? Data(contentsOf: URL(fileURLWithPath: paths.metadata.string)),
              let metadata = try? JSONDecoder().decode(PartialMetadata.self, from: data),
              metadata.originalURL == specification.url,
              metadata.receivedBytes > 0,
              metadata.receivedBytes < metadata.totalSize,
              metadata.totalSize <= specification.maximumResponseSize,
              metadata.validator.isEmpty == false,
              (try? fileSize(paths.partial)) == metadata.receivedBytes,
              permittedFinalURL(metadata.finalURL, specification: specification)
        else {
            discardPartial(paths)
            return nil
        }
        return metadata
    }

    private func permittedFinalURL(
        _ url: URL,
        specification: DownloadSpec
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil
        else { return false }
        if url == specification.url { return true }
        guard let value = origin(of: url) else { return false }
        return specification.permittedRedirectOrigins.contains(value)
    }

    private func matchingValidator(
        _ result: TransferResult,
        prior: PartialMetadata
    ) -> Bool {
        if let etag = prior.etag { return result.etag == etag }
        if let lastModified = prior.lastModified {
            return result.lastModified == lastModified
        }
        return false
    }

    private func isTransient(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            return [
                .timedOut, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet,
            ].contains(error.code)
        }
        switch error {
        case DownloadFailure.requestTimedOut,
             DownloadFailure.interruptedTransfer,
             DownloadFailure.incompleteTransfer:
            return true
        case DownloadFailure.httpStatus(let status):
            return status == 408 || status == 429 || (500...599).contains(status)
        default:
            return false
        }
    }

    private func isTerminal(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return !isTransient(error)
    }

    private func discardPartial(_ paths: DownloadStatePaths) {
        try? FileManager.default.removeItem(atPath: paths.partial.string)
        try? FileManager.default.removeItem(atPath: paths.metadata.string)
    }

    private func statePaths(for digest: ArtifactDigest) -> DownloadStatePaths {
        let hex = digest.bytes.map { String(format: "%02x", $0) }.joined()
        let directory = cacheRoot.appending("sha256").appending(hex)
        return DownloadStatePaths(
            directory: directory,
            partial: directory.appending("partial"),
            metadata: directory.appending("partial.json"),
            manifest: directory.appending("manifest.json"),
            transfer: directory.appending("transfer-\(UUID().uuidString)"))
    }

    private static func defaultCacheRoot() -> FilePath {
        let environment = ProcessInfo.processInfo.environment
        if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            return FilePath(xdg).appending("nucleus").appending("downloads")
        }
        let home = environment["HOME"] ?? "/tmp"
        return FilePath(home).appending(".cache").appending("nucleus")
            .appending("downloads")
    }
}

private final class DownloadLock {
    private let descriptor: FileDescriptor

    init(path: FilePath) throws {
        descriptor = try FileDescriptor.open(
            path,
            .readWrite,
            options: [.create],
            permissions: .ownerReadWrite)
        guard collider_lock_exclusive(descriptor.rawValue, 1) == 0 else {
            let failure = Errno(rawValue: errno)
            try? descriptor.close()
            throw failure
        }
    }

    deinit {
        _ = collider_unlock(descriptor.rawValue)
        try? descriptor.close()
    }
}

private struct DownloadStatePaths: Sendable {
    let directory: FilePath
    let partial: FilePath
    let metadata: FilePath
    let manifest: FilePath
    let transfer: FilePath
}

private struct PartialMetadata: Codable, Sendable {
    static let schemaVersion = 1
    let schema: Int
    let originalURL: URL
    let finalURL: URL
    let etag: String?
    let lastModified: String?
    let receivedBytes: Int64
    let totalSize: Int64

    init(
        originalURL: URL,
        finalURL: URL,
        etag: String?,
        lastModified: String?,
        receivedBytes: Int64,
        totalSize: Int64
    ) {
        schema = Self.schemaVersion
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.etag = etag
        self.lastModified = lastModified
        self.receivedBytes = receivedBytes
        self.totalSize = totalSize
    }

    var validator: String { etag ?? lastModified ?? "" }
}

private struct DownloadManifest: Codable, Sendable {
    static let schemaVersion = 1
    let schema: Int
    let originalURL: URL
    let finalURL: URL
    let redirects: [URL]
    let etag: String?
    let lastModified: String?
    let responseSize: Int64
    let digest: ArtifactDigest
    let status: String

    init(
        originalURL: URL,
        finalURL: URL,
        redirects: [URL],
        etag: String?,
        lastModified: String?,
        responseSize: Int64,
        digest: ArtifactDigest,
        status: String
    ) {
        schema = Self.schemaVersion
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.redirects = redirects
        self.etag = etag
        self.lastModified = lastModified
        self.responseSize = responseSize
        self.digest = digest
        self.status = status
    }
}

private struct TransferResult: Sendable {
    let status: Int
    let file: FilePath
    let finalURL: URL
    let mediaType: String?
    let contentEncoding: String?
    let contentLength: Int64?
    let contentRange: String?
    let etag: String?
    let lastModified: String?
    let redirects: [URL]
    let transportInterrupted: Bool
}

private final class DownloadState: @unchecked Sendable {
    let specification: DownloadSpec
    let transfer: FilePath
    var continuation: CheckedContinuation<TransferResult, any Error>?
    var response: HTTPURLResponse?
    var redirects: [URL] = []
    var policyError: (any Error)?
    var descriptor: FileDescriptor?
    var receivedBytes: Int64 = 0
    var transferComplete = false

    init(specification: DownloadSpec, transfer: FilePath) {
        self.specification = specification
        self.transfer = transfer
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct Invalidation {
        var started = false
        var completed = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let states = Mutex<[Int: DownloadState]>([:])
    private let invalidation = Mutex(Invalidation())
    private let progress: @Sendable (DownloadProgress) -> Void

    init(progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.progress = progress
    }

    func invalidate(_ session: URLSession) async {
        await withCheckedContinuation { continuation in
            let shouldStart = invalidation.withLock { state -> Bool in
                if state.completed {
                    continuation.resume()
                    return false
                }
                state.waiters.append(continuation)
                guard !state.started else { return false }
                state.started = true
                return true
            }
            if shouldStart {
                session.finishTasksAndInvalidate()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: (any Error)?
    ) {
        let waiters = invalidation.withLock { state -> [
            CheckedContinuation<Void, Never>
        ] in
            state.completed = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        _ = session
        _ = error
    }

    func run(
        task: URLSessionDataTask,
        specification: DownloadSpec,
        transfer: FilePath
    ) async throws -> TransferResult {
        let state = DownloadState(specification: specification, transfer: transfer)
        try? FileManager.default.removeItem(atPath: transfer.string)
        state.descriptor = try FileDescriptor.open(
            transfer,
            .writeOnly,
            options: [.create, .truncate],
            permissions: .ownerReadWrite)
        states.withLock { $0[task.taskIdentifier] = state }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                states.withLock { _ in state.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = states.withLock { states -> Bool in
            guard let state = states[task.taskIdentifier], let url = request.url else {
                return false
            }
            state.redirects.append(url)
            guard DownloadRedirectPolicy.permits(
                url,
                redirectCount: state.redirects.count,
                specification: state.specification)
            else {
                state.policyError = DownloadFailure.redirectRejected
                return false
            }
            return true
        }
        var redirected = allowed ? request : nil
        if origin(of: redirected?.url) != origin(of: task.currentRequest?.url) {
            redirected?.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected?.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(redirected)
        _ = session
        _ = response
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        let disposition = states.withLock { states -> URLSession.ResponseDisposition in
            guard let state = states[dataTask.taskIdentifier],
                  let response = response as? HTTPURLResponse
            else { return .cancel }
            state.response = response
            if response.expectedContentLength
                > state.specification.maximumResponseSize
            {
                state.policyError = DownloadFailure.sizeExceeded
                return .cancel
            }
            return .allow
        }
        completionHandler(disposition)
        _ = session
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let update = states.withLock { states -> DownloadProgress? in
            guard let state = states[dataTask.taskIdentifier],
                  state.policyError == nil,
                  let descriptor = state.descriptor
            else { return nil }
            state.receivedBytes += Int64(data.count)
            guard state.receivedBytes <= state.specification.maximumResponseSize else {
                state.policyError = DownloadFailure.sizeExceeded
                dataTask.cancel()
                return nil
            }
            do {
                _ = try data.withUnsafeBytes {
                    try descriptor.writeAll($0)
                }
            } catch {
                state.policyError = error
                dataTask.cancel()
                return nil
            }
            let expected = state.response?.expectedContentLength ?? -1
            return DownloadProgress(
                digest: state.specification.expectedDigest,
                receivedBytes: state.receivedBytes,
                expectedBytes: expected >= 0 ? expected : nil)
        }
        if let update { progress(update) }
        _ = session
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let completion = states.withLock { states -> (
            CheckedContinuation<TransferResult, any Error>,
            Result<TransferResult, any Error>
        )? in
            guard let state = states.removeValue(forKey: task.taskIdentifier),
                  let continuation = state.continuation
            else { return nil }
            if let descriptor = state.descriptor {
                if state.policyError == nil,
                   collider_sync_file(descriptor.rawValue) != 0
                {
                    state.policyError = Errno(rawValue: errno)
                }
                do {
                    try descriptor.close()
                    state.transferComplete = state.policyError == nil
                } catch where state.policyError == nil {
                    state.policyError = error
                } catch {}
                state.descriptor = nil
            }
            if let policyError = state.policyError {
                return (continuation, .failure(policyError))
            }
            guard state.transferComplete,
                  let response = state.response,
                  let finalURL = response.url
            else {
                if let error { return (continuation, .failure(error)) }
                return (continuation, .failure(DownloadFailure.missingResponse))
            }
            let interrupted = if let error = error as? URLError {
                error.code == .networkConnectionLost
            } else {
                false
            }
            if let error, !interrupted {
                return (continuation, .failure(error))
            }
            return (continuation, .success(TransferResult(
                status: response.statusCode,
                file: state.transfer,
                finalURL: finalURL,
                mediaType: response.mimeType,
                contentEncoding: response.value(forHTTPHeaderField: "Content-Encoding"),
                contentLength: response.expectedContentLength >= 0
                    ? response.expectedContentLength : nil,
                contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                etag: response.value(forHTTPHeaderField: "ETag"),
                lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                redirects: state.redirects,
                transportInterrupted: interrupted)))
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
        _ = session
    }
}

package enum DownloadRedirectPolicy {
    static func permits(
        _ url: URL,
        redirectCount: Int,
        specification: DownloadSpec
    ) -> Bool {
        guard redirectCount <= specification.maximumRedirects,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let redirectOrigin = origin(of: url)
        else { return false }
        return specification.permittedRedirectOrigins.contains(redirectOrigin)
    }
}

public enum DownloadFailure: Error, CustomStringConvertible, Sendable {
    case redirectRejected
    case httpStatus(Int)
    case contentEncoding(String)
    case mediaType(String)
    case sizeExceeded
    case missingContentLength
    case contentLengthMismatch(declared: Int64, received: Int64)
    case missingResponse
    case requestTimedOut
    case interruptedTransfer
    case unexpectedPartialResponse
    case invalidRangeResponse
    case invalidPartialState
    case incompleteTransfer(received: Int64, expected: Int64)
    case digestMismatch(expected: ArtifactDigest, actual: ArtifactDigest)

    public var description: String {
        switch self {
        case .redirectRejected: "download redirect violated the declared HTTPS origin policy"
        case .httpStatus(let status): "download returned HTTP status \(status)"
        case .contentEncoding(let value): "download returned forbidden content encoding '\(value)'"
        case .mediaType(let value): "download returned undeclared media type '\(value)'"
        case .sizeExceeded: "download exceeded its declared maximum size"
        case .missingContentLength:
            "download response omitted Content-Length"
        case .contentLengthMismatch(let declared, let received):
            "download Content-Length declared \(declared) bytes but received \(received)"
        case .missingResponse: "download completed without a valid HTTP response"
        case .requestTimedOut: "download exceeded its declared request timeout"
        case .interruptedTransfer:
            "download transport ended before the declared response completed"
        case .unexpectedPartialResponse: "download returned 206 without a resumable partial"
        case .invalidRangeResponse: "download returned a malformed or mismatched range response"
        case .invalidPartialState: "download partial metadata does not match its stored bytes"
        case .incompleteTransfer(let received, let expected):
            "download remains incomplete at \(received) of \(expected) bytes"
        case .digestMismatch(let expected, let actual):
            "download digest mismatch: expected \(expected), received \(actual)"
        }
    }
}

private struct ByteRange {
    let start: Int64
    let end: Int64
    let total: Int64
}

private func parseContentRange(_ value: String?) -> ByteRange? {
    guard let value, value.hasPrefix("bytes ") else { return nil }
    let fields = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard fields.count == 2,
          let total = Int64(fields[1])
    else { return nil }
    let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2,
          let start = Int64(bounds[0]),
          let end = Int64(bounds[1])
    else { return nil }
    return ByteRange(start: start, end: end, total: total)
}

private func origin(of url: URL?) -> String? {
    guard let url,
          let scheme = url.scheme?.lowercased(),
          let host = url.host?.lowercased()
    else { return nil }
    let port = url.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)"
}

private func fileSize(_ path: FilePath) throws -> Int64 {
    let metadata = try path.stat(followTargetSymlink: false)
    guard metadata.type == .regular else { throw DownloadFailure.invalidPartialState }
    return Int64(metadata.size)
}

private func appendFile(_ source: FilePath, to destination: FilePath) throws {
    let input = try FileDescriptor.open(source, .readOnly)
    defer { try? input.close() }
    let output = try FileDescriptor.open(
        destination,
        .writeOnly,
        options: [.create, .append],
        permissions: .ownerReadWrite)
    defer { try? output.close() }
    try copyBytes(from: input, to: output)
    guard collider_sync_file(output.rawValue) == 0 else { throw Errno(rawValue: errno) }
}

private func copyFile(_ source: FilePath, to destination: FilePath) throws {
    let input = try FileDescriptor.open(source, .readOnly)
    defer { try? input.close() }
    let output = try FileDescriptor.open(
        destination,
        .writeOnly,
        options: [.create, .truncate],
        permissions: .ownerReadWrite)
    defer { try? output.close() }
    try copyBytes(from: input, to: output)
    guard collider_sync_file(output.rawValue) == 0 else { throw Errno(rawValue: errno) }
}

private func copyBytes(from input: FileDescriptor, to output: FileDescriptor) throws {
    var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
    while true {
        let count = try buffer.withUnsafeMutableBytes { try input.read(into: $0) }
        if count == 0 { return }
        try output.writeAll(buffer[..<count])
    }
}

private func digest(file path: FilePath) throws -> ArtifactDigest {
    let descriptor = try FileDescriptor.open(path, .readOnly)
    defer { try? descriptor.close() }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
    while true {
        let count = try buffer.withUnsafeMutableBytes { try descriptor.read(into: $0) }
        if count == 0 { break }
        hasher.update(data: buffer[..<count])
    }
    return ArtifactDigest(bytes: Array(hasher.finalize()))
}

private func writeJSON<T: Encodable>(_ value: T, to path: FilePath) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0a)
    let temporary = FilePath(path.string + ".candidate-\(getpid())")
    let descriptor = try FileDescriptor.open(
        temporary,
        .writeOnly,
        options: [.create, .truncate],
        permissions: .ownerReadWrite)
    do {
        try descriptor.writeAll(data)
        guard collider_sync_file(descriptor.rawValue) == 0 else {
            throw Errno(rawValue: errno)
        }
        try descriptor.close()
        guard collider_replace(temporary.string, path.string) == 0 else {
            throw Errno(rawValue: errno)
        }
        let parent = try FileDescriptor.open(path.removingLastComponent(), .readOnly)
        defer { try? parent.close() }
        guard collider_sync_directory(parent.rawValue) == 0 else {
            throw Errno(rawValue: errno)
        }
    } catch {
        try? descriptor.close()
        try? FileManager.default.removeItem(atPath: temporary.string)
        throw error
    }
}
