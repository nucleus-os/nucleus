import Foundation

public struct AndroidRuntimeLayout: Sendable {
    public let androidRoot: URL
    public let name: String
    public let runtime: URL
    public let instance: URL
    public let rootFileSystem: URL
    public let persistentDataMountPoint: URL
    public let binder: URL
    public let deviceFileSystem: URL
    public let bpfBrokerDirectory: URL
    public let bpfBrokerSocket: URL
    public let bpfHookExecutable: URL
    public let gfxstreamBrokerDirectory: URL
    public let gfxstreamBrokerSocket: URL
    public let runtimeBridgeDirectory: URL
    public let runtimeBridgeSocket: URL
    public let presentationSocket: URL
    public let displayControlSocket: URL
    public let displayInputSocket: URL
    public let hostKernelConfigurationDirectory: URL
    public let hostKernelConfiguration: URL
    public let gfxstreamBrokerExecutable: URL
    public let displayHostSocket: URL
    public let displayHostExecutable: URL
    public let swiftRuntime: URL
    public let diagnostics: URL
    public let configuration: URL
    public let lxcLog: URL
    public let androidKernelLog: URL
    public let androidLog: URL
    public let gfxstreamBrokerLog: URL
    public let displayHostLog: URL
    public let progressLog: URL
    public let hostAuditLog: URL
    public let collectorErrors: URL
    public let gfxstreamCore: URL
    public let gfxstreamCoreMetadata: URL
    public let gfxstreamCoreCollectorLog: URL
    public let containerTombstones: URL
    public let diagnosticTombstones: URL
    public let images: URL
    public let provenance: URL
    public let sourceProvenance: URL
    public let patchManifest: URL
    public let sourceLock: URL
    public let productLock: URL
    public let signingIdentity: URL
    public let hostTools: URL
    public let appArmorProfile: URL
    public let seccompProfile: URL

    public init(
        androidRoot: URL,
        diagnosticsRunDirectory: URL,
        gfxstreamBrokerExecutable: URL,
        displayHostExecutable: URL,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.androidRoot = androidRoot
        name = "nucleus-android-runtime-\(processIdentifier)"
        runtime = URL(
            fileURLWithPath: "/run/nucleus/android",
            isDirectory: true)
        instance = runtime.appendingPathComponent(name, isDirectory: true)
        rootFileSystem = instance.appendingPathComponent(
            "rootfs",
            isDirectory: true)
        persistentDataMountPoint = androidPersistentDataMountPoint(
            instance: instance)
        binder = instance.appendingPathComponent(
            "binder",
            isDirectory: true)
        deviceFileSystem = instance.appendingPathComponent(
            "devices",
            isDirectory: true)
        bpfBrokerDirectory = instance.appendingPathComponent(
            "bpf-broker",
            isDirectory: true)
        bpfBrokerSocket = bpfBrokerDirectory.appendingPathComponent(
            "broker.sock")
        bpfHookExecutable = bpfBrokerDirectory.appendingPathComponent(
            "nucleus-android-runtime-privileged")
        gfxstreamBrokerDirectory = instance.appendingPathComponent(
            "gfxstream-broker",
            isDirectory: true)
        gfxstreamBrokerSocket = gfxstreamBrokerDirectory
            .appendingPathComponent("gfxstream.sock")
        runtimeBridgeDirectory = instance.appendingPathComponent(
            "runtime-bridge",
            isDirectory: true)
        runtimeBridgeSocket = runtimeBridgeDirectory.appendingPathComponent(
            "broker.sock")
        presentationSocket = runtimeBridgeDirectory.appendingPathComponent(
            "presentation.sock")
        displayControlSocket = runtimeBridgeDirectory.appendingPathComponent(
            "display-control.sock")
        displayInputSocket = runtimeBridgeDirectory.appendingPathComponent(
            "display-input.sock")
        hostKernelConfigurationDirectory = instance.appendingPathComponent(
            "kernel-configuration",
            isDirectory: true)
        hostKernelConfiguration = hostKernelConfigurationDirectory
            .appendingPathComponent("host-kernel.config")
        displayHostSocket = gfxstreamBrokerDirectory
            .appendingPathComponent("composer.sock")
        swiftRuntime = instance.appendingPathComponent(
            "swift-runtime",
            isDirectory: true)
        containerTombstones = instance.appendingPathComponent(
            "tombstones",
            isDirectory: true)
        diagnostics = diagnosticsRunDirectory.appendingPathComponent(
            "android-runtime",
            isDirectory: true)
        configuration = diagnostics.appendingPathComponent("lxc.conf")
        lxcLog = diagnostics.appendingPathComponent("lxc.log")
        androidKernelLog = diagnostics.appendingPathComponent(
            "android-kmsg.log")
        androidLog = diagnostics.appendingPathComponent(
            "android-logcat.log")
        gfxstreamBrokerLog = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.log")
        displayHostLog = diagnostics.appendingPathComponent(
            "android-display-host.log")
        progressLog = diagnostics.appendingPathComponent(
            "android-progress.jsonl")
        hostAuditLog = diagnostics.appendingPathComponent(
            "host-audit.log")
        collectorErrors = diagnostics.appendingPathComponent(
            "collector-errors.log")
        gfxstreamCore = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.core")
        gfxstreamCoreMetadata = diagnostics.appendingPathComponent(
            "android-gfxstream-broker.coredump.json")
        gfxstreamCoreCollectorLog = diagnostics.appendingPathComponent(
            "android-gfxstream-broker-core-collector.log")
        diagnosticTombstones = diagnostics.appendingPathComponent(
            "tombstones",
            isDirectory: true)
        self.gfxstreamBrokerExecutable = gfxstreamBrokerExecutable
        self.displayHostExecutable = displayHostExecutable
        images = androidRoot.appendingPathComponent(
            ".aosp-build/current/images",
            isDirectory: true)
        provenance = androidRoot.appendingPathComponent(
            ".aosp-build/current/signed/image-provenance.json")
        sourceProvenance = androidRoot.appendingPathComponent(
            ".aosp-source/.nucleus/source-provenance.json")
        patchManifest = androidRoot.appendingPathComponent(
            "aosp/patches.json")
        sourceLock = androidRoot.appendingPathComponent("aosp.lock.json")
        productLock = androidRoot.appendingPathComponent(
            "aosp-product.lock.json")
        signingIdentity = androidRoot.appendingPathComponent(
            ".aosp-signing/local-development",
            isDirectory: true)
        hostTools = androidRoot.appendingPathComponent(
            ".aosp-build/current/out/host/linux-x86/bin",
            isDirectory: true)
        appArmorProfile = androidRoot.appendingPathComponent(
            "container/lxc-nucleus-android.apparmor")
        seccompProfile = androidRoot.appendingPathComponent(
            "container/nucleus-android.seccomp")
    }
}
