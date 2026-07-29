import Foundation

public func validateAndroidRuntimeImages<
    RuntimeHost: AndroidRuntimeHost
>(
    layout: AndroidRuntimeLayout,
    using host: RuntimeHost
) async throws -> AndroidImageProvenance {
    let provenance = try JSONDecoder().decode(
        AndroidImageProvenance.self,
        from: Data(contentsOf: layout.provenance))
    let expected = Set([
        "system.img",
        "system_ext.img",
        "product.img",
        "vendor.img",
        "vbmeta.img",
        "vbmeta_system.img",
    ])
    guard provenance.status == "signed",
        provenance.product == "nucleus_x86_64",
        Set(provenance.images.map(\.name)) == expected,
        provenance.images.allSatisfy({ $0.storageFormat == "raw" })
    else {
        throw AndroidRuntimeFailure(
            "signed Android image provenance does not satisfy "
                + "the runtime contract")
    }
    for image in provenance.images {
        let path = layout.images.appendingPathComponent(image.name)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: path.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value
        guard size == image.size else {
            throw AndroidRuntimeFailure(
                "\(image.name) size does not match image provenance")
        }
        let output = try await host.run(
            "sha256sum",
            ["--", path.path],
            capture: true)
        guard output.split(whereSeparator: \.isWhitespace).first
            == Substring(image.sha256)
        else {
            throw AndroidRuntimeFailure(
                "\(image.name) digest does not match image provenance")
        }
    }
    try await host.run(
        layout.hostTools.appendingPathComponent("avbtool").path,
        [
            "verify_image",
            "--image",
            layout.images.appendingPathComponent("vbmeta.img").path,
            "--key",
            layout.signingIdentity.appendingPathComponent(
                "releasekey.pem").path,
            "--follow_chain_partitions",
        ],
        capture: true)
    return provenance
}
