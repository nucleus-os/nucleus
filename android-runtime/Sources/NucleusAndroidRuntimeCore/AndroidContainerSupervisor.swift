import Glibc
import NucleusAndroidRuntimePlatformC

struct AndroidContainerSupervisor {
    let ownerProcessIdentifier: Int32
    let containerName: String
    let configuration: String
    let logFile: String

    func run() throws {
        guard isNucleusAndroidRuntimeContainerName(containerName),
            configuration.hasPrefix("/"),
            logFile.hasPrefix("/")
        else {
            throw AndroidRuntimePrivilegedCommandFailure(
                "invalid container supervisor configuration")
        }
        let owner = nucleus_android_runtime_pidfd_open(
            ownerProcessIdentifier)
        guard owner >= 0 else {
            throw AndroidRuntimePrivilegedCommandFailure(
                "open Android runtime owner pidfd failed with errno \(errno)")
        }
        defer { _ = close(owner) }

        let launcher = containerName.withCString { namePointer in
            configuration.withCString { configurationPointer in
                logFile.withCString { logPointer in
                    unsafe nucleus_android_runtime_spawn_container_launcher(
                        namePointer,
                        configurationPointer,
                        logPointer)
                }
            }
        }
        guard launcher > 0 else {
            throw AndroidRuntimePrivilegedCommandFailure(
                "spawn Android container launcher failed with errno \(errno)")
        }

        while true {
            let launcherState =
                nucleus_android_runtime_poll_process_status(launcher)
            guard launcherState >= 0 else {
                stopContainer()
                terminateAndWait(launcher)
                throw AndroidRuntimePrivilegedCommandFailure(
                    "wait for Android container launcher failed with errno "
                        + "\(errno)")
            }
            if launcherState > 0 {
                let launcherStatus = launcherState - 1
                guard launcherStatus == 0 else {
                    throw AndroidRuntimePrivilegedCommandFailure(
                        "Android container launcher exited with status "
                            + "\(launcherStatus)")
                }
                return
            }

            let ownerState = nucleus_android_runtime_pidfd_wait(
                owner,
                250)
            guard ownerState >= 0 else {
                stopContainer()
                terminateAndWait(launcher)
                throw AndroidRuntimePrivilegedCommandFailure(
                    "wait for Android runtime owner failed with errno \(errno)")
            }
            if ownerState == 1 {
                stopContainer()
                terminateAndWait(launcher)
                return
            }
        }
    }

    private func stopContainer() {
        containerName.withCString { namePointer in
            _ = unsafe nucleus_android_runtime_stop_container(namePointer)
        }
    }

    private func terminateAndWait(_ processIdentifier: Int32) {
        _ = kill(processIdentifier, SIGTERM)
        _ = nucleus_android_runtime_wait_process_status(processIdentifier)
    }
}
