struct AndroidCommand {
    let context: WorkspaceContext

    func run(
        _ arguments: ArraySlice<String>,
        dryRun: Bool = false,
        explain: Bool = false,
        verbose: Bool = false,
        json: Bool = false
    ) throws {
        guard let command = arguments.first else { throw WorkspaceFailure.message(usage) }
        let rest = Array(arguments.dropFirst())
        let registry = ComponentRegistry(context: context)
        switch command {
        case "build":
            try registry.buildAndroidHost(
                gradleArguments: rest,
                dryRun: dryRun,
                explain: explain,
                verbose: verbose,
                json: json)
        case "native":
            guard rest.isEmpty else {
                throw WorkspaceFailure.message("android native does not accept arguments\n\n\(usage)")
            }
            try registry.buildAndroidNative(
                dryRun: dryRun,
                explain: explain,
                verbose: verbose,
                json: json)
        case "verify":
            guard rest.count <= 1 else {
                throw WorkspaceFailure.message(
                    "android verify accepts at most one library path\n\n\(usage)")
            }
            try registry.validateAndroidHost(
                library: rest.first,
                dryRun: dryRun,
                explain: explain,
                verbose: verbose,
                json: json)
        case "help", "--help", "-h":
            print(usage)
        default:
            throw WorkspaceFailure.message("unknown android command '\(command)'\n\n\(usage)")
        }
    }

    private var usage: String {
        """
        Usage: tools/collider android <command>

          build [gradle arguments]  Build and verify the Android host (default: verifyDebug)
          native                    Cross-compile and verify the Swift Android host library
          verify [library]         Verify the Android host ELF and JNI contract
          Swift toolchain and Android SDK generations are managed together by:
            tools/collider toolchain rebuild
        """
    }
}
