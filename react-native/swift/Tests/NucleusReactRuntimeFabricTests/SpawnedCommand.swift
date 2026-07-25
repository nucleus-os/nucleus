import Foundation
import Glibc

struct SpawnedCommandResult {
    let status: Int32
    let output: String
}

enum SpawnedCommand {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        captureOutput: Bool = false
    ) throws -> SpawnedCommandResult {
        var actions = unsafe posix_spawn_file_actions_t()
        guard unsafe posix_spawn_file_actions_init(&actions) == 0 else {
            throw commandError("could not initialize process file actions")
        }
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }

        var descriptors = [Int32](repeating: -1, count: 2)
        if captureOutput {
            guard descriptors.withUnsafeMutableBufferPointer({
                unsafe pipe($0.baseAddress!)
            }) == 0 else {
                throw commandError("could not create process output pipe")
            }
            guard
                unsafe posix_spawn_file_actions_adddup2(
                    &actions, descriptors[1], STDOUT_FILENO) == 0,
                unsafe posix_spawn_file_actions_addclose(
                    &actions, descriptors[0]) == 0,
                unsafe posix_spawn_file_actions_addclose(
                    &actions, descriptors[1]) == 0
            else {
                close(descriptors[0])
                close(descriptors[1])
                throw commandError("could not configure process output pipe")
            }
        }

        let argv = unsafe ([executable] + arguments).map {
            $0.withCString { unsafe strdup($0) }
        } + [nil]
        let environmentPointers = unsafe environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .map { value in
                value.withCString { unsafe strdup($0) }
            } + [nil]
        defer {
            for unsafe pointer in unsafe argv {
                if let pointer = unsafe pointer {
                    unsafe free(UnsafeMutableRawPointer(pointer))
                }
            }
            for unsafe pointer in unsafe environmentPointers {
                if let pointer = unsafe pointer {
                    unsafe free(UnsafeMutableRawPointer(pointer))
                }
            }
        }

        var processID = pid_t()
        let launchStatus = argv.withUnsafeBufferPointer { argvBuffer in
            environmentPointers.withUnsafeBufferPointer { environmentBuffer in
                unsafe posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    nil,
                    UnsafeMutablePointer(
                        mutating: argvBuffer.baseAddress!),
                    UnsafeMutablePointer(
                        mutating: environmentBuffer.baseAddress!))
            }
        }
        guard launchStatus == 0 else {
            if captureOutput {
                close(descriptors[0])
                close(descriptors[1])
            }
            throw commandError(
                "could not launch \(executable): error \(launchStatus)")
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
        while unsafe waitpid(processID, &waitStatus, 0) == -1 {
            guard errno == EINTR else {
                throw commandError(
                    "waitpid failed for \(executable): errno \(errno)")
            }
        }
        let signal = waitStatus & 0x7f
        let status = signal == 0
            ? (waitStatus >> 8) & 0xff
            : 128 + signal
        return SpawnedCommandResult(status: status, output: output)
    }

    private static func commandError(_ description: String) -> NSError {
        NSError(
            domain: "NucleusReactRuntimeFabricTests.SpawnedCommand",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }
}
