import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

/// Names the location a verifying invocation produces into, beside the
/// retained one it is checked against.
package let verificationScratchSuffix = ".verification"

/// What a second production of one identity said about the first.
package struct ReproductionComparison: Codable, Equatable, Sendable {
    package struct Product: Codable, Equatable, Sendable {
        package let scratch: String
        package let matched: Int
        package let differing: [String]
        package let missing: [String]
    }

    package let products: [Product]

    package var reproduced: Bool {
        products.allSatisfy { $0.differing.isEmpty && $0.missing.isEmpty }
    }
}

/// Compares every verification production against the retained one beside it.
///
/// The pairing is the filesystem's: a verifying invocation produces into a
/// sibling of the location it would otherwise have replaced, so the two
/// results sit next to each other under one identity and need no record to
/// associate them.
package func compareVerificationProductions(
    under scratchRoots: [FilePath],
    files: FileManager = .default
) throws -> ReproductionComparison {
    var products: [ReproductionComparison.Product] = []
    // A scratch is two levels beneath its root: one directory per sanitizer,
    // then one per identity. Walking exactly that keeps the search off the
    // build trees themselves, which are large.
    for root in scratchRoots {
        let variants = (try? files.contentsOfDirectory(atPath: root.string)) ?? []
        for variant in variants.sorted() {
            let variantRoot = root.appending(variant)
            let scratches = (try? files.contentsOfDirectory(atPath: variantRoot.string)) ?? []
            for scratch in scratches.sorted()
            where scratch.hasSuffix(verificationScratchSuffix) {
                let verificationProducts = variantRoot.appending(scratch)
                    .appending(".collider/products")
                let retainedProducts =
                    variantRoot
                    .appending(String(scratch.dropLast(verificationScratchSuffix.count)))
                    .appending(".collider/products")
                guard files.fileExists(atPath: verificationProducts.string) else { continue }
                products.append(
                    try compare(
                        verification: verificationProducts,
                        retained: retainedProducts,
                        scratch: "\(variant)/\(scratch)",
                        files: files))
            }
        }
    }
    return ReproductionComparison(products: products.sorted { $0.scratch < $1.scratch })
}

private func compare(
    verification: FilePath,
    retained: FilePath,
    scratch: String,
    files: FileManager
) throws -> ReproductionComparison.Product {
    var matched = 0
    var differing: [String] = []
    var missing: [String] = []
    let walker = files.enumerator(atPath: verification.string)
    while let entry = walker?.nextObject() as? String {
        let produced = verification.appending(entry)
        let attributes = try? files.attributesOfItem(atPath: produced.string)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
        let counterpart = retained.appending(entry)
        guard files.fileExists(atPath: counterpart.string) else {
            missing.append(entry)
            continue
        }
        let producedDigest = try ArtifactHasher.digest(file: produced)
        let retainedDigest = try ArtifactHasher.digest(file: counterpart)
        if producedDigest == retainedDigest {
            matched += 1
        } else {
            differing.append(entry)
        }
    }
    return ReproductionComparison.Product(
        scratch: scratch,
        matched: matched,
        differing: differing.sorted(),
        missing: missing.sorted())
}
