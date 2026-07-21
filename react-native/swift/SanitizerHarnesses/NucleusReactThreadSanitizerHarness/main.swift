import Foundation
import Glibc
import NucleusReactFabricSmokeC

private enum HarnessFailure: Error {
    case process(String)
}

@main
enum NucleusReactThreadSanitizerHarness {
    private static let workspaceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().path

    static func main() {
        do {
            guard nucleus_rn_mount_batching_smoke() == 0,
                  nucleus_rn_mount_lifecycle_smoke() == 0,
                  nucleus_rn_mount_event_payload_smoke() == 0
            else {
                exit(2)
            }

            let bytecode = try makeBytecode()
            defer {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: bytecode)
                        .deletingLastPathComponent())
            }
            let result = bytecode.withCString {
                nucleus_rn_js_work_wake_smoke($0)
            }
            exit(result == 0 ? 0 : 3)
        } catch {
            FileHandle.standardError.write(
                Data("RN TSan harness error: \(error)\n".utf8))
            exit(4)
        }
    }

    private static func makeBytecode() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["NUCLEUS_WORKSPACE_ROOT"] ?? workspaceRoot
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-rn-tsan-\(getpid())",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("probe.js")
        let bytecode = directory.appendingPathComponent("probe.hbc")
        try "setTimeout(function () {}, 1);\n"
            .write(to: source, atomically: true, encoding: .utf8)

        var childEnvironment = environment
        if let libcxx = try libcxxDirectory(environment: environment) {
            childEnvironment["LD_LIBRARY_PATH"] = [
                libcxx,
                environment["LD_LIBRARY_PATH"],
            ].compactMap { $0 }.joined(separator: ":")
        }
        let hermesc = root
            + "/react-native/.rn-build/hermes/bin/hermesc"
        let result = try spawn(
            executable: hermesc,
            arguments: [
                "-emit-binary",
                "-out", bytecode.path,
                source.path,
            ],
            environment: childEnvironment)
        guard result.status == 0 else {
            throw HarnessFailure.process(
                "hermesc exited with \(result.status)")
        }
        return bytecode.path
    }

    private static func libcxxDirectory(
        environment: [String: String]
    ) throws -> String? {
        let result = try spawn(
            executable: "/usr/bin/env",
            arguments: [
                "clang++",
                "-print-file-name=libc++.so.1",
            ],
            environment: environment,
            captureOutput: true)
        guard result.status == 0, !result.output.isEmpty else {
            return nil
        }
        return (result.output as NSString).deletingLastPathComponent
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        captureOutput: Bool = false
    ) throws -> (status: Int32, output: String) {
        var actions = posix_spawn_file_actions_t()
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw HarnessFailure.process("posix_spawn actions init failed")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var descriptors = [Int32](repeating: -1, count: 2)
        if captureOutput {
            guard descriptors.withUnsafeMutableBufferPointer({
                pipe($0.baseAddress!)
            }) == 0,
            posix_spawn_file_actions_adddup2(
                &actions, descriptors[1], STDOUT_FILENO) == 0,
            posix_spawn_file_actions_addclose(
                &actions, descriptors[0]) == 0,
            posix_spawn_file_actions_addclose(
                &actions, descriptors[1]) == 0
            else {
                throw HarnessFailure.process("output pipe setup failed")
            }
        }

        let argv = ([executable] + arguments).map {
            $0.withCString(strdup)
        } + [nil]
        let environmentPointers = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .map { $0.withCString(strdup) } + [nil]
        defer {
            for pointer in argv {
                if let pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
            for pointer in environmentPointers {
                if let pointer { free(UnsafeMutableRawPointer(pointer)) }
            }
        }

        var processID = pid_t()
        let launchStatus = argv.withUnsafeBufferPointer { arguments in
            environmentPointers.withUnsafeBufferPointer { environment in
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    nil,
                    UnsafeMutablePointer(
                        mutating: arguments.baseAddress!),
                    UnsafeMutablePointer(
                        mutating: environment.baseAddress!))
            }
        }
        guard launchStatus == 0 else {
            throw HarnessFailure.process(
                "could not launch \(executable): \(launchStatus)")
        }

        let output: String
        if captureOutput {
            close(descriptors[1])
            let handle = FileHandle(
                fileDescriptor: descriptors[0],
                closeOnDealloc: true)
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            output = ""
        }

        var waitStatus: Int32 = 0
        while waitpid(processID, &waitStatus, 0) == -1 {
            guard errno == EINTR else {
                throw HarnessFailure.process("waitpid failed: \(errno)")
            }
        }
        let signal = waitStatus & 0x7f
        return (
            signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal,
            output)
    }
}
