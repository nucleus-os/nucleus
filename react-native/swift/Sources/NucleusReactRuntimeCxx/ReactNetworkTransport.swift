import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NucleusReactRuntimeCxxBridge
import Synchronization

package final class ReactNetworkTransport: @unchecked Sendable {
    private let eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    private let cookieJar = ReactCookieJar()
    private let httpClient: HTTPClient

    package init() {
        var configuration = HTTPClient.Configuration.singletonConfiguration
        // Nucleus owns redirect policy so cookies set by an intermediate
        // response can participate in the very next request.
        configuration.redirectConfiguration = .disallow
        httpClient = HTTPClient(
            eventLoopGroup: eventLoopGroup,
            configuration: configuration
        )
    }

    deinit {
        try? httpClient.syncShutdown()
    }

    package func makeFacade() -> nucleus.react.NetworkTransport {
        unsafe nucleus.react.NetworkTransport(
            .init { [self] request, callbacks in
                unsafe startHTTPRequest(request, callbacks: callbacks)
            },
            .init { [self] callbacks in
                unsafe createWebSocket(callbacks: callbacks)
            }
        )
    }

    fileprivate func startHTTPRequest(
        _ request: borrowing nucleus.react.NetworkHTTPRequest,
        callbacks: nucleus.react.NetworkHTTPCallbacks
    ) -> nucleus.react.NetworkRequestToken {
        let sink = unsafe HTTPCallbackSink(callbacks)
        do {
            let prepared = try makeRequest(request)
            let timeoutMilliseconds = request.timeoutMilliseconds
            let deadline: NIODeadline =
                timeoutMilliseconds == 0
                ? .distantFuture
                : .now() + .milliseconds(Int64(timeoutMilliseconds))
            let handle = HTTPRequestHandle()
            let task = Task { [self] in
                await execute(
                    prepared,
                    deadline: deadline,
                    callbacks: sink
                )
            }
            handle.install(task)
            return unsafe nucleus.react.NetworkRequestToken(.init { handle.cancel() })
        } catch {
            unsafe sink.value.didComplete(std.string(String(describing: error)), false)
            return unsafe nucleus.react.NetworkRequestToken()
        }
    }

    private func execute(
        _ prepared: PreparedRequest,
        deadline: NIODeadline,
        callbacks: HTTPCallbackSink
    ) async {
        do {
            if prepared.bodyByteCount > 0 {
                unsafe callbacks.value.didSendBody(
                    Int64(prepared.bodyByteCount),
                    Int64(prepared.bodyByteCount)
                )
            }

            var request = prepared.request
            var visited = Set<String>()
            for redirectCount in 0...20 {
                try Task.checkCancellation()
                try applyCookies(to: &request)
                guard visited.insert(request.url).inserted else {
                    throw ReactNetworkError.redirectCycle
                }

                let response = try await httpClient.execute(request, deadline: deadline)
                guard let responseURL = URL(string: request.url) else {
                    throw ReactNetworkError.invalidRequest
                }
                cookieJar.store(response.headers["set-cookie"], from: responseURL)

                if let redirect = try redirectRequest(
                    from: request,
                    response: response,
                    responseURL: responseURL,
                    redirectCount: redirectCount
                ) {
                    try await discardRedirectBody(response.body)
                    request = redirect
                    continue
                }

                try await deliver(
                    response,
                    callbacks: callbacks
                )
                unsafe callbacks.value.didComplete(std.string(), false)
                return
            }
            throw ReactNetworkError.redirectLimitReached
        } catch {
            unsafe callbacks.value.didComplete(
                std.string(String(describing: error)), isTimeout(error))
        }
    }

    private func deliver(
        _ response: HTTPClientResponse,
        callbacks: HTTPCallbackSink
    ) async throws {
        unsafe callbacks.value.didReceiveResponse(UInt16(response.status.code))
        for header in response.headers {
            unsafe callbacks.value.didReceiveHeader(
                std.string(header.name), std.string(header.value))
        }
        unsafe callbacks.value.didFinishHeaders()

        let total = response.headers.first(name: "content-length").flatMap(Int64.init) ?? -1
        var received: Int64 = 0
        for try await buffer in response.body {
            try Task.checkCancellation()
            received += Int64(buffer.readableBytes)
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            var cxxBytes = nucleus.react.NetworkBytes()
            cxxBytes.reserve(bytes.count)
            for byte in bytes { cxxBytes.push_back(byte) }
            let accepted = unsafe callbacks.value.didReceiveBody(received, total, cxxBytes)
            guard accepted > 0 || buffer.readableBytes == 0 else {
                throw ReactNetworkError.responseRejected
            }
        }
    }

    private func makeRequest(
        _ request: borrowing nucleus.react.NetworkHTTPRequest
    ) throws -> PreparedRequest {
        var result = HTTPClientRequest(url: String(request.url))
        result.method = HTTPMethod(rawValue: String(request.method))
        for header in request.headers {
            result.headers.add(name: String(header.name), value: String(header.value))
        }

        let body: ByteBuffer?
        switch request.bodyKind {
        case .none:
            body = nil
        case .bytes:
            body = ByteBuffer(bytes: Array(request.body))
        case .base64:
            let encoded = Data(Array(request.body))
            guard
                let string = String(data: encoded, encoding: .utf8),
                let decoded = Data(base64Encoded: string)
            else {
                throw ReactNetworkError.invalidBase64Body
            }
            body = ByteBuffer(bytes: decoded)
        default:
            throw ReactNetworkError.unsupportedBody
        }
        if let body {
            result.body = .bytes(body)
        }
        return PreparedRequest(request: result, bodyByteCount: body?.readableBytes ?? 0)
    }

    private func applyCookies(to request: inout HTTPClientRequest) throws {
        guard let url = URL(string: request.url) else {
            throw ReactNetworkError.invalidRequest
        }
        let stored = cookieJar.header(for: url)
        guard !stored.isEmpty else { return }
        let supplied = request.headers["cookie"].joined(separator: "; ")
        request.headers.replaceOrAdd(
            name: "Cookie",
            value: supplied.isEmpty ? stored : "\(supplied); \(stored)"
        )
    }

    private func redirectRequest(
        from request: HTTPClientRequest,
        response: HTTPClientResponse,
        responseURL: URL,
        redirectCount: Int
    ) throws -> HTTPClientRequest? {
        guard
            [301, 302, 303, 307, 308].contains(response.status.code),
            let location = response.headers.first(name: "location"),
            let target = URL(string: location, relativeTo: responseURL)?.absoluteURL
        else {
            return nil
        }
        guard redirectCount < 20 else {
            throw ReactNetworkError.redirectLimitReached
        }

        let changesToGet =
            response.status.code == 303 && request.method != .HEAD
            || (response.status.code == 301 || response.status.code == 302)
                && request.method == .POST
        var redirected = request
        redirected.url = target.absoluteString
        if changesToGet {
            redirected.method = .GET
            redirected.body = nil
            redirected.headers.remove(name: "Content-Length")
            redirected.headers.remove(name: "Content-Type")
        }
        redirected.headers.remove(name: "Cookie")
        if !sameOrigin(responseURL, target) {
            redirected.headers.remove(name: "Origin")
            redirected.headers.remove(name: "Authorization")
            redirected.headers.remove(name: "Proxy-Authorization")
        }
        return redirected
    }

    private func discardRedirectBody(_ body: HTTPClientResponse.Body) async throws {
        var byteCount = 0
        for try await buffer in body {
            byteCount += buffer.readableBytes
            guard byteCount <= 64 * 1024 else {
                throw ReactNetworkError.redirectBodyTooLarge
            }
        }
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    private func isTimeout(_ error: Error) -> Bool {
        guard let error = error as? HTTPClientError else { return false }
        switch error {
        case .connectTimeout, .readTimeout, .deadlineExceeded:
            return true
        default:
            return false
        }
    }
}

private struct PreparedRequest: Sendable {
    var request: HTTPClientRequest
    var bodyByteCount: Int
}

@safe private final class HTTPCallbackSink: @unchecked Sendable {
    let value: nucleus.react.NetworkHTTPCallbacks

    init(_ value: consuming nucleus.react.NetworkHTTPCallbacks) {
        unsafe self.value = value
    }
}

private enum ReactNetworkError: Error, CustomStringConvertible {
    case invalidBase64Body
    case invalidRequest
    case redirectCycle
    case redirectBodyTooLarge
    case redirectLimitReached
    case responseRejected
    case unsupportedBody

    var description: String {
        switch self {
        case .invalidBase64Body: "invalid base64 request body"
        case .invalidRequest: "invalid HTTP request"
        case .redirectCycle: "HTTP redirect cycle detected"
        case .redirectBodyTooLarge: "HTTP redirect response body exceeded 64 KiB"
        case .redirectLimitReached: "HTTP redirect limit reached"
        case .responseRejected: "response body exceeded its consumer limit"
        case .unsupportedBody: "blob and multipart bodies require Blob integration"
        }
    }
}

private final class HTTPRequestHandle: @unchecked Sendable {
    private struct State {
        var cancelled = false
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func install(_ task: Task<Void, Never>) {
        let cancel = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        if cancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

private final class ReactCookieJar: @unchecked Sendable {
    private struct Key: Hashable {
        var name: String
        var domain: String
        var path: String
        var hostOnly: Bool
    }

    private struct StoredCookie {
        var cookie: HTTPClient.Cookie
        var hostOnly: Bool
        var expiresAt: Date?
    }

    private let storage = Mutex([Key: StoredCookie]())

    func store(_ headers: [String], from url: URL) {
        guard let host = url.host?.lowercased() else { return }
        let now = Date()
        storage.withLock { cookies in
            cookies = cookies.filter { $0.value.expiresAt.map { $0 > now } ?? true }
            for header in headers {
                guard var cookie = HTTPClient.Cookie(header: header, defaultDomain: host) else {
                    continue
                }
                let attributes = cookieAttributes(header)
                let hostOnly = attributes["domain"] == nil
                let domain = (cookie.domain ?? host).lowercased()
                guard hostOnly ? domain == host : domainMatches(host: host, domain: domain) else {
                    continue
                }
                if attributes["path"] == nil {
                    cookie.path = defaultCookiePath(url.path)
                }
                let key = Key(
                    name: cookie.name,
                    domain: domain,
                    path: cookie.path,
                    hostOnly: hostOnly
                )
                let expiresAt: Date?
                if let maxAge = cookie.maxAge {
                    expiresAt = now.addingTimeInterval(TimeInterval(maxAge))
                } else {
                    expiresAt = attributes["expires"].flatMap(parseCookieDate)
                }
                if cookie.maxAge.map({ $0 <= 0 }) == true
                    || expiresAt.map({ $0 <= now }) == true
                {
                    cookies.removeValue(forKey: key)
                } else {
                    cookies[key] = StoredCookie(
                        cookie: cookie,
                        hostOnly: hostOnly,
                        expiresAt: expiresAt
                    )
                }
            }
        }
    }

    func header(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        let now = Date()
        return storage.withLock { cookies in
            cookies = cookies.filter { $0.value.expiresAt.map { $0 > now } ?? true }
            return cookies.values
                .filter { stored in
                    let domain = stored.cookie.domain ?? host
                    return (!stored.cookie.secure || secure)
                        && (stored.hostOnly
                            ? host == domain
                            : domainMatches(host: host, domain: domain))
                        && pathMatches(requestPath: path, cookiePath: stored.cookie.path)
                }
                .sorted { $0.cookie.path.count > $1.cookie.path.count }
                .map { "\($0.cookie.name)=\($0.cookie.value)" }
                .joined(separator: "; ")
        }
    }

    private func cookieAttributes(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for component in header.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1)
            let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            result[name] =
                pair.count == 2
                ? pair[1].trimmingCharacters(in: .whitespaces)
                : ""
        }
        return result
    }

    private func defaultCookiePath(_ requestPath: String) -> String {
        guard requestPath.first == "/" else { return "/" }
        guard let separator = requestPath.dropFirst().lastIndex(of: "/") else { return "/" }
        return String(requestPath[...separator])
    }

    private func domainMatches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    private func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return requestPath.count == cookiePath.count
            || cookiePath.hasSuffix("/")
            || requestPath.dropFirst(cookiePath.count).first == "/"
    }

    private func parseCookieDate(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
