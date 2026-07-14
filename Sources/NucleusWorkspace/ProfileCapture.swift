import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct ProfileOptions {
    var output = "profiles"
    var name = compactTimestamp()
    var host = "127.0.0.1"
    var port = 8086
    var seconds: Int?
    var presentMode: String?
    var renderBenchmark: String?
    var build = true
    var launch = false
    var validation = false
    var session = true
    var autostop = true
    var diagnostics = false
    var optimize = "release"
    var tracy = true
    var valgrind = false
    var addressSanitizer = false
    var compositorArguments: [String] = []

    static func parse(_ input: [String]) throws -> ProfileOptions {
        var value = ProfileOptions()
        var index = 0
        func argument(_ option: String) throws -> String {
            guard index + 1 < input.count else { throw WorkspaceFailure.message("missing value for \(option)") }
            index += 1
            return input[index]
        }
        while index < input.count {
            switch input[index] {
            case "--output": value.output = try argument("--output")
            case "--name": value.name = try argument("--name")
            case "--host": value.host = try argument("--host")
            case "--port":
                guard let port = Int(try argument("--port")), (1...65535).contains(port) else { throw WorkspaceFailure.message("invalid Tracy port") }
                value.port = port
            case "--seconds":
                guard let seconds = Int(try argument("--seconds")), seconds > 0 else { throw WorkspaceFailure.message("--seconds must be positive") }
                value.seconds = seconds
            case "--present-mode": value.presentMode = try argument("--present-mode")
            case "--render-benchmark": value.renderBenchmark = try argument("--render-benchmark")
            case "--optimize": value.optimize = try argument("--optimize")
            case "--no-build": value.build = false
            case "--launch": value.launch = true
            case "--vk-validation": value.validation = true
            case "--no-session": value.session = false
            case "--no-autostop": value.autostop = false
            case "--trace-diagnostics": value.diagnostics = true
            case "--no-tracy": value.tracy = false
            case "--sanitize-address": value.addressSanitizer = true
            case "--valgrind": value.valgrind = true; value.launch = true; value.session = false; value.tracy = false
            case "--": value.compositorArguments = Array(input.dropFirst(index + 1)); return try value.validated()
            case "-h", "--help": print(ProfileCapture.usage); throw ProfileHelp.shown
            default: throw WorkspaceFailure.message("unknown profile option '\(input[index])'\n\n\(ProfileCapture.usage)")
            }
            index += 1
        }
        return try value.validated()
    }

    private func validated() throws -> ProfileOptions {
        guard ["debug", "release"].contains(optimize) else { throw WorkspaceFailure.message("--optimize must be debug or release") }
        if let presentMode, !["vsync", "mailbox_latest_wins"].contains(presentMode) { throw WorkspaceFailure.message("invalid present mode '\(presentMode)'") }
        if let renderBenchmark, renderBenchmark != "uncapped" { throw WorkspaceFailure.message("invalid render benchmark '\(renderBenchmark)'") }
        return self
    }
}

