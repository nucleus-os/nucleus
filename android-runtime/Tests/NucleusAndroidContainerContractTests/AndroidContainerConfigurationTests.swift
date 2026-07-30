import NucleusAndroidContainerContract
import Testing

@Test
func containerConfigurationRunsDelegationBeforeAndroidInit() throws {
    let configuration = AndroidContainerConfiguration(
        name: "nucleus-android-runtime-3970820",
        rootFileSystem:
            "/run/nucleus/android/nucleus-android-runtime-3970820/rootfs",
        seccompProfile: "/opt/nucleus/container.seccomp",
        kernelLogDevice: "/dev/pts/2",
        tombstones:
            "/run/nucleus/android/nucleus-android-runtime-3970820/tombstones",
        persistentData:
            "/run/nucleus/android/nucleus-android-runtime-3970820/persistent-data",
        gfxstreamSocketDirectory:
            "/run/nucleus/android/nucleus-android-runtime-3970820/gfxstream-broker",
        runtimeBridgeSocket:
            "/run/nucleus/android/nucleus-android-runtime-3970820/runtime-bridge/broker.sock",
        presentationSocket:
            "/run/nucleus/android/nucleus-android-runtime-3970820/runtime-bridge/presentation.sock",
        displayControlSocket:
            "/run/nucleus/android/nucleus-android-runtime-3970820/runtime-bridge/display-control.sock",
        hostKernelConfigurationDirectory:
            "/run/nucleus/android/nucleus-android-runtime-3970820/kernel-configuration",
        hostUIDStart: 165_536,
        hostGIDStart: 165_536,
        hostUIDCount: 65_536,
        hostGIDCount: 65_536,
        binderDevices: [
            AndroidContainerDevice(
                name: "binder",
                source: "/run/nucleus/android/nucleus-android-runtime-3970820/binder/binder",
                major: 508,
                minor: 1),
            AndroidContainerDevice(
                name: "hwbinder",
                source:
                    "/run/nucleus/android/nucleus-android-runtime-3970820/binder/hwbinder",
                major: 508,
                minor: 2),
            AndroidContainerDevice(
                name: "vndbinder",
                source:
                    "/run/nucleus/android/nucleus-android-runtime-3970820/binder/vndbinder",
                major: 508,
                minor: 3),
        ],
        mountHook: AndroidContainerMountHook(
            executable: "/usr/bin/env",
            arguments: ["/opt/nucleus/collider", "__android-bpf-mount"]),
        startHostHook: AndroidContainerMountHook(
            executable: "/usr/bin/env",
            arguments: [
                "/opt/nucleus/collider",
                "__android-cgroup-delegate",
                "--container",
                "nucleus-android-runtime-3970820",
                "--system-uid",
                "166536",
                "--system-gid",
                "166536",
            ]))

    let text = try configuration.lxcConfiguration()
    #expect(
        text.contains(
            "lxc.hook.start-host = /usr/bin/env /opt/nucleus/collider "
                + "__android-cgroup-delegate --container "
                + "nucleus-android-runtime-3970820 --system-uid 166536 "
                + "--system-gid 166536"))
    #expect(text.contains("lxc.cgroup.dir.container = payload"))
    #expect(text.contains("lxc.cgroup.dir.container.inner = android"))
    #expect(text.contains("lxc.cgroup.dir.monitor = monitor"))
    #expect(text.contains("lxc.prlimit.rtprio = 3"))
    #expect(text.contains("lxc.cgroup2.devices.allow = c 10:229 rwm"))
    #expect(!text.contains("lxc.cgroup2.devices.allow = c 10:223 rwm"))
    #expect(
        text.contains(
            "lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file 0 0"))
    #expect(!text.contains("dev/uinput"))
    #expect(
        text.contains(
            "lxc.mount.entry = tmpfs dev/nucleus-runtime tmpfs "
                + "rw,nosuid,nodev,noexec,mode=0755,create=dir 0 0"))
    #expect(
        text.contains(
            "nucleus-android-runtime-3970820/runtime-bridge/broker.sock "
                + "dev/nucleus-runtime/broker.sock none "
                + "bind,create=file 0 0"))
    #expect(
        text.contains(
            "nucleus-android-runtime-3970820/runtime-bridge/presentation.sock "
                + "dev/nucleus-runtime/presentation.sock none "
                + "bind,create=file 0 0"))
}
