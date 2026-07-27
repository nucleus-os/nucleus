import ColliderCore
import Foundation
import NucleusSessionProtocol
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct NumericPlotSummary: Equatable {
    let count: Int
    let p50: Double
    let p90: Double
    let p99: Double
    let maximum: Double
}

func summarizeNumericPlots(_ csv: String) -> [String: NumericPlotSummary] {
    var samples: [String: [Double]] = [:]
    for row in csv.split(separator: "\n").dropFirst() {
        let fields = row.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count > 6, let value = Double(fields[6]), value.isFinite else { continue }
        samples[String(fields[0]), default: []].append(value)
    }

    func percentile(_ fraction: Double, in sorted: [Double]) -> Double {
        let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
        return sorted[rank - 1]
    }

    return samples.mapValues { values in
        let sorted = values.sorted()
        return NumericPlotSummary(
            count: sorted.count,
            p50: percentile(0.50, in: sorted),
            p90: percentile(0.90, in: sorted),
            p99: percentile(0.99, in: sorted),
            maximum: sorted[sorted.count - 1])
    }
}

struct ProfileCapture {
    let context: WorkspaceContext

    func run(
        options: RunOptions,
        installation: RuntimeInstallation,
        environment configuredEnvironment: [String: String],
        sessionLog: URL?
    ) async throws {
        let compositor = context.layout.compositor
        let receiver = compositor.appendingPathComponent(".tracy-build/tracy-capture")
        let exporter = compositor.appendingPathComponent(".tracy-build/tracy-csvexport")
        guard FileManager.default.isExecutableFile(atPath: receiver.path), FileManager.default.isExecutableFile(atPath: exporter.path) else {
            throw WorkspaceFailure.message(
                "Tracy receivers are missing; rerun without --no-build")
        }
        let port = try await availablePort(startingAt: options.port)

        let runDirectory = URL(fileURLWithPath: options.output, relativeTo: compositor).standardizedFileURL.appendingPathComponent(options.name)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let capture = runDirectory.appendingPathComponent("capture.tracy")
        let captureLog = runDirectory.appendingPathComponent("tracy-capture.log")
        let sessionStatus = runDirectory.appendingPathComponent("session-status.bin")
        let profileCompositorLog = runDirectory.appendingPathComponent(
            "nucleus_drm.log")
        let compositorLog: URL
        if let sessionLog {
            try FileManager.default.createSymbolicLink(
                at: profileCompositorLog,
                withDestinationURL: sessionLog)
            compositorLog = sessionLog
        } else {
            compositorLog = profileCompositorLog
        }
        if let colliderRun = context.environment["NUCLEUS_RUN_DIR"] {
            let stageLog = URL(fileURLWithPath: colliderRun)
                .appendingPathComponent("stages/profile-capture.log")
            try? FileManager.default.removeItem(at: captureLog)
            try FileManager.default.createSymbolicLink(
                at: captureLog,
                withDestinationURL: stageLog)
        }
        try writeMetadata(
            options,
            port: port,
            binary: installation.compositor,
            directory: runDirectory)

        var environment = configuredEnvironment
        environment["TRACY_PORT"] = String(port)
        let runtimeEnvironment = environment
        let configuration = try options.sessionConfiguration
        let sessionArguments = [
            "--status-file", sessionStatus.path,
            "--configuration", configuration.hexEncoded,
            "--", installation.compositor.path,
        ] + options.compositorArguments
        try await context.withRunningCommand(
            installation.session.path,
            sessionArguments,
            directory: compositor,
            environmentOverrides: runtimeEnvironment,
            stage: TaskID(rawValue: "profile.session")
        ) { session in
            try await session.waitUntilReady()
            try await waitForSessionReady(
                session,
                statusFile: sessionStatus,
                log: compositorLog,
                environment: runtimeEnvironment)
            let captureObservation = try await context.withRunningCommand(
                receiver.path,
                captureArguments(options, port: port, capture: capture),
                directory: compositor,
                environmentOverrides: context.environment,
                stage: TaskID(rawValue: "profile.capture")
            ) { captureProcess in
                try await captureProcess.waitUntilReady()
                print("profile dir: \(runDirectory.path)")
                let compositorExited = try await waitForCapture(
                    captureProcess,
                    compositor: session)
                let status: Int32? =
                    if compositorExited {
                        nil
                    } else {
                        try await captureProcess.wait().status
                    }
                return CaptureObservation(
                    compositorExited: compositorExited,
                    status: status)
            }
            let captureStatus = captureObservation.status ?? 130
            if captureObservation.compositorExited,
                await session.terminationStatus != 0
            {
                throw WorkspaceFailure.message(
                    "launched compositor exited with status "
                        + "\(await session.terminationStatus ?? -1); see "
                        + compositorLog.path)
            }
            let captureIsEmpty: Bool
            if FileManager.default.fileExists(atPath: capture.path) {
                captureIsEmpty = try Data(contentsOf: capture).isEmpty
            } else {
                captureIsEmpty = true
            }
            if captureObservation.compositorExited, captureIsEmpty {
                throw WorkspaceFailure.message(
                    "launched compositor exited before Tracy produced a capture; "
                        + "see \(compositorLog.path)")
            }
            guard FileManager.default.fileExists(atPath: capture.path),
                (try Data(contentsOf: capture)).count > 0
            else {
                throw WorkspaceFailure.message(
                    "Tracy capture exited with status \(captureStatus) and "
                        + "produced no data; see \(captureLog.path)")
            }
            let summary = try await exportAndSummarize(
                capture: capture,
                exporter: exporter,
                directory: runDirectory)
            if summary.eventCount == 0, summary.plotCount == 0 {
                throw WorkspaceFailure.message(
                    "capture contains no Tracy events or plots; the compositor "
                        + "likely failed during bring-up; see \(compositorLog.path) "
                        + "and \(captureLog.path)")
            }
            print("profile captured: \(capture.path)")
        }
    }

