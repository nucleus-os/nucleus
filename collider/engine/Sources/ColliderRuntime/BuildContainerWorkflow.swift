import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareBuildContainer(
        _ preparation: BuildContainerPreparation,
        stage: TaskID
    ) async throws {
        let contents = try String(
            contentsOfFile: preparation.containerFile.string,
            encoding: .utf8)
        let base = contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("FROM ") }
        guard let base, base.contains("@sha256:") else {
            throw RuntimeFailure.invalidOutput(
                "build Containerfile must select its base image by digest")
        }

        let parent = preparation.imageID.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        let candidate = parent.appending(
            ".image-id.candidate-\(UUID().uuidString)")
        let previousImageID = try? String(
            contentsOfFile: preparation.imageID.string,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: candidate.string) }

        let result = try await execute(
            CommandSpec(
                executable: .named("podman"),
                arguments: [
                    "build",
                    "--pull=always",
                    "--tag", preparation.imageName,
                    "--iidfile", candidate.string,
                    "--file", preparation.containerFile.string,
                    preparation.context.string,
                ],
                workingDirectory: preparation.context,
                environment: preparation.environment,
                output: .logged),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
        let imageID = try String(
            contentsOfFile: candidate.string,
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageID.hasPrefix("sha256:"), imageID.count == 71 else {
            throw RuntimeFailure.invalidOutput(
                "Podman did not produce a content-addressed builder image ID")
        }
        try DurableFile.write(Data("\(imageID)\n".utf8), to: preparation.imageID)
        if let previousImageID,
            previousImageID != imageID,
            previousImageID.hasPrefix("sha256:"),
            previousImageID.count == 71
        {
            _ = try? await execute(
                CommandSpec(
                    executable: .named("podman"),
                    arguments: ["image", "rm", previousImageID],
                    workingDirectory: preparation.context,
                    environment: preparation.environment,
                    output: .logged),
                stage: stage)
        }
    }

    func runBuildContainer(
        _ execution: BuildContainerExecution,
        stage: TaskID
    ) async throws {
        let imageID = try String(
            contentsOfFile: execution.imageID.string,
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageID.hasPrefix("sha256:"), imageID.count == 71 else {
            throw RuntimeFailure.invalidOutput(
                "builder image ID is missing or invalid")
        }
        guard execution.workingDirectory.hasPrefix("/"),
            !execution.hostname.isEmpty,
            !execution.command.isEmpty
        else {
            throw RuntimeFailure.invalidOutput(
                "invalid build container execution contract")
        }

        var targets: Set<String> = ["/tmp", "/home/nucleus-build"]
        for mount in execution.mounts {
            guard mount.target.hasPrefix("/"),
                !mount.target.contains(".."),
                targets.insert(mount.target).inserted
            else {
                throw RuntimeFailure.invalidOutput(
                    "invalid or duplicate build container mount: \(mount.target)")
            }
            if mount.access == .readWrite {
                try FileManager.default.createDirectory(
                    atPath: mount.source.string,
                    withIntermediateDirectories: true)
            } else if !FileManager.default.fileExists(atPath: mount.source.string) {
                throw RuntimeFailure.invalidOutput(
                    "read-only build container input is missing: \(mount.source)")
            }
        }

        let temporaryDirectory: FilePath?
        if let root = execution.temporaryDirectory {
            try FileManager.default.createDirectory(
                atPath: root.string,
                withIntermediateDirectories: true)
            let candidate = root.appending(UUID().uuidString)
            try FileManager.default.createDirectory(
                atPath: candidate.string,
                withIntermediateDirectories: false)
            temporaryDirectory = candidate
        } else {
            temporaryDirectory = nil
        }
        defer {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(
                    atPath: temporaryDirectory.string)
            }
        }

        var arguments = [
            "run",
            "--rm",
            "--network=none",
            "--userns=keep-id:uid=1000,gid=1000",
            "--cap-drop=all",
            "--security-opt=no-new-privileges",
            "--hostname=\(execution.hostname)",
            "--read-only",
            "--pids-limit=32768",
            "--tmpfs=/home/nucleus-build:rw,nosuid,nodev,noexec,size=1g",
            "--workdir=\(execution.workingDirectory)",
        ]
        if let temporaryDirectory {
            arguments += [
                "--mount",
                "type=bind,src=\(temporaryDirectory),target=/tmp,rw=true",
            ]
        } else {
            arguments.append("--tmpfs=/tmp:rw,nosuid,nodev,size=8g")
        }
        for (name, value) in execution.containerEnvironment.sorted(by: {
            $0.key < $1.key
        }) {
            arguments += ["--env", "\(name)=\(value)"]
        }
        for mount in execution.mounts {
            let writable = mount.access == .readWrite ? "rw=true" : "ro=true"
            arguments += [
                "--mount",
                "type=bind,src=\(mount.source),target=\(mount.target),\(writable)",
            ]
        }
        arguments.append(imageID)
        arguments += execution.command

        let result = try await execute(
            CommandSpec(
                executable: .named("podman"),
                arguments: arguments,
                workingDirectory: execution.hostWorkingDirectory,
                environment: execution.environment,
                output: .logged),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
    }
}
