import Foundation
import PackagePlugin

@main
struct GenerateApexManifestPlugin: CommandPlugin {
    private enum Mode: String {
        case publish = "--publish"
        case verify = "--verify"
    }

    private enum Failure: Error, CustomStringConvertible {
        case invalidArguments
        case generationFailed(String)
        case missingGeneratedSource(String)
        case generatedSourceDrift

        var description: String {
            switch self {
            case .invalidArguments:
                "expected exactly one argument: --publish or --verify"
            case .generationFailed(let output):
                "APEX manifest protobuf generation failed:\n\(output)"
            case .missingGeneratedSource(let path):
                "APEX manifest protobuf generator did not produce \(path)"
            case .generatedSourceDrift:
                """
                checked-in APEX manifest Swift source differs from SwiftProtobuf output; run \
                `collider generate android-runtime`
                """
            }
        }
    }

    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        guard arguments.count == 1,
            let argument = arguments.first,
            let mode = Mode(rawValue: argument)
        else {
            throw Failure.invalidArguments
        }

        let packageRoot = context.package.directoryURL
        let protoRoot = packageRoot.appending(path: "android-runtime/Protos")
        let proto = protoRoot.appending(path: "apex_manifest.proto")
        let destination = packageRoot.appending(
            path:
                "android-runtime/Sources/NucleusAndroidContainerContract/apex_manifest.pb.swift")
        let candidateRoot = context.pluginWorkDirectoryURL.appending(path: "candidate")
        let candidate = candidateRoot.appending(path: "apex_manifest.pb.swift")
        let files = FileManager.default

        try? files.removeItem(at: candidateRoot)
        try files.createDirectory(
            at: candidateRoot,
            withIntermediateDirectories: true)

        let protoc = try context.tool(named: "protoc").url
        let generator = try context.tool(named: "protoc-gen-swift").url
        let process = Process()
        process.executableURL = protoc
        process.arguments = [
            "--plugin=protoc-gen-swift=\(generator.path(percentEncoded: false))",
            "--proto_path=\(protoRoot.path(percentEncoded: false))",
            "--swift_opt=Visibility=Internal",
            "--swift_out=\(candidateRoot.path(percentEncoded: false))",
            proto.path(percentEncoded: false),
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.generationFailed(
                String(decoding: outputData, as: UTF8.self))
        }
        guard files.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            throw Failure.missingGeneratedSource(candidate.path(percentEncoded: false))
        }

        let generated = try Data(contentsOf: candidate)
        switch mode {
        case .publish:
            if (try? Data(contentsOf: destination)) != generated {
                try generated.write(to: destination, options: .atomic)
            }
            print("Generated \(destination.path(percentEncoded: false))")
        case .verify:
            guard (try? Data(contentsOf: destination)) == generated else {
                throw Failure.generatedSourceDrift
            }
            print("Verified \(destination.path(percentEncoded: false))")
        }
    }
}
