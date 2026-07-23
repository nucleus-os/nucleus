@testable import ColliderDownloads
import ColliderCore
import ColliderRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import SystemPackage
import Testing

private struct StubHTTPResponse: Sendable {
    enum Completion: Sendable {
        case finish
        case fail(URLError.Code)
        case pending
    }

    let status: Int
    let headers: [String: String]
    let body: Data
    let completion: Completion

    init(
        status: Int,
        headers: [String: String],
        body: Data,
        completion: Completion = .finish
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.completion = completion
    }
}

private struct StubHTTPExchange {
    var responses: [StubHTTPResponse] = []
    var requests: [URLRequest] = []
}

private final class StubURLProtocol: URLProtocol {
    static let exchange = Mutex(StubHTTPExchange())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.exchange.withLock { exchange -> StubHTTPResponse? in
            exchange.requests.append(request)
            guard !exchange.responses.isEmpty else { return nil }
            return exchange.responses.removeFirst()
        }
        guard let response,
              let url = request.url,
              let http = HTTPURLResponse(
                  url: url,
                  statusCode: response.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: response.headers)
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse))
            return
        }
        if (300...399).contains(response.status),
           let location = response.headers["Location"],
           let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL
        {
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: redirectURL),
                redirectResponse: http)
            return
        }
        client?.urlProtocol(
            self,
            didReceive: http,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        switch response.completion {
        case .finish:
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending:
            break
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct DownloadPolicyTests {
    @Test func acceptsVerifiedBoundedHTTPSResponse() async throws {
        let body = Data("verified download".utf8)
        let fixture = try fixture(response: StubHTTPResponse(
            status: 200,
            headers: headers(for: body),
            body: body))
        defer { fixture.remove() }

        try await fixture.download()

        #expect(try Data(contentsOf: fixture.candidate) == body)
    }

    @Test func rejectsHTTPStatusBeforeBodyMetadata() async throws {
        try await expectFailure(
            StubHTTPResponse(status: 503, headers: [:], body: Data()),
            containing: "HTTP status 503")
    }

    @Test func rejectsMissingAndIncorrectContentLength() async throws {
        let body = Data("length".utf8)
        try await expectFailure(
            StubHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/octet-stream"],
                body: body),
            containing: "omitted Content-Length")
        try await expectFailure(
            StubHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Length": "\(body.count + 3)",
                ],
                body: body),
            containing: "declared \(body.count + 3) bytes")
    }

    @Test func rejectsSizeOverflowAndEncodedBodies() async throws {
        let body = Data(repeating: 0x61, count: 32)
        try await expectFailure(
            StubHTTPResponse(
                status: 200,
                headers: headers(for: body),
                body: body),
            maximumSize: 8,
            containing: "maximum size")
        var encodedHeaders = headers(for: body)
        encodedHeaders["Content-Encoding"] = "gzip"
        try await expectFailure(
            StubHTTPResponse(
                status: 200,
                headers: encodedHeaders,
                body: body),
            containing: "forbidden content encoding")
    }

    @Test func rejectsDigestMismatchAndCleansPrivateCandidates() async throws {
        let body = Data("wrong bytes".utf8)
        try await expectFailure(
            StubHTTPResponse(
                status: 200,
                headers: headers(for: body),
                body: body),
            expectedDigest: ArtifactHasher.digest(bytes: Data("expected".utf8)),
            containing: "digest mismatch")
    }

    @Test func resumesInterruptedETagTransferWithValidatedRange() async throws {
        let complete = Data("resumable-payload".utf8)
        let first = Data(complete.prefix(6))
        let remaining = Data(complete.dropFirst(6))
        let fixture = try fixture(
            responses: [
                StubHTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Content-Length": "\(complete.count)",
                        "ETag": "\"fixture-v1\"",
                    ],
                    body: first,
                    completion: .fail(.networkConnectionLost)),
                StubHTTPResponse(
                    status: 206,
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Content-Length": "\(remaining.count)",
                        "Content-Range":
                            "bytes 6-\(complete.count - 1)/\(complete.count)",
                        "ETag": "\"fixture-v1\"",
                    ],
                    body: remaining),
            ],
            expectedDigest: ArtifactHasher.digest(bytes: complete),
            maximumRetries: 1)
        defer { fixture.remove() }

        try await fixture.download()

        #expect(try Data(contentsOf: fixture.candidate) == complete)
        let requests = StubURLProtocol.exchange.withLock { $0.requests }
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=6-")
        #expect(requests[1].value(forHTTPHeaderField: "If-Range")
            == "\"fixture-v1\"")
    }

    @Test func resumesInterruptedLastModifiedTransfer() async throws {
        let complete = Data("last-modified-payload".utf8)
        let split = 5
        let fixture = try fixture(
            responses: [
                StubHTTPResponse(
                    status: 200,
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Content-Length": "\(complete.count)",
                        "Last-Modified":
                            "Wed, 22 Jul 2026 12:00:00 GMT",
                    ],
                    body: Data(complete.prefix(split)),
                    completion: .fail(.networkConnectionLost)),
                StubHTTPResponse(
                    status: 206,
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Content-Length": "\(complete.count - split)",
                        "Content-Range":
                            "bytes \(split)-\(complete.count - 1)/\(complete.count)",
                        "Last-Modified":
                            "Wed, 22 Jul 2026 12:00:00 GMT",
                    ],
                    body: Data(complete.dropFirst(split))),
            ],
            expectedDigest: ArtifactHasher.digest(bytes: complete),
            maximumRetries: 1)
        defer { fixture.remove() }

        try await fixture.download()

        let requests = StubURLProtocol.exchange.withLock { $0.requests }
        #expect(requests[1].value(forHTTPHeaderField: "If-Range")
            == "Wed, 22 Jul 2026 12:00:00 GMT")
    }

    @Test func rejectsInvalidRangesAndChangedValidators() async throws {
        let complete = Data("invalid-resume".utf8)
        let prefix = Data(complete.prefix(4))
        for headers in [
            [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(complete.count - 4)",
                "Content-Range":
                    "bytes 5-\(complete.count - 1)/\(complete.count)",
                "ETag": "\"fixture-v1\"",
            ],
            [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(complete.count - 4)",
                "Content-Range":
                    "bytes 4-\(complete.count - 1)/\(complete.count)",
                "ETag": "\"fixture-v2\"",
            ],
        ] {
            let fixture = try fixture(
                responses: [
                    StubHTTPResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "application/octet-stream",
                            "Content-Length": "\(complete.count)",
                            "ETag": "\"fixture-v1\"",
                        ],
                        body: prefix,
                        completion: .fail(.networkConnectionLost)),
                    StubHTTPResponse(
                        status: 206,
                        headers: headers,
                        body: Data(complete.dropFirst(4))),
                ],
                expectedDigest: ArtifactHasher.digest(bytes: complete),
                maximumRetries: 1)
            defer { fixture.remove() }
            do {
                try await fixture.download()
                Issue.record("invalid resumed response was accepted")
            } catch let error as DownloadFailure {
                #expect(error.description.contains("range response"))
            }
            #expect(!FileManager.default.fileExists(
                atPath: fixture.candidate.path))
        }
    }

    @Test func retriesTransientFailuresOnlyWithinTheDeclaredBound() async throws {
        let body = Data("retry".utf8)
        let transient = StubHTTPResponse(
            status: 200,
            headers: headers(for: body),
            body: Data(),
            completion: .fail(.cannotConnectToHost))
        let success = StubHTTPResponse(
            status: 200,
            headers: headers(for: body),
            body: body)
        let succeeding = try fixture(
            responses: [transient, success],
            expectedDigest: ArtifactHasher.digest(bytes: body),
            maximumRetries: 1)
        defer { succeeding.remove() }
        try await succeeding.download()
        #expect(StubURLProtocol.exchange.withLock { $0.requests.count } == 2)

        let exhausted = try fixture(
            responses: [transient, transient, success],
            expectedDigest: ArtifactHasher.digest(bytes: body),
            maximumRetries: 1)
        defer { exhausted.remove() }
        await #expect(throws: URLError.self) {
            try await exhausted.download()
        }
        #expect(StubURLProtocol.exchange.withLock { $0.requests.count } == 2)
    }

    @Test func cancellationRemovesTheInFlightTransfer() async throws {
        let body = Data("pending".utf8)
        let fixture = try fixture(response: StubHTTPResponse(
            status: 200,
            headers: headers(for: body),
            body: Data(),
            completion: .pending))
        defer { fixture.remove() }
        let operation = Task { try await fixture.download() }
        try await ContinuousClock().sleep(for: .milliseconds(20))
        operation.cancel()
        await #expect(throws: (any Error).self) {
            try await operation.value
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.candidate.path))
        if let enumerator = FileManager.default.enumerator(
            at: fixture.directory.appendingPathComponent("cache"),
            includingPropertiesForKeys: nil)
        {
            for case let url as URL in enumerator {
                #expect(!url.lastPathComponent.hasPrefix("transfer-"))
            }
        }
    }

    @Test func downloadManifestRedactsSensitiveQueryValues() async throws {
        let body = Data("manifest".utf8)
        let fixture = try fixture(
            response: StubHTTPResponse(
                status: 200,
                headers: headers(for: body),
                body: body),
            url: #require(URL(
                string: "https://loopback.invalid/artifact?token=manifest-secret")))
        defer { fixture.remove() }
        try await fixture.download()
        let cache = fixture.directory.appendingPathComponent("cache")
        let enumerator = try #require(FileManager.default.enumerator(
            at: cache,
            includingPropertiesForKeys: nil))
        var manifests: [URL] = []
        for case let url as URL in enumerator
            where url.lastPathComponent == "manifest.json"
        {
            manifests.append(url)
        }
        let manifest = try String(
            contentsOf: #require(manifests.first),
            encoding: .utf8)
        #expect(!manifest.contains("manifest-secret"))
        #expect(manifest.contains("%3Credacted%3E"))
    }

    @Test func enforcesRedirectOriginAndHTTPSDowngradePolicy() async throws {
        let body = Data("redirected".utf8)
        let specification = try DownloadSpec(
            url: #require(URL(
                string: "https://loopback.invalid/artifact")),
            permittedRedirectOrigins: ["https://allowed.invalid"],
            expectedDigest: ArtifactHasher.digest(bytes: body),
            maximumResponseSize: 1_024,
            acceptedMediaTypes: ["application/octet-stream"],
            maximumRedirects: 1)
        let allowed = try #require(URL(
            string: "https://allowed.invalid/final"))
        let other = try #require(URL(
            string: "https://other.invalid/final"))
        let downgrade = try #require(URL(
            string: "http://allowed.invalid/final"))
        let credentials = try #require(URL(
            string: "https://user:secret@allowed.invalid/final"))
        #expect(DownloadRedirectPolicy.permits(
            allowed,
            redirectCount: 1,
            specification: specification))
        #expect(!DownloadRedirectPolicy.permits(
            other,
            redirectCount: 1,
            specification: specification))
        #expect(!DownloadRedirectPolicy.permits(
            downgrade,
            redirectCount: 1,
            specification: specification))
        #expect(!DownloadRedirectPolicy.permits(
            credentials,
            redirectCount: 1,
            specification: specification))
        #expect(!DownloadRedirectPolicy.permits(
            allowed,
            redirectCount: 2,
            specification: specification))
    }

    @Test func reportsMonotonicByteProgress() async throws {
        let body = Data("progress".utf8)
        let updates = Mutex<[DownloadProgress]>([])
        let fixture = try fixture(
            response: StubHTTPResponse(
                status: 200,
                headers: headers(for: body),
                body: body),
            progress: { update in
                updates.withLock { $0.append(update) }
            })
        defer { fixture.remove() }

        try await fixture.download()

        let recorded = updates.withLock { $0 }
        let last = try #require(recorded.last)
        #expect(last.receivedBytes == Int64(body.count))
        #expect(last.expectedBytes == Int64(body.count))
        #expect(last.digest == ArtifactHasher.digest(bytes: body))
        #expect(zip(recorded, recorded.dropFirst()).allSatisfy {
            $0.receivedBytes <= $1.receivedBytes
        })
    }

    @Test func completedDownloaderShutsDownIdempotently() async throws {
        let body = Data("shutdown".utf8)
        let fixture = try fixture(
            response: StubHTTPResponse(
                status: 200,
                headers: headers(for: body),
                body: body))
        defer { fixture.remove() }

        try await fixture.download()
        await fixture.downloads.shutdown()
        await fixture.downloads.shutdown()

        #expect(try Data(contentsOf: fixture.candidate) == body)
    }
}

