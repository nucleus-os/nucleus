import PackagePlugin
import Foundation

// Command plugin: builds the RN-curated C++ runtime layer on host — glog (its own
// CMake) and the folly_runtime + ReactCommon jsi superbuild (swiftpm/cmake/
// reactnative, RN's curated source lists). Depends on the leaf libs from
// build-rn-support (fmt + double-conversion) being built first; the full chain:
//   swift package build-hermes      --allow-writing-to-package-directory
//   swift package build-rn-support  --allow-writing-to-package-directory
//   swift package build-rn-cxx      --allow-writing-to-package-directory
//
// Output (gitignored, persistent):
//   .rn-build/glog/{libglog.a, glog/*.h (generated)}
//   .rn-build/reactnative/{libfolly_runtime.a, libjsi.a}
//
// Built with clang++ (libc++) + PIC. Deps are the vendored submodules
// (third-party/{folly,glog,fast_float,fmt,double-conversion}) + the fetched boost
// headers (third-party/boost) + RN's ReactCommon/jsi.

@main
struct BuildReactNativeCxx: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL.path
        let rn = "\(root)/third-party/react-native/packages/react-native"

        // double-conversion 1.1.6 keeps headers flat in src/; folly includes
        // <double-conversion/…>, so expose a prefix symlink.
        let dcPrefix = "\(root)/.rn-build/include"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dcPrefix, withIntermediateDirectories: true)
        let dcLink = "\(dcPrefix)/double-conversion"
        try? fm.removeItem(atPath: dcLink)
        try fm.createSymbolicLink(atPath: dcLink, withDestinationPath: "\(root)/third-party/double-conversion/src")

        let common = "-DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++"

        // glog: its own CMake (1.1.6-era min version needs the policy floor).
        try run("""
        set -e
        if [ ! -f "\(root)/.rn-build/glog/build.ninja" ]; then
            cmake -S "\(root)/third-party/glog" -B "\(root)/.rn-build/glog" -G Ninja \(common) \
                -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DWITH_GFLAGS=OFF -DBUILD_TESTING=OFF \
                -DHAVE_EXECINFO_H=0 -DHAVE_UNWIND_H=0
        fi
        # Disable glog's stacktrace backends (execinfo + unwind). Its utilities.cc
        # otherwise runs a load-time _Unwind_Backtrace that segfaults libunwind when
        # glog is dlopen'd in a test bundle (the .so's eh_frame isn't registered yet
        # during _dl_init). folly only needs glog's LOG(), not stacktraces — matching
        # RN's mobile glog.
        ninja -C "\(root)/.rn-build/glog" glog
        """)

        // The full RN C++ stack: folly_runtime + jsi + react_native (ReactCommon)
        // + react_cxx_platform + yogacore (deps wired by absolute -D include paths).
        try run("""
        set -e
        cmake -S "\(root)/../core/swiftpm/cmake/reactnative" -B "\(root)/.rn-build/reactnative" -G Ninja \(common) \
                -DFOLLY_DIR="\(root)/third-party/folly" \
                -DBOOST_INC="\(root)/third-party/boost" \
                -DGLOG_INC="\(root)/.rn-build/glog" \
                -DGLOG_SRC_INC="\(root)/third-party/glog/src" \
                -DDOUBLE_CONVERSION_INC="\(dcPrefix)" \
                -DFMT_INC="\(root)/third-party/fmt/include" \
                -DFAST_FLOAT_INC="\(root)/third-party/fast_float/include" \
                -DJSI_DIR="\(rn)/ReactCommon/jsi" \
                -DRN_ROOT="\(rn)" \
                -DRN_CODEGEN_ROOT="\(root)/.rn-build/generated" \
                -DHERMES_DIR="\(root)/third-party/hermes"
        ninja -C "\(root)/.rn-build/reactnative" folly_runtime jsi react_native react_cxx_platform yogacore
        """)

        Diagnostics.remark("Built RN C++ stack: folly_runtime + jsi + react_native + react_cxx_platform + yogacore")
    }

    private func run(_ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ProcessInfo.processInfo.environment
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            Diagnostics.error("RN C++ build failed (exit \(p.terminationStatus))")
            throw BuildError.failed
        }
    }
}

enum BuildError: Error { case failed }
