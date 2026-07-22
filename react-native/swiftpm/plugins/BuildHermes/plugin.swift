import PackagePlugin
import Foundation

// Command plugin: drives upstream Hermes's own CMake + Ninja to build the lean
// JS VM runtime plus hermesc (the bytecode compiler). It is the first link in the
// React Native C/C++ chain and follows the same upstream-build-system posture as
// BuildSkia (the Zig build's native Hermes compile was a reimplementation).
//
//   swift package build-hermes --allow-writing-to-package-directory
//
// Built STATIC (BUILD_SHARED_LIBS=OFF, HERMES_BUILD_SHARED_JSI=OFF) and
// position-independent (CMAKE_POSITION_INDEPENDENT_CODE=ON, so the archives link
// into both the PIE compositor and the swift-testing .so test bundles). Hermes
// emits ~30 static archives (the lean VM + jsi + their llvh/dtoa/zip deps); we
// merge them into one libhermes_lean_combined.a so consumers link a single
// archive with no libhermes_lean.so / libjsi.so (hence no rpath). ICU stays a
// system shared lib, resolved at runtime from the loader path.
//
// Output (gitignored, persistent so cmake/ninja stay incremental):
//   .rn-build/hermes/{libhermes_lean_combined.a, bin/hermesc}
//
// Source: third-party/hermes — a vanilla git submodule of facebook/hermes pinned
// to the tag React Native 0.86.0 pins in sdks/.hermesversion (hermes-v0.17.0), so
// the RN C++ deps are vendored independently of the Zig package manager. Requires
// the dev shell
// (cmake/ninja/clang + ICU via pkg-config). Two host-Linux fixes the de-risk
// found, both
// encoded below: point CMake at ICU (icu-uc, now a dev-shell dep), and put libc++
// on LD_LIBRARY_PATH for the build-time hermesc invocation (clang defaults to
// libc++; the Swift toolchain provides it) — the same libc++ detail BuildSkia hit.

@main
struct BuildHermes: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL.path
        let src = "\(root)/third-party/hermes"
        let build = "\(root)/.rn-build/hermes"

        let script = """
        set -e
        ICU_INC=$(pkg-config --variable=includedir icu-uc)
        ICU_LIB=$(pkg-config --variable=libdir icu-uc)
        find_library() {
            candidate="$ICU_LIB/$1"
            [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return; }
            clang -print-file-name="$1"
        }
        ICU_UC=$(find_library libicuuc.so)
        ICU_I18N=$(find_library libicui18n.so)
        ICU_DATA=$(find_library libicudata.so)
        LIBCXX=$(dirname "$(clang++ -print-file-name=libc++.so.1)")
        # Always (re)configure: cmake is idempotent on a no-change build and this
        # picks up flag deltas (e.g. a prior shared build dir). Cheap re-gen; ninja
        # stays incremental.
        cmake -S "\(src)" -B "\(build)" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DHERMES_BUILD_SHARED_JSI=OFF \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DHERMES_BUILD_APPLE_FRAMEWORK=OFF \
            -DHERMES_ENABLE_DEBUGGER=OFF \
            -DHERMES_ENABLE_INTL=ON \
            -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
            -DICU_INCLUDE_DIR="$ICU_INC" \
            -DICU_UC_LIBRARY_RELEASE="$ICU_UC" \
            -DICU_I18N_LIBRARY_RELEASE="$ICU_I18N" \
            -DICU_DATA_LIBRARY_RELEASE="$ICU_DATA" \
            -DICU_ROOT="$ICU_INC/.."
        # hermesvmlean → libhermes_lean.a; jsi → libjsi.a; hermesc → the compiler.
        LD_LIBRARY_PATH="$LIBCXX" ninja -C "\(build)" hermesvmlean jsi hermesc

        # Merge the lean VM + jsi + their transitive static deps into one archive
        # (the linker pulls only referenced members; combining all is correct and
        # avoids enumerating the ~30-archive closure). Exclude the gtest archives
        # and the previous combined output.
        COMBINED="\(build)/libhermes_lean_combined.a"
        MRI="\(build)/.combine.mri"
        rm -f "$COMBINED"
        echo "create $COMBINED" > "$MRI"
        find "\(build)" -name '*.a' ! -name 'libgtest*' ! -name 'libhermes_lean_combined.a' \
            | sed 's/^/addlib /' >> "$MRI"
        printf 'save\\nend\\n' >> "$MRI"
        ar -M < "$MRI"
        ranlib "$COMBINED"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("Hermes build failed (exit \(process.terminationStatus))")
            throw BuildError.failed
        }
        Diagnostics.remark("Built Hermes (lean VM + hermesc) into .rn-build/hermes")
    }
}

enum BuildError: Error { case failed }
