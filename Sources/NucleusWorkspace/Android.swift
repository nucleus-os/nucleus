import Foundation

struct AndroidCommand {
    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        guard let command = arguments.first else { throw WorkspaceFailure.message(usage) }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "build":
            try context.run("./gradlew", rest.isEmpty ? ["verifyDebug"] : rest, directory: context.root.appendingPathComponent("core/android"))
        case "verify":
            try verifyHostLibrary(rest.first)
        case "sdk":
            try runSDK(rest)
        case "help", "--help", "-h":
            print(usage)
        default:
            throw WorkspaceFailure.message("unknown android command '\(command)'\n\n\(usage)")
        }
    }

    private var usage: String {
        """
        Usage: tools/nucleus android <command>

          build [gradle arguments]  Build and verify the Android host (default: verifyDebug)
          verify [library]         Verify the Android host ELF and JNI contract
          sdk build [arguments]    Build the Swift Android SDK
          sdk install [arguments]  Install the locally built SDK artifact bundle
          sdk test [arguments]     Test the installed SDK without modifying it
        """
    }

    private func runSDK(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw WorkspaceFailure.message(usage) }
        let sdk = context.root.appendingPathComponent("swift-android-sdk")
        let rest = Array(arguments.dropFirst())
        let script: String
        switch command {
        case "build":
            #if os(macOS)
            script = "build-macos.sh"
            #else
            script = "build.sh"
            #endif
        case "install": script = "scripts/install-sdk.sh"
        case "test": script = "scripts/test-installed-sdk.sh"
        default: throw WorkspaceFailure.message("unknown android sdk command '\(command)'\n\n\(usage)")
        }
        // These scripts are cross-toolchain build recipes; Swift owns command
        // routing while the recipes retain shell semantics required by upstream.
        try context.run("./" + script, rest, directory: sdk)
    }

    private func verifyHostLibrary(_ suppliedPath: String?) throws {
        let core = context.root.appendingPathComponent("core")
        let library = suppliedPath.map { URL(fileURLWithPath: $0, relativeTo: context.root).standardizedFileURL }
            ?? core.appendingPathComponent("platform-android/.build/out/Products/Release-android-aarch64/libnucleus-android.so")
        let kotlin = core.appendingPathComponent("android/nucleus/src/main/kotlin/dev/nucleus/android/NucleusNative.kt")
        guard FileManager.default.fileExists(atPath: library.path) else { throw WorkspaceFailure.message("Android host library not found: \(library.path)") }
        guard let source = try? String(contentsOf: kotlin, encoding: .utf8) else { throw WorkspaceFailure.message("Kotlin JNI contract not found: \(kotlin.path)") }
        let readelf = try resolveReadelf()
        let header = try context.run(readelf, ["-h", library.path], capture: true)
        let dynamic = try context.run(readelf, ["-d", library.path], capture: true)
        let symbols = try context.run(readelf, ["-Ws", library.path], capture: true)
        var failures: [String] = []
        func check(_ description: String, _ pattern: String, in value: String, absent: Bool = false) {
            let found = value.range(of: pattern, options: .regularExpression) != nil
            if found != absent { print("  ok   \(description)") }
            else { print("  FAIL \(description)"); failures.append(description) }
        }
        print("verify-android-host: \(library.path)")
        check("ELF machine is AArch64", #"Machine:\s+AArch64"#, in: header)
        check("links libandroid.so", #"NEEDED.*\[libandroid\.so\]"#, in: dynamic)
        check("links libvulkan.so", #"NEEDED.*\[libvulkan\.so\]"#, in: dynamic)
        check("exports JNI_OnLoad", #"\bJNI_OnLoad\b"#, in: symbols)
        check("links libSwiftJava.so", #"NEEDED.*\[libSwiftJava\.so\]"#, in: dynamic)
        check("contains the static Swift runtime", #"\sFUNC\s+LOCAL\s+PROTECTED\s+\d+\s+swift_retain(?:\s|$)"#, in: symbols)
        check("does not link libswiftCore.so", #"NEEDED.*\[libswiftCore\.so\]"#, in: dynamic, absent: true)

        let functionPattern = try NSRegularExpression(pattern: #"external\s+fun\s+([A-Za-z0-9_]+)"#)
        let range = NSRange(source.startIndex..., in: source)
        let functions = functionPattern.matches(in: source, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[swiftRange])
        }
        guard !functions.isEmpty else { throw WorkspaceFailure.message("no external functions found in \(kotlin.path)") }
        for function in functions {
            check("exports NucleusNative.\(function)", "Java_dev_nucleus_android_NucleusNative_" + function, in: symbols)
        }
        let hostExports = symbols.components(separatedBy: "Java_dev_nucleus_android_AndroidHost__").count - 1
        if hostExports >= 20 { print("  ok   \(hostExports) swift-java AndroidHost thunks") }
        else { failures.append("only \(hostExports) swift-java AndroidHost thunks (expected at least 20)") }
        guard failures.isEmpty else { throw WorkspaceFailure.message("Android host verification failed:\n  " + failures.joined(separator: "\n  ")) }
        print("verify-android-host: OK")
    }

    private func resolveReadelf() throws -> String {
        if let explicit = context.environment["LLVM_READELF"], FileManager.default.isExecutableFile(atPath: explicit) { return explicit }
        let home = context.environment["NUCLEUS_ANDROID_NDK_HOME"]
            ?? context.environment["ANDROID_NDK_HOME"]
            ?? (context.environment["ANDROID_SDK_ROOT"] ?? NSHomeDirectory() + "/Android/Sdk") + "/ndk/30.0.14904198"
        let bundled = home + "/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let path = try? context.run("which", ["llvm-readelf"], capture: true)
        guard let path, !path.isEmpty else { throw WorkspaceFailure.message("llvm-readelf not found; set LLVM_READELF or NUCLEUS_ANDROID_NDK_HOME") }
        return path
    }
}
