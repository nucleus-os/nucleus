import PackagePlugin
import Foundation

// Command plugin: builds the leaf React Native C++ support libs that have clean,
// self-contained upstream builds — fmt and double-conversion — via their own
// CMake. (fast_float is header-only, so it needs no build, just its submodule
// include path; folly and glog are RN-curated and are built by RN's own CMake in
// the ReactCommon step; boost is folly's header dependency.)
//
//   swift package build-rn-support --allow-writing-to-package-directory
//
// Built with clang++ (libc++, matching folly's FOLLY_USE_LIBCPP) and PIC (these
// link into the RN shared libs downstream). Output (gitignored, persistent):
//   .rn-build/fmt/libfmt.a
//   .rn-build/double-conversion/src/libdouble-conversion.a
//
// Sources: third-party/{fmt,double-conversion} — vanilla submodules at the tags
// React Native 0.86.0 pins (fmt 12.1.0, double-conversion 1.1.6).

@main
struct BuildRNSupportLibs: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL.path

        try buildCMakeLib(
            name: "fmt",
            src: "\(root)/third-party/fmt",
            build: "\(root)/.rn-build/fmt",
            extraArgs: ["-DFMT_TEST=OFF", "-DFMT_DOC=OFF", "-DFMT_INSTALL=OFF"],
            target: "fmt"
        )
        try buildCMakeLib(
            name: "double-conversion",
            src: "\(root)/third-party/double-conversion",
            build: "\(root)/.rn-build/double-conversion",
            // double-conversion 1.1.6's cmake_minimum_required predates CMake 4.x's
            // floor; allow the old policy version (the lib itself is current).
            extraArgs: ["-DCMAKE_POLICY_VERSION_MINIMUM=3.5"],
            target: "double-conversion"
        )
        Diagnostics.remark("Built RN support libs: fmt + double-conversion into .rn-build/")
    }

    private func buildCMakeLib(name: String, src: String, build: String, extraArgs: [String], target: String) throws {
        let args = (extraArgs + [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
            "-DCMAKE_C_COMPILER=clang", "-DCMAKE_CXX_COMPILER=clang++",
        ]).joined(separator: " ")
        let script = """
        set -e
        if [ ! -f "\(build)/build.ninja" ]; then
            cmake -S "\(src)" -B "\(build)" -G Ninja \(args)
        fi
        ninja -C "\(build)" \(target)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("\(name) build failed (exit \(process.terminationStatus))")
            throw BuildError.failed
        }
    }
}

enum BuildError: Error { case failed }
