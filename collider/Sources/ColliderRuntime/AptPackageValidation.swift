import ColliderCore
import Foundation

extension ColliderRuntime {
    func validateAptPackages(
        _ validation: AptPackageValidation,
        stage: TaskID
    ) async throws {
        let contents = try String(
            contentsOf: URL(
                fileURLWithPath: validation.packageList.string),
            encoding: .utf8)
        let packages = contents.split(separator: "\n").compactMap {
            raw -> String? in
            let value = raw.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces)
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        guard !packages.isEmpty else {
            throw RuntimeFailure.invalidOutput(
                "apt package list is empty: \(validation.packageList)")
        }
        var missing: [String] = []
        for package in packages {
            let result = try await execute(
                CommandSpec(
                    executable: .named("dpkg-query"),
                    arguments: [
                        "--show",
                        "--showformat=${db:Status-Abbrev}",
                        package,
                    ],
                    workingDirectory:
                        validation.packageList.removingLastComponent(),
                    environment: validation.environment,
                    output: .captured(limit: 64 * 1_024)),
                stage: stage)
            if result.status != 0
                || !result.standardOutput.hasPrefix("ii ")
            {
                missing.append(package)
            }
        }
        guard missing.isEmpty else {
            throw RuntimeFailure.invalidOutput(
                "missing Chromium host packages: "
                    + missing.joined(separator: ", ")
                    + "\ninstall them with:\n  sudo apt-get install -y "
                    + missing.joined(separator: " "))
        }
    }
}
