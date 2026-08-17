import Foundation
import NucleusAndroidRuntimeCore
import Testing

@Suite struct AndroidRuntimeLayoutTests {
    @Test func layoutRejectsOverlappingPackageAndStateRoots() {
        #expect(throws: AndroidRuntimeFailure.self) {
            _ = try AndroidRuntimeLayout(
                packageRoot: URL(fileURLWithPath: "/usr/lib/nucleus-android/fixture"),
                persistentStateRoot: URL(
                    fileURLWithPath: "/usr/lib/nucleus-android/fixture/state"),
                diagnosticsRunDirectory: URL(
                    fileURLWithPath: "/run/user/1000/nucleus"),
                gfxstreamBrokerExecutable: URL(fileURLWithPath: "/broker"),
                displayHostExecutable: URL(fileURLWithPath: "/display"))
        }
    }

    @Test func layoutUsesPackagePayloadAndIndependentPersistentState() throws {
        let packageRoot = URL(fileURLWithPath: "/usr/lib/nucleus-android/fixture")
        let stateRoot = URL(fileURLWithPath: "/var/lib/nucleus/android")
        let runDirectory = URL(fileURLWithPath: "/run/user/1000/nucleus")
        let layout = try AndroidRuntimeLayout(
            packageRoot: packageRoot,
            persistentStateRoot: stateRoot,
            diagnosticsRunDirectory: runDirectory,
            gfxstreamBrokerExecutable: URL(
                fileURLWithPath: "/usr/libexec/nucleus-android-gfxstream-broker"),
            displayHostExecutable: URL(
                fileURLWithPath: "/usr/libexec/nucleus-android-display-host"),
            processIdentifier: 42)

        #expect(layout.name == "nucleus-android-runtime-42")
        #expect(
            layout.instance.path
                == "/run/nucleus/android/nucleus-android-runtime-42")
        #expect(
            layout.persistentDataMountPoint.path
                == layout.instance.appendingPathComponent(
                    "persistent-data"
                ).path)
        #expect(
            layout.diagnostics.path
                == "/run/user/1000/nucleus/android-runtime")
        #expect(
            layout.images.path
                == "/usr/lib/nucleus-android/fixture/images")
        #expect(layout.persistentStateRoot.path == "/var/lib/nucleus/android")
        #expect(
            layout.verificationKey.path
                == "/usr/lib/nucleus-android/fixture/share/nucleus/android/avb-release-key.pem")
        #expect(
            layout.avbTool.path
                == "/usr/lib/nucleus-android/fixture/libexec/android-tools/avbtool")
        #expect(
            layout.displayHostSocket.path
                == layout.instance.appendingPathComponent(
                    "gfxstream-broker/composer.sock"
                ).path)
        #expect(
            layout.displayInputSocket.path
                == layout.instance.appendingPathComponent(
                    "runtime-bridge/display-input.sock"
                ).path)
        #expect(
            layout.presentationControlSocket.path
                == layout.instance.appendingPathComponent(
                    "runtime-bridge/presentation-control.sock"
                ).path)
    }

    @Test func mountLedgerTakesExactlyOnceInReverseOrder() {
        var ledger = AndroidRuntimeMountLedger()
        let first = URL(fileURLWithPath: "/runtime/first")
        let second = URL(fileURLWithPath: "/runtime/second")
        ledger.record(first)
        ledger.record(second)
        #expect(ledger.takeInReverseOrder() == [second, first])
        #expect(ledger.takeInReverseOrder().isEmpty)
    }

    @Test func processInvocationsRemainFullySpecified() {
        let lxc = AndroidLXCStartInvocation(
            helperExecutable: "/runtime/privileged",
            ownerProcessIdentifier: 7,
            name: "nucleus-android-runtime-42",
            configuration: "/runtime/lxc.conf",
            logFile: "/runtime/lxc.log")
        #expect(lxc.executable == "sudo")
        #expect(
            lxc.arguments.suffix(8) == [
                "--owner-pid", "7",
                "--container", "nucleus-android-runtime-42",
                "--configuration", "/runtime/lxc.conf",
                "--log-file", "/runtime/lxc.log",
            ])

        let logcat = AndroidLogcatInvocation(
            name: "nucleus-android-runtime-42",
            sinceEpochSecond: 123)
        #expect(logcat.arguments.suffix(2) == ["-T", "123.000"])
    }

    @Test func lifecycleReconciliationOnlySelectsNucleusContainers() {
        #expect(
            androidRuntimeContainerNames(
                """
                unrelated nucleus-runtime-7 nucleus-android-runtime-42
                nucleus-android-runtime-4x nucleus-android-runtime-42.scope
                """
            ) == [
                "nucleus-android-runtime-42"
            ])
        #expect(
            isNucleusAndroidRuntimeContainerName(
                "nucleus-android-runtime-193313"))
        #expect(
            !isNucleusAndroidRuntimeContainerName(
                "nucleus-android-runtime-193313.scope"))
        #expect(
            !isNucleusAndroidRuntimeContainerName(
                "nucleus-android-runtime-\u{0661}"))
        #expect(
            androidRuntimeMountDiscoveryArguments(
                instance: "/run/nucleus/android/nucleus-android-runtime-42"
            ) == [
                "--target",
                "/run/nucleus/android/nucleus-android-runtime-42",
                "--submounts",
                "--noheadings",
                "--raw",
                "--output",
                "TARGET",
            ])
        #expect(
            androidRuntimeMountPoints(
                """
                /run
                /run/unrelated
                /run/nucleus/android/nucleus-android-runtime-42/rootfs
                /run/nucleus/android/nucleus-android-runtime-42/rootfs/apex/runtime
                /run/nucleus/android/nucleus-android-runtime-42/binder
                """,
                instance: "/run/nucleus/android/nucleus-android-runtime-42"
            ) == [
                "/run/nucleus/android/nucleus-android-runtime-42/rootfs/apex/runtime",
                "/run/nucleus/android/nucleus-android-runtime-42/binder",
                "/run/nucleus/android/nucleus-android-runtime-42/rootfs",
            ])
    }

    @Test func swiftRuntimeCarriesItsInstalledLoaderPath() throws {
        let runtime = try AndroidSwiftRuntime(
            libraryRoot: URL(fileURLWithPath: "/opt/nucleus"),
            loaderSearchDirectory: URL(
                fileURLWithPath: "/opt/nucleus/lib"))
        #expect(runtime.loaderSearchPath == "lib")
        #expect(throws: AndroidRuntimeFailure.self) {
            try AndroidSwiftRuntime(
                libraryRoot: URL(fileURLWithPath: "/opt/nucleus"),
                loaderSearchDirectory: URL(
                    fileURLWithPath: "/usr/lib"))
        }
    }

    @Test func subordinateRangesRequireAFullAndroidIdentitySpace() {
        #expect(
            androidRuntimeSubordinateRange(
                user: "root",
                contents: "other:100000:65536\nroot:166536:65536\n"
            )?.start == 166_536)
        #expect(
            androidRuntimeSubordinateRange(
                user: "root",
                contents: "root:166536:65535\n") == nil)
    }

    @Test func privilegedCommandRejectsUnboundedOptionShapes() {
        #expect(throws: AndroidRuntimePrivilegedCommandFailure.self) {
            try AndroidRuntimePrivilegedCommand.run(
                arguments: [
                    AndroidRuntimePrivilegedOperation
                        .apexMountCommandName,
                    "--source", "/system/apex/runtime.apex",
                    "--source", "/vendor/apex/runtime.apex",
                ],
                environment: [:])
        }
        #expect(throws: AndroidRuntimePrivilegedCommandFailure.self) {
            try AndroidRuntimePrivilegedCommand.run(
                arguments: ["unknown-operation"],
                environment: [:])
        }
    }
}
