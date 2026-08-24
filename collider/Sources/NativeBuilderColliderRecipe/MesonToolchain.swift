import ColliderCore

/// How a meson build for a Linux target is configured inside the builder
/// guest, and how a build directory is kept matched to that configuration.
///
/// Meson needs the target sysroot in four places: the compiler launch
/// arguments, `sys_root` for pkg-config, the libc++ include root, and the
/// libc++ library root. All four derive from `NucleusLinuxABI.sdkDirectoryName`
/// here, because checking a machine file into the worktree wrote them a second
/// time as literals and moving the ABI baseline moved only the derived copy.
/// The compiler then took `--sysroot` from the file and `-isystem` from the
/// command line, and no header search satisfies that pair. Command-line `-D`
/// options replace a machine file's `[built-in options]` rather than merging
/// with them, so the half naming the sysroot was the half that lost.
package enum MesonToolchain {

    /// The configuration document lives inside the build directory it
    /// configured, so a directory always carries the description it was set up
    /// from. For a cross build it is also the meson cross file.
    package static let documentName = "nucleus-configuration.ini"

    /// The compiler and linker options a build for `target` needs, spelled as
    /// meson command-line options.
    ///
    /// This is the delivery a native build uses. A cross build takes the same
    /// options through the machine file instead, because a cross build also
    /// needs `[binaries]` and `[properties]`, which have no command-line form.
    package static func compilerOptionArguments(
        for target: NativeLinuxTarget
    ) -> [String] {
        [
            "-Dcpp_args=" + mesonArray(compilerArguments(for: target)),
            "-Dc_link_args=" + mesonArray(cLinkArguments(for: target)),
            "-Dcpp_link_args=" + mesonArray(cxxLinkArguments(for: target)),
        ]
    }

    /// The meson cross file for `target`, describing the toolchain that
    /// produces it from the ARM64 builder guest.
    package static func crossFile(for target: NativeLinuxTarget) -> String {
        let sysroot = target.containerSwiftSDKRoot
        let pkgConfigLibraryDirectories = [
            "/usr/lib/\(target.gnuArchitecture)/pkgconfig",
            "/usr/share/pkgconfig",
        ]
        return """
            [binaries]
            c = \(mesonArray(["clang", "--target=\(target.targetTriple)", "--sysroot=\(sysroot)"]))
            cpp = \(mesonArray(["clang++", "--target=\(target.targetTriple)", "--sysroot=\(sysroot)"]))
            ar = '/opt/swift/usr/bin/llvm-ar'
            pkg-config = 'pkg-config'

            [host_machine]
            system = 'linux'
            cpu_family = '\(target.mesonCPUFamily)'
            cpu = '\(target.mesonCPUFamily)'
            endian = 'little'

            [properties]
            sys_root = '\(sysroot)'
            pkg_config_libdir = \(mesonArray(pkgConfigLibraryDirectories))

            [built-in options]
            c_args = \(mesonArray(fallbackIncludeArguments(for: target)))
            cpp_args = \(mesonArray(compilerArguments(for: target) + fallbackIncludeArguments(for: target)))
            c_link_args = \(mesonArray(cLinkArguments(for: target)))
            cpp_link_args = \(mesonArray(cxxLinkArguments(for: target)))
            """
    }

    private static func compilerArguments(
        for target: NativeLinuxTarget
    ) -> [String] {
        ["-stdlib=libc++", "-nostdinc++", "-isystem" + target.containerLibCXXIncludeRoot]
    }

    private static func cLinkArguments(for target: NativeLinuxTarget) -> [String] {
        ["-fuse-ld=lld", "-L" + target.containerLibCXXLibraryRoot]
    }

    private static func cxxLinkArguments(for target: NativeLinuxTarget) -> [String] {
        ["-stdlib=libc++"] + cLinkArguments(for: target)
    }

    /// The builder guest's own headers, searched only after the sysroot's.
    ///
    /// A cross build reaches for these when the sysroot does not carry a header
    /// the source expects; a native build has them on the default search path
    /// already, which is why they appear in the cross file rather than in the
    /// options every target passes.
    private static func fallbackIncludeArguments(
        for target: NativeLinuxTarget
    ) -> [String] {
        ["-idirafter/usr/include", "-idirafter/usr/include/\(target.gnuArchitecture)"]
    }

    private static func mesonArray(_ elements: [String]) -> String {
        "[" + elements.map { "'" + $0 + "'" }.joined(separator: ", ") + "]"
    }
}

