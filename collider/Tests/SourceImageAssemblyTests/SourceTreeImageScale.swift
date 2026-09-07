#if os(macOS)

import ContainerizationEXT4
import Foundation
import SourceImageAssembly
import SystemPackage
import Testing

/// Measures building an image from a real prepared source tree.
///
/// The phase this belongs to claims the host build costs nothing that scales
/// with the file-sharing layer, because the host reads its own filesystem
/// natively. That is an argument about a tree of roughly a million entries and
/// tens of gigabytes, and the behaviour tests run against fixtures of a few
/// kilobytes. Opt in with `COLLIDER_MEASURE_SOURCE_IMAGE=<tree path>` and an
/// output directory in `COLLIDER_MEASURE_SOURCE_IMAGE_OUTPUT`.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["COLLIDER_MEASURE_SOURCE_IMAGE"]
            != nil))
func sourceTreeImageScaleMeasurement() throws {
    let environment = ProcessInfo.processInfo.environment
    let tree = FilePath(environment["COLLIDER_MEASURE_SOURCE_IMAGE"]!)
    let output = FilePath(
        environment["COLLIDER_MEASURE_SOURCE_IMAGE_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.path)
    let image = output.appending("source-measurement.img")

    let started = ContinuousClock.now
    try SourceTreeImage.write(tree: tree, to: image)
    let elapsed = ContinuousClock.now - started

    let bytes =
        (try? FileManager.default.attributesOfItem(atPath: image.string)[.size]
            as? NSNumber)??.uint64Value ?? 0
    let tenthsOfAGibibyte = bytes / 107_374_182
    print(
        "MEASURE tree=\(tree) elapsed=\(elapsed) imageBytes=\(bytes) "
            + "imageGiB=\(tenthsOfAGibibyte / 10).\(tenthsOfAGibibyte % 10)")
}

#endif
