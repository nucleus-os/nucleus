import ColliderCore
import Testing

@testable import LinuxPackageContracts

@Test func nativePackageStageObservationsAggregateInDeclaredOrder() {
    let recorder = LinuxNativePackageStageRecorder()
    recorder.record(
        .rpmAssembly,
        durationNanoseconds: 11,
        inputByteCount: 12,
        outputByteCount: 13)
    recorder.record(
        .payloadMaterialization,
        durationNanoseconds: 1,
        inputByteCount: 2,
        outputByteCount: 3)
    recorder.record(
        .rpmAssembly,
        durationNanoseconds: 17,
        inputByteCount: 19,
        outputByteCount: 23)
    recorder.record(
        .rpmBuild,
        package: .runtime,
        family: .rpm,
        durationNanoseconds: 29,
        inputByteCount: 31,
        outputByteCount: 37)
    recorder.record(
        .debianBuild,
        package: .browser,
        family: .debian,
        durationNanoseconds: 41,
        inputByteCount: 43,
        outputByteCount: 47)

    #expect(
        recorder.observations == [
            ActionStageObservation(
                name: "linux-native-package.payload-materialization",
                durationNanoseconds: 1,
                inputByteCount: 2,
                outputByteCount: 3),
            ActionStageObservation(
                name: "linux-native-package.rpm-assembly",
                durationNanoseconds: 28,
                inputByteCount: 31,
                outputByteCount: 36),
            ActionStageObservation(
                name:
                    "linux-native-package.debian.nucleus-browser."
                    + "dpkg-deb-zstd-level-7-threads-2",
                durationNanoseconds: 41,
                inputByteCount: 43,
                outputByteCount: 47),
            ActionStageObservation(
                name: "linux-native-package.rpm.nucleus-runtime.rpmbuild",
                durationNanoseconds: 29,
                inputByteCount: 31,
                outputByteCount: 37),
        ])
}
