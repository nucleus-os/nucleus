import Foundation
import PackagePlugin

@main
struct GenerateApexManifestPlugin: CommandPlugin {
    private enum Failure: Error, CustomStringConvertible {
        case invalidArguments
        case generationFailed(String)
        case missingGeneratedSource(String)

        var description: String {
            switch self {
            case .invalidArguments:
                "expected exactly one argument: --output <directory>"
            case .generationFailed(let output):
                "APEX manifest protobuf generation failed:\n\(output)"
            case .missingGeneratedSource(let path):
                "APEX manifest protobuf generator did not produce \(path)"
            }
        }
    }

    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        // Where generation writes is the caller's decision. The plugin does
        // not know the checkout destination at all: publishing there is a
        // separate act by the account that owns the checkout.
        guard arguments.count == 2, arguments[0] == "--output" else {
            throw Failure.invalidArguments
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)

        let packageRoot = context.package.directoryURL
        let protoRoot = packageRoot.appending(path: "android-runtime/Protos")
        let proto = protoRoot.appending(path: "apex_manifest.proto")
        let candidateRoot = context.pluginWorkDirectoryURL.appending(path: "candidate")
        let candidate = candidateRoot.appending(path: "apex_manifest.pb.swift")
        let generated = output.appending(path: "apex_manifest.pb.swift")
        let files = FileManager.default

        try? files.removeItem(at: candidateRoot)
        try files.createDirectory(
            at: candidateRoot,
            withIntermediateDirectories: true)
        try files.createDirectory(at: output, withIntermediateDirectories: true)

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
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.generationFailed(
                String(decoding: outputData, as: UTF8.self))
        }
        guard files.fileExists(atPath: candidate.path(percentEncoded: false)) else {
            throw Failure.missingGeneratedSource(candidate.path(percentEncoded: false))
        }

        let contents = try Data(contentsOf: candidate)
        if (try? Data(contentsOf: generated)) != contents {
            try contents.write(to: generated, options: .atomic)
        }
        print("Generated \(generated.path(percentEncoded: false))")
    }
}
