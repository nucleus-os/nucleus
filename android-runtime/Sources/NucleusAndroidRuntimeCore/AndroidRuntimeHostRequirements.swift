import Foundation
import Glibc

public func resolveAndroidRuntimeHostConfiguration<
    RuntimeHost: AndroidRuntimeHost
>(
    using host: RuntimeHost,
    environment: [String: String]
) async throws -> AndroidRuntimeHostConfiguration {
    var failures: [String] = []
    for tool in [
        "sudo", "mount", "umount", "lxc-start", "lxc-stop",
        "lxc-attach", "newuidmap", "newgidmap", "systemd-run",
        "aa-enabled", "apparmor_parser", "modprobe", "modinfo",
        "uname", "journalctl", "fsverity", "sha256sum", "python3",
    ]
    where resolveAndroidRuntimeExecutable(
        tool,
        environment: environment
    ) == nil {
        failures.append("missing host tool: \(tool)")
    }

    let mountedFileSystems =
        (try? String(
            contentsOfFile: "/proc/filesystems",
            encoding: .utf8)) ?? ""
    for requirement in [
        (
            fileSystem: "binder",
            module: "binder_linux",
            failure:
                "kernel neither exposes binderfs nor provides "
                + "the binder_linux module"
        ),
        (
            fileSystem: "erofs",
            module: "erofs",
            failure:
                "kernel neither exposes EROFS nor provides "
                + "the erofs module"
        ),
        (
            fileSystem: "bpf",
            module: "",
            failure:
                "kernel does not expose the BPF filesystem required "
                + "for per-instance BPF delegation"
        ),
    ] {
        let available =
            mountedFileSystems
            .split(whereSeparator: \.isNewline)
            .contains {
                $0.split(whereSeparator: \.isWhitespace).last
                    == Substring(requirement.fileSystem)
            }
        if !available {
            if requirement.module.isEmpty {
                failures.append(requirement.failure)
            } else {
                do {
                    _ = try await host.run(
                        "modinfo",
                        [requirement.module],
                        capture: true)
                } catch {
                    failures.append(requirement.failure)
                }
            }
        }
    }
    for module in androidRuntimeRequiredKernelModules {
        do {
            _ = try await host.run(
                "modinfo",
                [module],
                capture: true)
        } catch {
            failures.append(
                "kernel does not provide required Android module: "
                    + module)
        }
    }

    let controllers =
        (try? String(
            contentsOfFile: "/sys/fs/cgroup/cgroup.controllers",
            encoding: .utf8)) ?? ""
    if controllers.isEmpty {
        failures.append("unified cgroup v2 is not mounted")
    }
    if resolveAndroidRuntimeExecutable(
        "aa-enabled",
        environment: environment
    ) != nil {
        do {
            _ = try await host.run("aa-enabled", ["--quiet"])
        } catch {
            failures.append("AppArmor is not enabled")
        }
    }

    let kernelRelease: String?
    do {
        kernelRelease = try await host.run(
            "uname",
            ["--kernel-release"],
            capture: true)
    } catch {
        kernelRelease = nil
        failures.append("could not determine the running kernel release")
    }
    let kernelConfiguration = kernelRelease.flatMap {
        resolveAndroidRuntimeKernelConfiguration(release: $0)
    }
    if kernelConfiguration == nil {
        failures.append(
            "the running kernel configuration is unavailable")
    }

    let userRange = androidRuntimeSubordinateRange(
        user: "root",
        contents: (try? String(
            contentsOfFile: "/etc/subuid",
            encoding: .utf8)) ?? "")
    let groupRange = androidRuntimeSubordinateRange(
        user: "root",
        contents: (try? String(
            contentsOfFile: "/etc/subgid",
            encoding: .utf8)) ?? "")
    if userRange == nil {
        failures.append(
            "root has no subordinate UID range for the LXC manager")
    }
    if groupRange == nil {
        failures.append(
            "root has no subordinate GID range for the LXC manager")
    }
    guard failures.isEmpty,
        let kernelConfiguration,
        let userRange,
        let groupRange
    else {
        throw AndroidRuntimeFailure(
            "contained Android host prerequisites failed:\n"
                + failures.map { "  - \($0)" }.joined(separator: "\n"))
    }
    return AndroidRuntimeHostConfiguration(
        userID: getuid(),
        groupID: getgid(),
        kernelConfiguration: kernelConfiguration,
        subordinateUID: userRange.start,
        subordinateGID: groupRange.start,
        subordinateUIDCount: userRange.count,
        subordinateGIDCount: groupRange.count)
}

public func resolveAndroidRuntimeExecutable(
    _ name: String,
    environment: [String: String]
) -> URL? {
    guard !name.isEmpty, !name.contains("/") else {
        return nil
    }
    for directory in (environment["PATH"] ?? "/usr/bin:/bin")
        .split(separator: ":")
    {
        let candidate = URL(
            fileURLWithPath: String(directory),
            isDirectory: true
        ).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

public func resolveAndroidRuntimeKernelConfiguration(
    release: String
) -> URL? {
    guard !release.isEmpty,
        !release.contains("/"),
        !release.contains("\0")
    else {
        return nil
    }
    for path in [
        "/proc/config.gz",
        "/boot/config-\(release)",
    ] {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
            FileManager.default.isReadableFile(atPath: path),
            let data = try? Data(contentsOf: url),
            isValidHostKernelConfiguration(data)
        else {
            continue
        }
        return url
    }
    return nil
}

public func androidRuntimeSubordinateRange(
    user: String,
    contents: String
) -> (start: UInt32, count: UInt32)? {
    for line in contents.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
            fields[0] == Substring(user),
            let start = UInt32(fields[1]),
            let count = UInt32(fields[2]),
            count >= 65_536,
            UInt64(start) + UInt64(count) <= UInt64(UInt32.max) + 1
        else {
            continue
        }
        return (start, count)
    }
    return nil
}
