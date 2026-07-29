import Foundation
import NucleusAndroidRuntimeCore
import Testing

@Suite struct AndroidRuntimeLayoutTests {
    @Test func layoutIsDerivedWithoutColliderWorkspaceState() {
        let androidRoot = URL(fileURLWithPath: "/opt/nucleus/android")
        let runDirectory = URL(fileURLWithPath: "/run/user/1000/nucleus")
        let layout = AndroidRuntimeLayout(
            androidRoot: androidRoot,
            runDirectory: runDirectory,
            gfxstreamBrokerExecutable: URL(
                fileURLWithPath: "/usr/libexec/nucleus-android-gfxstream-broker"),
            displayHostExecutable: URL(
                fileURLWithPath: "/usr/libexec/nucleus-android-display-host"),
            processIdentifier: 42)

        #expect(layout.name == "nucleus-framework-42")
        #expect(layout.instance.path
            == "/run/nucleus/android/nucleus-framework-42")
        #expect(layout.persistentDataMountPoint.path
            == layout.instance.appendingPathComponent(
                "persistent-data").path)
        #expect(layout.diagnostics.path
            == "/run/user/1000/nucleus/android-framework-boot")
        #expect(layout.images.path
            == "/opt/nucleus/android/.aosp-build/current/images")
        #expect(layout.displayHostSocket.path
            == layout.instance.appendingPathComponent(
                "gfxstream-broker/composer.sock").path)
    }

    @Test func mountLedgerTakesExactlyOnceInReverseOrder() {
        var ledger = AndroidFrameworkMountLedger()
        let first = URL(fileURLWithPath: "/runtime/first")
        let second = URL(fileURLWithPath: "/runtime/second")
        ledger.record(first)
        ledger.record(second)
        #expect(ledger.takeInReverseOrder() == [second, first])
        #expect(ledger.takeInReverseOrder().isEmpty)
    }

    @Test func processInvocationsRemainFullySpecified() {
        let lxc = AndroidLXCStartInvocation(
            name: "nucleus-framework-42",
            configuration: "/runtime/lxc.conf",
            logFile: "/runtime/lxc.log")
        #expect(lxc.executable == "sudo")
        #expect(lxc.arguments.suffix(6) == [
            "--rcfile", "/runtime/lxc.conf",
            "--logfile", "/runtime/lxc.log",
            "--logpriority", "TRACE",
        ])

        let logcat = AndroidLogcatInvocation(
            name: "nucleus-framework-42",
            sinceEpochSecond: 123)
        #expect(logcat.arguments.suffix(2) == ["-T", "123.000"])
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