private struct DownloadFixture {
    let directory: URL
    let candidate: URL
    let downloads: ColliderDownloads
    let specification: DownloadSpec

    func download() async throws {
        try await downloads.download(
            specification,
            to: FilePath(candidate.path))
    }

    func remove() {
        StubURLProtocol.exchange.withLock { $0 = StubHTTPExchange() }
        try? FileManager.default.removeItem(at: directory)
    }
}

private func fixture(
    response: StubHTTPResponse,
    maximumSize: Int64 = 1_024,
    expectedDigest: ArtifactDigest? = nil,
    url: URL = URL(string: "https://loopback.invalid/artifact")!,
    progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
) throws -> DownloadFixture {
    try fixture(
        responses: [response],
        maximumSize: maximumSize,
        expectedDigest: expectedDigest,
        url: url,
        progress: progress)
}

private func fixture(
    responses: [StubHTTPResponse],
    maximumSize: Int64 = 1_024,
    expectedDigest: ArtifactDigest? = nil,
    maximumRetries: Int = 0,
    url: URL = URL(string: "https://loopback.invalid/artifact")!,
    permittedRedirectOrigins: Set<String> = [],
    progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
) throws -> DownloadFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-download-\(UUID().uuidString)")
    StubURLProtocol.exchange.withLock {
        $0 = StubHTTPExchange(responses: responses)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return DownloadFixture(
        directory: directory,
        candidate: directory.appendingPathComponent("artifact"),
        downloads: ColliderDownloads(
            cacheRoot: FilePath(directory.appendingPathComponent("cache").path),
            configuration: configuration,
            progress: progress),
        specification: try DownloadSpec(
            url: url,
            permittedRedirectOrigins: permittedRedirectOrigins,
            expectedDigest: expectedDigest
                ?? ArtifactHasher.digest(bytes: responses[0].body),
            maximumResponseSize: maximumSize,
            acceptedMediaTypes: ["application/octet-stream"],
            maximumRetries: maximumRetries))
}

private func headers(for body: Data) -> [String: String] {
    [
        "Content-Type": "application/octet-stream",
        "Content-Length": "\(body.count)",
        "Content-Encoding": "identity",
    ]
}

private func expectFailure(
    _ response: StubHTTPResponse,
    maximumSize: Int64 = 1_024,
    expectedDigest: ArtifactDigest? = nil,
    containing expectedMessage: String
) async throws {
    let fixture = try fixture(
        response: response,
        maximumSize: maximumSize,
        expectedDigest: expectedDigest)
    defer { fixture.remove() }
    do {
        try await fixture.download()
        Issue.record("download unexpectedly passed policy validation")
    } catch let error as DownloadFailure {
        #expect(error.description.contains(expectedMessage))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.candidate.path))
    if let enumerator = FileManager.default.enumerator(
        at: fixture.directory.appendingPathComponent("cache"),
        includingPropertiesForKeys: nil)
    {
        for case let url as URL in enumerator {
            #expect(!url.lastPathComponent.hasPrefix("transfer-"))
        }
    }
}
