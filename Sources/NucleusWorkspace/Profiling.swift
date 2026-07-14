import Foundation

struct ProfilingCommand {
    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        if arguments.first == "receivers" {
            try buildReceivers()
            return
        }
        try ProfileCapture(context: context).run(Array(arguments))
    }

    func buildReceivers() throws {
        let compositor = context.root.appendingPathComponent("compositor")
        let build = compositor.appendingPathComponent(".tracy-build")
        let relativeSource = "swift-tracy/third-party/tracy"
        let source = context.root.appendingPathComponent(relativeSource)
        let commit = try context.run(
            "git", ["rev-parse", "HEAD:\(relativeSource)"], directory: context.root, capture: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
            throw WorkspaceFailure.message("could not read the pinned Tracy submodule commit")
        }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path) else {
            throw WorkspaceFailure.message(
                "Tracy submodule is not initialized; run tools/nucleus bootstrap tracy")
        }
        let checkout = try context.run(
            "git", ["rev-parse", "HEAD"], directory: source, capture: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard checkout == commit else {
            throw WorkspaceFailure.message(
                "Tracy submodule is at \(checkout), expected pinned commit \(commit); "
                + "run git submodule update --init --recursive swift-tracy/third-party/tracy")
        }
        let stamp = build.appendingPathComponent(".built-commit")
        let capture = build.appendingPathComponent("tracy-capture")
        let csv = build.appendingPathComponent("tracy-csvexport")
        // The pre-submodule receiver builder cloned Tracy under `source/` and its
        // CMake caches permanently record that path. Remove those ignored build
        // artifacts once so CMake never mixes the old clone with the submodule.
        for legacy in ["source", "build-tracy-capture", "build-tracy-csvexport"] {
            let path = build.appendingPathComponent(legacy)
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
        if (try? String(contentsOf: stamp, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == commit,
           FileManager.default.isExecutableFile(atPath: capture.path), FileManager.default.isExecutableFile(atPath: csv.path) {
            print("tracy receivers up to date (\(commit))")
            return
        }
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        for (name, subdirectory) in [("tracy-capture", "capture"), ("tracy-csvexport", "csvexport")] {
            let toolBuild = build.appendingPathComponent("build-submodule-" + name)
            var environment = context.environment
            environment["CPM_SOURCE_CACHE"] = build.appendingPathComponent(".cpm-cache").path
            let environmentContext = WorkspaceContext(root: context.root, environment: environment)
            try environmentContext.run("cmake", ["-S", source.appendingPathComponent(subdirectory).path, "-B", toolBuild.path, "-DCMAKE_BUILD_TYPE=Release", "-DDOWNLOAD_CAPSTONE=ON", "-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc"])
            try environmentContext.run("cmake", ["--build", toolBuild.path, "--parallel", "--target", name])
            let output = build.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            try FileManager.default.copyItem(at: toolBuild.appendingPathComponent(name), to: output)
        }
        try Data((commit + "\n").utf8).write(to: stamp, options: .atomic)
        print("built Tracy receivers at \(build.path)")
    }
}