/// A meson build directory, the configuration that produced it, and the shell
/// that keeps the two matched.
///
/// A build directory is a function of the configuration it was set up from.
/// Rather than reason about which parts of a configuration `--reconfigure`
/// re-reads, a directory whose recorded configuration differs from the current
/// one is discarded and set up again, and a directory whose configuration is
/// unchanged is left alone for meson's own incremental machinery.
package struct MesonBuildDirectory: Sendable {
    /// Which toolchain a build that is not cross-compiling uses.
    ///
    /// A cross build has no choice and always targets the Nucleus sysroot,
    /// because the builder guest's own toolchain cannot produce the target at
    /// all. A native build does have a choice, and the two consumers make it
    /// differently: gfxstream links into Nucleus binaries and must share their
    /// libc++, while Wayland produces a build-time SDK for libraries Nucleus
    /// never ships and takes the guest's own toolchain.
    package enum NativeToolchain: Sendable {
        case guestDefault
        case nucleusSysroot
    }

    package let path: String
    package let sourcePath: String
    package let target: NativeLinuxTarget
    package let options: [String]
    package let nativeToolchain: NativeToolchain

    package init(
        path: String,
        source sourcePath: String,
        target: NativeLinuxTarget,
        nativeToolchain: NativeToolchain,
        options: [String]
    ) {
        self.path = path
        self.sourcePath = sourcePath
        self.target = target
        self.nativeToolchain = nativeToolchain
        self.options = options
    }

    package var documentPath: String {
        path + "/" + MesonToolchain.documentName
    }

    package var configureArguments: [String] {
        var arguments = ["meson", "setup", path, sourcePath] + options
        if target.isCrossCompiledInBuilder {
            arguments.append("--cross-file=" + documentPath)
        } else if nativeToolchain == .nucleusSysroot {
            arguments += MesonToolchain.compilerOptionArguments(for: target)
        }
        return arguments
    }

    /// The document recording what this directory was configured from. A cross
    /// build's document is its machine file; a native build's records only the
    /// configure command, which is the whole of what meson was told.
    package var documentContent: String {
        let configuration = configureArguments.joined(separator: " ")
        let header = "# nucleus-configuration: \(configuration)"
        guard target.isCrossCompiledInBuilder else { return header }
        return header + "\n" + MesonToolchain.crossFile(for: target)
    }

    /// Shell that materializes the configuration document, discards a build
    /// directory set up from a different one, and configures the directory
    /// when it is not configured yet.
    ///
    /// The document is written beside meson's own state inside the build
    /// directory, so the two are discarded together and can never disagree.
    /// The directory's contents are removed rather than the directory itself,
    /// because a build directory is sometimes the persistent workspace's own
    /// mount point.
    package var setupScript: String {
        let pending = "/tmp/nucleus-meson-configuration.ini"
        return """
            set -eu
            mkdir -p \(shellQuoted(path))
            cat > \(shellQuoted(pending)) <<'NUCLEUS_MESON_CONFIGURATION'
            \(documentContent)
            NUCLEUS_MESON_CONFIGURATION
            if ! cmp -s \(shellQuoted(pending)) \(shellQuoted(documentPath)); then
                find \(shellQuoted(path)) -mindepth 1 -delete
                cp \(shellQuoted(pending)) \(shellQuoted(documentPath))
            fi
            if [ ! -f \(shellQuoted(path + "/meson-private/coredata.dat")) ]; then
                \(configureArguments.map(shellQuoted).joined(separator: " ")) \\
                    || { status=$?; cat \(shellQuoted(path + "/meson-logs/meson-log.txt")); exit $status; }
            fi
            """
    }

    private func shellQuoted(_ argument: String) -> String {
        "'"
            + argument.split(separator: "'", omittingEmptySubsequences: false)
            .joined(separator: "'\\''") + "'"
    }
}