private enum ProfileHelp: Error { case shown }

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
    static let usage = """
    Usage: tools/nucleus profile [options] [-- compositor-arguments]

      --output DIR --name NAME --host HOST --port PORT --seconds N
      --present-mode vsync|mailbox_latest_wins --render-benchmark uncapped
      --no-build --no-tracy --optimize debug|release --sanitize-address
      --launch --vk-validation --no-session --no-autostop
      --trace-diagnostics --valgrind
    """

    func run(_ arguments: [String]) throws {
        let options: ProfileOptions
        do { options = try ProfileOptions.parse(arguments) }
        catch ProfileHelp.shown { return }
        let compositor = context.root.appendingPathComponent("compositor")
        if options.launch, options.validation {
            try context.run(
                compositor.appendingPathComponent("scripts/run-vk-validation.sh").path,
                ["--check"], directory: compositor)
        }
        if options.build { try ProfilingCommand(context: context).buildReceivers() }
        let receiver = compositor.appendingPathComponent(".tracy-build/tracy-capture")
        let exporter = compositor.appendingPathComponent(".tracy-build/tracy-csvexport")
        guard FileManager.default.isExecutableFile(atPath: receiver.path), FileManager.default.isExecutableFile(atPath: exporter.path) else {
            throw WorkspaceFailure.message("Tracy receivers are missing; run tools/nucleus profile receivers")
        }
        let port = try availablePort(startingAt: options.port)
        if options.build { try buildCompositor(options, in: compositor) }
        let configuration = options.optimize == "release" ? "Release" : "Debug"
        let binary = compositor.appendingPathComponent("compositor/.build/out/Products/\(configuration)-linux-x86_64/NucleusCompositor")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw WorkspaceFailure.message("compositor not built: \(binary.path)") }

        let runDirectory = URL(fileURLWithPath: options.output, relativeTo: compositor).standardizedFileURL.appendingPathComponent(options.name)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let capture = runDirectory.appendingPathComponent("capture.tracy")
        let captureLog = runDirectory.appendingPathComponent("tracy-capture.log")
        let compositorLog = runDirectory.appendingPathComponent("nucleus_drm.log")
        try writeMetadata(options, port: port, binary: binary, directory: runDirectory)

        var environment = context.environment
        environment["TRACY_PORT"] = String(port)
        if let mode = options.presentMode { environment["NUCLEUS_PRESENT_MODE"] = mode }
        if options.renderBenchmark != nil { environment["NUCLEUS_PROFILE_RENDER_MODE"] = "uncapped_offscreen" }
        if options.diagnostics { environment["NUCLEUS_TRACE_BLUR_PROTOCOL"] = "1"; environment["NUCLEUS_TRACE_DRM_DEMAND"] = "1" }
        if options.validation { environment["NUCLEUS_COMPOSITOR_BIN"] = binary.path }
        if options.addressSanitizer { try configureAddressSanitizer(environment: &environment) }

        var compositorProcess: ProfileProcess?
        var preserveCompositor = false
        defer {
            if let compositorProcess, options.autostop || !preserveCompositor { stop(compositorProcess) }
        }
        if options.launch {
            if environment["WAYLAND_DISPLAY"] != nil || environment["DISPLAY"] != nil {
                throw WorkspaceFailure.message("cannot launch the DRM compositor inside an existing Wayland/X11 desktop session; switch to a free virtual terminal, unset DISPLAY and WAYLAND_DISPLAY, and run the profile command there")
            }
            compositorProcess = try launchCompositor(options, binary: binary, log: compositorLog, environment: environment, directory: compositor)
            try waitForCompositorReady(compositorProcess!, log: compositorLog, environment: environment)
        } else {
            print("waiting for a Tracy-enabled compositor; run with TRACY_PORT=\(port):\n  \(binary.path)")
        }
        let captureProcess = try launch(receiver.path, arguments: captureArguments(options, port: port, capture: capture), log: captureLog, environment: context.environment, directory: compositor)
        print("profile dir: \(runDirectory.path)")
        let compositorExitedDuringCapture = waitForCapture(captureProcess, compositor: compositorProcess)
        if captureProcess.isRunning { captureProcess.interrupt(); captureProcess.waitUntilExit() }
        if options.launch, compositorExitedDuringCapture, let compositorProcess,
           compositorProcess.process.terminationStatus != 0 {
            throw WorkspaceFailure.message("launched compositor exited with status \(compositorProcess.process.terminationStatus); see \(compositorLog.path)")
        }
        let captureIsEmpty: Bool
        if FileManager.default.fileExists(atPath: capture.path) {
            captureIsEmpty = try Data(contentsOf: capture).isEmpty
        } else {
            captureIsEmpty = true
        }
        if options.launch, compositorExitedDuringCapture, captureIsEmpty {
            throw WorkspaceFailure.message("launched compositor exited before Tracy produced a capture; see \(compositorLog.path)")
        }
        guard FileManager.default.fileExists(atPath: capture.path), (try Data(contentsOf: capture)).count > 0 else {
            throw WorkspaceFailure.message("Tracy capture produced no data; see \(captureLog.path)")
        }
        let summary = try exportAndSummarize(capture: capture, exporter: exporter, directory: runDirectory)
        if options.tracy, summary.eventCount == 0, summary.plotCount == 0 {
            throw WorkspaceFailure.message("capture contains no Tracy events or plots; the compositor likely failed during bring-up; see \(compositorLog.path) and \(captureLog.path)")
        }
        print("profile captured: \(capture.path)")
        preserveCompositor = !options.autostop
    }

    private func buildCompositor(_ options: ProfileOptions, in directory: URL) throws {
        var arguments = ["build", "--package-path", "compositor", "-c", options.optimize]
        if options.tracy { arguments += ["-Xcc", "-DTRACY_ENABLE"] }
        if options.addressSanitizer { arguments.append("--sanitize=address") }
        try context.run("swift", arguments, directory: directory)
    }

    private func captureArguments(_ options: ProfileOptions, port: Int, capture: URL) -> [String] {
        var value = ["-o", capture.path, "-a", options.host, "-p", String(port)]
        if let seconds = options.seconds { value += ["-s", String(seconds)] }
        return value
    }

    private func availablePort(startingAt requested: Int) throws -> Int {
        for candidate in requested...(requested + 32) {
            let result = try? context.run("ss", ["-ltnH", "sport", "=", ":\(candidate)"], capture: true)
            if result?.isEmpty != false { return candidate }
        }
        throw WorkspaceFailure.message("no free Tracy port found near \(requested)")
    }

    private func launchCompositor(_ options: ProfileOptions, binary: URL, log: URL, environment: [String: String], directory: URL) throws -> ProfileProcess {
        var executable = binary.path
        var arguments = options.compositorArguments
        if options.validation { executable = directory.appendingPathComponent("scripts/run-vk-validation.sh").path; arguments = options.compositorArguments }
        if options.session { arguments = [executable] + arguments; executable = directory.appendingPathComponent("packages/session/nucleus-session").path }
        if options.valgrind { arguments = ["--tool=memcheck", "--error-exitcode=0", "--log-file=" + log.deletingLastPathComponent().appendingPathComponent("valgrind.log").path, "--num-callers=40", "--track-origins=yes", "--leak-check=no", executable] + arguments; executable = "valgrind" }
        let process = try launch(executable, arguments: arguments, log: log, environment: environment, directory: directory)
        return ProfileProcess(process: process, processGroup: process.processIdentifier)
    }

    private func launch(_ executable: String, arguments: [String], log: URL, environment: [String: String], directory: URL) throws -> Process {
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable.hasPrefix("/") ? URL(fileURLWithPath: executable) : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? arguments : [executable] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    private func waitForCapture(_ capture: Process, compositor: ProfileProcess?) -> Bool {
        var compositorExited = false
        while capture.isRunning {
            if let compositor, !compositor.process.isRunning { compositorExited = true; capture.interrupt(); break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        capture.waitUntilExit()
        return compositorExited
    }

    private func waitForCompositorReady(_ managed: ProfileProcess, log: URL, environment: [String: String]) throws {
        let readyMessage = "Wayland compositor listening on the libwayland router"
        for _ in 0..<150 {
            if let contents = try? String(contentsOf: log, encoding: .utf8) {
                if contents.contains("render runtime: Swift render path active for 0 output(s)") {
                    throw WorkspaceFailure.message("compositor initialized but attached no physical DRM outputs; see \(log.path)")
                }
                if contents.contains(readyMessage) { return }
            }
            if !managed.process.isRunning {
                managed.process.waitUntilExit()
                throw WorkspaceFailure.message("launched compositor exited with status \(managed.process.terminationStatus) during bring-up; see \(log.path)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let graphicalSession = environment["WAYLAND_DISPLAY"] != nil || environment["DISPLAY"] != nil
        let hint = graphicalSession
            ? " The current graphical session likely owns the DRM seat; switch to a free virtual terminal and run the profile command there."
            : " Check the compositor log for the blocked bring-up stage."
        throw WorkspaceFailure.message("compositor did not finish Wayland/DRM bring-up within 15 seconds.\(hint) See \(log.path)")
    }

    private func stop(_ managed: ProfileProcess) {
        let process = managed.process
        if let processGroup = managed.processGroup {
            let group = -processGroup
            _ = kill(group, SIGTERM)
            for _ in 0..<30 {
                if kill(group, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if kill(group, 0) == 0 { _ = kill(group, SIGKILL) }
        } else if process.isRunning {
            process.terminate()
        }
        if process.isRunning { process.waitUntilExit() }
    }

    private func writeMetadata(_ options: ProfileOptions, port: Int, binary: URL, directory: URL) throws {
        let values = [
            "profile_schema=4", "created_at=\(ISO8601DateFormatter().string(from: Date()))",
            "host=\(options.host)", "port=\(port)", "seconds=\(options.seconds.map(String.init) ?? "until-client-exit")",
            "optimize=\(options.optimize)", "tracy=\(options.tracy)", "launch=\(options.launch)",
            "session=\(options.session)", "vk_validation=\(options.validation)",
            "compositor=\(binary.path)",
        ]
        try Data((values.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("metadata.txt"), options: .atomic)
    }

    private func configureAddressSanitizer(environment: inout [String: String]) throws {
        guard let toolchain = environment["SWIFT_TOOLCHAIN"] else { throw WorkspaceFailure.message("--sanitize-address requires SWIFT_TOOLCHAIN") }
        let runtime = toolchain + "/lib/clang/21/lib/linux/libclang_rt.asan-x86_64.so"
        guard FileManager.default.fileExists(atPath: runtime) else { throw WorkspaceFailure.message("ASan runtime not found at \(runtime)") }
        environment["ASAN_OPTIONS"] = "halt_on_error=0:abort_on_error=0:detect_leaks=0:symbolize=1:print_stats=0"
        environment["LD_PRELOAD"] = runtime
        environment["LD_LIBRARY_PATH"] = toolchain + "/lib:" + (environment["LD_LIBRARY_PATH"] ?? "")
    }

    private func exportAndSummarize(capture: URL, exporter: URL, directory: URL) throws -> ProfileSummaryStats {
        let events = try context.run(exporter.path, ["-u", capture.path], capture: true)
        let plots = try context.run(exporter.path, ["-u", "-p", capture.path], capture: true)
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
        let summary = (["profile_schema=4", "framebuffer_effect_cache.create_failures=0"]
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

private struct ProfileProcess {
    var process: Process
    var processGroup: pid_t?
}

private func compactTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
    return formatter.string(from: Date())
}
