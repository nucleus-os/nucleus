import ColliderCore
import Foundation
import Testing

@Test func platformCoordinatesRemainIndependent() throws {
    let runner = RunnerPlatform(
        operatingSystem: .macOS,
        architecture: .arm64)
    let execution = ExecutionPlatform.linuxAMD64OCI
    let artifact = ArtifactTarget.androidX86_64(apiLevel: 37)

    #expect(runner.operatingSystem == .macOS)
    #expect(runner.architecture == .arm64)
    #expect(execution.environment == .oci)
    #expect(execution.operatingSystem == .linux)
    #expect(execution.architecture == .x86_64)
    #expect(artifact.operatingSystem == .android)
    #expect(artifact.architecture == .x86_64)
    #expect(artifact.abi == "bionic")
    #expect(artifact.androidAPILevel == 37)

    let encoded = try JSONEncoder().encode(artifact)
    #expect(try JSONDecoder().decode(ArtifactTarget.self, from: encoded) == artifact)
}

@Test func artifactIdentityIncludesABIAndAndroidAPILevel() {
    #expect(
        ArtifactTarget.linuxX86_64
            != ArtifactTarget(
                operatingSystem: .linux,
                architecture: .x86_64,
                abi: "musl"))
    #expect(
        ArtifactTarget.androidX86_64(apiLevel: 36)
            != ArtifactTarget.androidX86_64(apiLevel: 37))
}
