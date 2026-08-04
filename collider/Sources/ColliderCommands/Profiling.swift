import Foundation
import SystemPackage

struct TracyTools {
    let context: WorkspaceContext

    func buildReceivers() async throws {
        let build = context.layout.tracyBuild
        let relativeSource = "swift-tracy/third-party/tracy"
        let source = context.layout.root.appending(relativeSource)
        guard
            FileManager.default.fileExists(
                atPath: source.appending("public/TracyClient.cpp").string)
        else {
            throw WorkspaceFailure.message(
                "Tracy sources are absent; rerun ./collider-setup.sh")
        }
        // The pre-submodule receiver builder cloned Tracy under `source/` and its
        // CMake caches permanently record that path. Remove those ignored build
        // artifacts once so CMake never mixes the old clone with the submodule.
        for legacy in ["source", "build-tracy-capture", "build-tracy-csvexport"] {
            let path = build.appending(legacy)
            if FileManager.default.fileExists(atPath: path.string) {
                try FileManager.default.removeItem(
                    at: URL(fileURLWithPath: path.string))
            }
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: build.string),
            withIntermediateDirectories: true)
        for (name, subdirectory) in [
            ("tracy-capture", "capture"), ("tracy-csvexport", "csvexport"),
        ] {
            let toolBuild = build.appending("build-submodule-" + name)
            var environment = context.environment
            environment["CPM_SOURCE_CACHE"] = build.appending(".cpm-cache").string
            let environmentContext = WorkspaceContext(root: context.root, environment: environment)
            try await environmentContext.run(
                "cmake",
                [
                    "-S", source.appending(subdirectory).string, "-B", toolBuild.string,
                    "-DCMAKE_BUILD_TYPE=Release", "-DDOWNLOAD_CAPSTONE=ON",
                    "-DCMAKE_CXX_FLAGS=-stdlib=libc++",
                    "-DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -static-libgcc",
                ])
            try await environmentContext.run(
                "cmake", ["--build", toolBuild.string, "--parallel", "--target", name])
            let output = build.appending(name)
            if FileManager.default.fileExists(atPath: output.string) {
                try FileManager.default.removeItem(
                    at: URL(fileURLWithPath: output.string))
            }
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: toolBuild.appending(name).string),
                to: URL(fileURLWithPath: output.string))
        }
        print("built Tracy receivers at \(build.string)")
    }
}
