import Foundation

public func validateAndroidRuntimeImages<
    RuntimeHost: AndroidRuntimeHost
>(
    layout: AndroidRuntimeLayout,
    using host: RuntimeHost
) async throws -> AndroidImageProvenance {
    let manifest = try JSONDecoder().decode(
        AndroidPackageManifest.self,
        from: Data(contentsOf: layout.packageManifest))
    for file in manifest.payload {
        let path = layout.packageRoot.appendingPathComponent(file.path)
        let values = try path.resourceValues(
            forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .isExecutableKey,
            ])
        guard let size = values.fileSize, size >= 0,
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            UInt64(size) == file.size,
            values.isExecutable == file.executable
        else {
            throw AndroidRuntimeFailure(
                "Android package payload metadata changed: \(file.path)")
        }
        let output = try await host.run(
            "sha256sum", ["--", path.path], capture: true)
        guard
            output.split(whereSeparator: \.isWhitespace).first
                == Substring(file.sha256)
        else {
            throw AndroidRuntimeFailure(
                "Android package payload digest changed: \(file.path)")
        }
    }
    let provenance = try JSONDecoder().decode(
        AndroidImageProvenance.self,
        from: Data(contentsOf: layout.provenance))
    try validateAndroidPackageImageProvenance(
        manifest: manifest,
        provenance: provenance)
    for image in provenance.images {
        let path = layout.images.appendingPathComponent(image.name)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: path.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value
        guard size == image.size else {
            throw AndroidRuntimeFailure(
                "\(image.name) size does not match image provenance")
        }
    }
    try await host.run(
        layout.avbTool.path,
        [
            "verify_image",
            "--image",
            layout.images.appendingPathComponent("vbmeta.img").path,
            "--key",
            layout.verificationKey.path,
            "--follow_chain_partitions",
        ],
        capture: true)
    return provenance
}

public func validateAndroidPackageImageProvenance(
    manifest: AndroidPackageManifest,
    provenance: AndroidImageProvenance
) throws {
    let expected = Set([
        "system.img",
        "system_ext.img",
        "product.img",
        "vendor.img",
        "vbmeta.img",
        "vbmeta_system.img",
    ])
    let expectedProduct =
        switch manifest.architecture {
        case .arm64: "nucleus_arm64"
        case .x86_64: "nucleus_x86_64"
        }
    guard provenance.status == "signed",
        provenance.product == expectedProduct,
        provenance.release == manifest.release,
        provenance.buildNumber == manifest.buildNumber,
        Set(provenance.images.map(\.name)) == expected,
        provenance.images.allSatisfy({ $0.storageFormat == "raw" })
    else {
        throw AndroidRuntimeFailure(
            "signed Android image provenance does not satisfy "
                + "the runtime contract")
    }
    for image in provenance.images {
        guard
            let payload = manifest.payload.first(where: {
                $0.path == "images/\(image.name)"
            }),
            payload.size == image.size,
            payload.sha256 == image.sha256
        else {
            throw AndroidRuntimeFailure(
                "\(image.name) does not match the signed package manifest")
        }
    }
}
