import Foundation

struct Doctor {
    let context: WorkspaceContext
    let contract: BuildContract

    func run() throws {
        var failures = 0
        print("Nucleus workspace build contract v\(contract.schemaVersion)")

        failures += checkPrefix("Swift", command: "swift", arguments: ["--version"], prefix: "Swift version \(contract.toolchain.swiftVersionPrefix)")
        failures += checkMajor("Clang", command: "clang", arguments: ["--version"], expected: contract.toolchain.clangMajor)
        failures += checkMinimum("CMake", command: "cmake", arguments: ["--version"], minimum: contract.tools.cmakeMinimum)
        failures += checkMinimum("Ninja", command: "ninja", arguments: ["--version"], minimum: contract.tools.ninjaMinimum)
        failures += checkNode()
        failures += checkExact("Yarn", command: "corepack", arguments: ["yarn", "--version"], expected: contract.tools.yarnVersion)
        failures += checkExact("Bun", command: "bun", arguments: ["--version"], expected: contract.tools.bunVersion)
        failures += checkMinimum("Python", command: "python3", arguments: ["-c", "import platform; print(platform.python_version())"], minimum: contract.tools.pythonMinimum)
        failures += checkPythonPackage("Jinja2", package: "jinja2", minimum: contract.tools.jinja2Minimum)
        failures += checkPythonPackage("MarkupSafe", package: "markupsafe", minimum: contract.tools.markupsafeMinimum)

        failures += checkPkgConfig("ICU", module: "icu-uc", minimum: contract.libraries.icuMinimum)
        failures += checkPkgConfig("libevent", module: "libevent", minimum: contract.libraries.libeventMinimum)
        failures += checkPkgConfig("OpenSSL", module: "openssl", minimum: contract.libraries.opensslMinimum)
        failures += checkPkgConfig("Vulkan", module: "vulkan", minimum: contract.libraries.vulkanMinimum)
        failures += checkPkgConfig("fontconfig", module: "fontconfig", minimum: contract.libraries.fontconfigMinimum)
        failures += checkPkgConfig("FreeType", module: "freetype2", minimum: contract.libraries.freetypeMinimum)

        guard failures == 0 else { throw WorkspaceFailure.message("build contract has \(failures) violation(s)") }
        print("doctor: build contract satisfied")
    }

    private func output(_ command: String, _ arguments: [String]) -> String? {
        try? context.run(command, arguments, capture: true)
    }

    private func checkPrefix(_ name: String, command: String, arguments: [String], prefix: String) -> Int {
        guard let value = output(command, arguments), value.hasPrefix(prefix) else {
            print("  MISMATCH \(name): expected prefix '\(prefix)'")
            return 1
        }
        print("  ok       \(name): \(value.split(separator: "\n").first ?? "")")
        return 0
    }

    private func checkMajor(_ name: String, command: String, arguments: [String], expected: Int) -> Int {
        guard let value = output(command, arguments),
              let firstLine = value.split(separator: "\n").first,
              let version = try? SemanticVersion(String(firstLine.drop { !$0.isNumber })),
              version.components.first == expected else {
            print("  MISMATCH \(name): expected major \(expected)")
            return 1
        }
        print("  ok       \(name): \(version)")
        return 0
    }

    private func checkMinimum(_ name: String, command: String, arguments: [String], minimum: String) -> Int {
        guard let value = output(command, arguments),
              let firstLine = value.split(separator: "\n").first,
              let actual = try? SemanticVersion(String(firstLine.drop { !$0.isNumber })),
              let required = try? SemanticVersion(minimum), actual >= required else {
            print("  MISMATCH \(name): requires >= \(minimum)")
            return 1
        }
        print("  ok       \(name): \(actual)")
        return 0
    }

    private func checkExact(_ name: String, command: String, arguments: [String], expected: String) -> Int {
        guard let value = output(command, arguments), value == expected else {
            print("  MISMATCH \(name): expected \(expected), found \(output(command, arguments) ?? "missing")")
            return 1
        }
        print("  ok       \(name): \(value)")
        return 0
    }

    private func checkNode() -> Int {
        guard let value = output("node", ["-p", "process.versions.node"]),
              let version = try? SemanticVersion(value), let major = version.components.first,
              contract.tools.nodeAllowedMajors.contains(major) || major >= contract.tools.nodeMinimumFutureMajor else {
            print("  MISMATCH Node: allowed majors \(contract.tools.nodeAllowedMajors) or >= \(contract.tools.nodeMinimumFutureMajor)")
            return 1
        }
        print("  ok       Node: \(version)")
        return 0
    }

    private func checkPythonPackage(_ name: String, package: String, minimum: String) -> Int {
        checkMinimum(name, command: "python3", arguments: ["-c", "import importlib.metadata as m; print(m.version('\(package)'))"], minimum: minimum)
    }

    private func checkPkgConfig(_ name: String, module: String, minimum: String) -> Int {
        checkMinimum(name, command: "pkg-config", arguments: ["--modversion", module], minimum: minimum)
    }
}
