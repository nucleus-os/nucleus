import ColliderCore
import Testing

@testable import LinuxColliderRecipe

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
        ])
}