    private func captureArguments(_ options: RunOptions, port: Int, capture: URL) -> [String] {
        var value = ["-o", capture.path, "-a", options.host, "-p", String(port)]
        if let seconds = options.seconds { value += ["-s", String(seconds)] }
        return value
    }

    private func availablePort(startingAt requested: Int) async throws -> Int {
        for candidate in requested...(requested + 32) {
            let result = try? await context.run(
                "ss",
                ["-ltnH", "sport", "=", ":\(candidate)"],
                capture: true)
            if result?.isEmpty != false { return candidate }
        }
        throw WorkspaceFailure.message("no free Tracy port found near \(requested)")
    }

    private func waitForCapture(
        _ capture: RunningCommand,
        compositor: RunningCommand
    ) async throws -> Bool {
        while await capture.isRunning {
            if !(await compositor.isRunning) {
                return true
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
        return false
    }

    private func waitForSessionReady(
        _ managed: RunningCommand,
        statusFile: URL,
        log: URL,
        environment: [String: String]
    ) async throws {
        for _ in 0..<150 {
            if let data = try? Data(contentsOf: statusFile),
               let message = SessionReadinessMessage(encoded: Array(data)) {
                switch message.milestone {
                case .shellReady:
                    guard message.role == .shell else { break }
                    return
                case .failed:
                    let reason = SessionFailureReason(
                        rawValue: message.detail)
                        .map { String(describing: $0) }
                        ?? "unknown failure detail \(message.detail)"
                    throw WorkspaceFailure.message(
                        "native session supervisor reported startup failure "
                            + "(\(reason)); see \(log.path)")
                case .compositorReady, .terminating:
                    break
                }
            }
            if !(await managed.isRunning) {
                _ = try? await managed.wait()
                throw WorkspaceFailure.message(
                    "launched compositor exited with status "
                        + "\(await managed.terminationStatus ?? -1) during "
                        + "bring-up; see \(log.path)")
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
        let graphicalSession = environment["WAYLAND_DISPLAY"] != nil || environment["DISPLAY"] != nil
        let hint = graphicalSession
            ? " The current graphical session likely owns the DRM seat; switch to a free virtual terminal and run collider run there."
            : " Check the compositor log for the blocked bring-up stage."
        throw WorkspaceFailure.message(
            "compositor and shell did not report native readiness within 15 seconds."
                + "\(hint) See \(log.path)")
    }

    private func writeMetadata(
        _ options: RunOptions,
        port: Int,
        binary: URL,
        directory: URL
    ) throws {
        let values = [
            "created_at=\(ISO8601DateFormatter().string(from: Date()))",
            "host=\(options.host)", "port=\(port)", "seconds=\(options.seconds.map(String.init) ?? "until-client-exit")",
            "optimize=\(options.effectiveOptimization.rawValue)",
            "tracy=true", "launch=true",
            "session=true", "vk_validation=\(options.validation)",
            "output_scale=\(options.scale ?? 1)",
            "present_mode=\((options.presentMode ?? .vsync).rawValue)",
            "sanitizer=\(options.sanitizer?.rawValue ?? "none")",
            "compositor=\(binary.path)",
        ]
        try Data((values.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("metadata.txt"), options: .atomic)
    }

    private func exportAndSummarize(
        capture: URL,
        exporter: URL,
        directory: URL
    ) async throws -> ProfileSummaryStats {
        let events = try await context.run(
            exporter.path,
            ["-u", capture.path],
            capture: true)
        let plots = try await context.run(
            exporter.path,
            ["-u", "-p", capture.path],
            capture: true)
        try Data(events.utf8).write(to: directory.appendingPathComponent("trace-events.csv"), options: .atomic)
        try Data(plots.utf8).write(to: directory.appendingPathComponent("trace-plots.csv"), options: .atomic)
        var eventCounts: [String: Int] = [:]
        var overBudget: [String: [Int: Int]] = [:]
        for row in events.split(separator: "\n").dropFirst() {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            if let name = fields.first, !name.isEmpty {
                let key = String(name)
                eventCounts[key, default: 0] += 1
                if fields.count > 4, let duration = Int(fields[4]) {
                    for budget in [4_166_667, 2_777_778, 2_000_000] where duration > budget { overBudget[key, default: [:]][budget, default: 0] += 1 }
                }
            }
        }
        let plotSummaries = summarizeNumericPlots(plots)
        let budgetNames = [4_166_667: "240hz", 2_777_778: "360hz", 2_000_000: "500hz"]
        let budgets = overBudget.flatMap { name, values in values.map { "\(name).over_\(budgetNames[$0.key]!).budget=\($0.value)" } }
        let numericPlotLines = plotSummaries.sorted { $0.key < $1.key }.flatMap { name, value in
            [
                "\(name).count=\(value.count)",
                "\(name).p50=\(value.p50)",
                "\(name).p90=\(value.p90)",
                "\(name).p99=\(value.p99)",
                "\(name).max=\(value.maximum)",
            ]
        }
        let summary = (["framebuffer_effect_cache.create_failures=0"]
            + eventCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            + numericPlotLines
            + budgets.sorted()).joined(separator: "\n") + "\n"
        try Data(summary.utf8).write(to: directory.appendingPathComponent("trace-summary.txt"), options: .atomic)
        return ProfileSummaryStats(
            eventCount: eventCounts.values.reduce(0, +),
            plotCount: plots.split(separator: "\n").dropFirst().count)
    }
}

private struct ProfileSummaryStats {
    var eventCount: Int
    var plotCount: Int
}

private struct CaptureObservation: Sendable {
    var compositorExited: Bool
    var status: Int32?
}
