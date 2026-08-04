import Dispatch
import Foundation
import Glibc
import NucleusAndroidRuntimeBrokerCore
import NucleusAndroidRuntimeCore
import NucleusAndroidRuntimeHostLinux

@main
enum NucleusAndroidRuntimeMain {
    static func main() async {
        do {
            let signals = RuntimeTerminationSignals()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await run()
                }
                group.addTask {
                    await signals.wait()
                    throw CancellationError()
                }
                do {
                    try await group.next()
                    group.cancelAll()
                    while (try await group.next()) != nil {}
                } catch is CancellationError {
                    group.cancelAll()
                    while (try? await group.next()) != nil {}
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("nucleus-android-runtime: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment
        guard
            let addonRoot = option(
                "addon-root",
                in: arguments),
            let persistentStateRoot = option(
                "state-root",
                in: arguments),
            option(
                "nucleus-session-capability-id",
                in: arguments) == "android",
            let sessionRuntimeDirectory = environment[
                "NUCLEUS_SESSION_RUNTIME_DIR"
            ],
            let waylandSocket = environment[
                "WAYLAND_DISPLAY"
            ]
        else {
            throw AndroidRuntimeFailure(
                "missing Android payload or session environment")
        }
        let timeout: UInt32
        if let value = option("timeout-seconds", in: arguments) {
            guard let parsed = UInt32(value), parsed > 0 else {
                throw AndroidRuntimeFailure(
                    "invalid Android runtime timeout")
            }
            timeout = parsed
        } else {
            timeout = 180
        }
        let executable = URL(
            fileURLWithPath: try FileManager.default
                .destinationOfSymbolicLink(atPath: "/proc/self/exe"))
        let libexec = executable.deletingLastPathComponent()
        let prefix = libexec.deletingLastPathComponent()
        let libraryDirectory = prefix.appendingPathComponent(
            "lib",
            isDirectory: true)
        let diagnosticsRunDirectory =
            environment["NUCLEUS_RUN_DIR"]
            ?? sessionRuntimeDirectory
        let gfxstreamBrokerEnvironment: [String: String]
        if let encoded = environment[
            "NUCLEUS_ANDROID_GFXSTREAM_BROKER_ENVIRONMENT"
        ] {
            gfxstreamBrokerEnvironment = try JSONDecoder().decode(
                [String: String].self,
                from: Data(encoded.utf8))
        } else {
            gfxstreamBrokerEnvironment = [:]
        }
        let gfxstreamBrokerExecutable =
            environment[
                "NUCLEUS_ANDROID_GFXSTREAM_BROKER_EXECUTABLE"
            ].map(URL.init(fileURLWithPath:))
            ?? libexec.appendingPathComponent(
                "nucleus-android-gfxstream-broker")
        let configuration = try AndroidRuntimeBrokerConfiguration(
            addonRoot: URL(
                fileURLWithPath: addonRoot,
                isDirectory: true),
            persistentStateRoot: URL(
                fileURLWithPath: persistentStateRoot,
                isDirectory: true),
            sessionRuntimeDirectory: URL(
                fileURLWithPath: sessionRuntimeDirectory,
                isDirectory: true),
            diagnosticsRunDirectory: URL(
                fileURLWithPath: diagnosticsRunDirectory,
                isDirectory: true),
            waylandSocket: waylandSocket,
            gfxstreamBrokerExecutable: gfxstreamBrokerExecutable,
            displayHostExecutable: libexec.appendingPathComponent(
                "nucleus-android-display-host"),
            privilegedHelperExecutable: libexec.appendingPathComponent(
                "nucleus-android-runtime-privileged"),
            swiftRuntime: try AndroidSwiftRuntime(
                libraryRoot: prefix,
                loaderSearchDirectory: libraryDirectory),
            timeoutSeconds: timeout,
            gfxstreamBrokerEnvironment:
                gfxstreamBrokerEnvironment)
        try await runAndroidRuntimeBroker(
            configuration: configuration,
            host: LinuxAndroidRuntimeHost(),
            environment: environment)
    }

    private static func option(
        _ name: String,
        in arguments: [String]
    ) -> String? {
        let flag = "--\(name)"
        guard arguments.count.isMultiple(of: 2) else {
            return nil
        }
        var value: String?
        var index = 0
        while index < arguments.count {
            guard arguments[index] == flag else {
                index += 2
                continue
            }
            guard value == nil else {
                return nil
            }
            value = arguments[index + 1]
            index += 2
        }
        return value
    }
}

private final class RuntimeTerminationSignals: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let sources: [DispatchSourceSignal]

    init() {
        let stream = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.stream = stream.stream
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: number,
                queue: .global(qos: .userInitiated))
            source.setEventHandler {
                stream.continuation.yield(())
            }
            source.resume()
            sources.append(source)
        }
        self.sources = sources
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}
