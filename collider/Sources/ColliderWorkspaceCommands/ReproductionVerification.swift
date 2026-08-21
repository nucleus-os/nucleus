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
    // Scratch roots nest by target and by sanitizer, and how deeply is the
    // layout's business rather than this comparison's, so the search is
    // bounded by depth instead of assuming a shape.
    for root in scratchRoots {
        for scratch in verificationScratches(under: root, depth: 4, files: files) {
            let name = scratch.lastComponent?.string ?? ""
            let retained = scratch.removingLastComponent()
                .appending(String(name.dropLast(verificationScratchSuffix.count)))
            let verificationProducts = scratch.appending(".collider/products")
            guard files.fileExists(atPath: verificationProducts.string) else { continue }
            products.append(
                try compare(
                    verification: verificationProducts,
                    retained: retained.appending(".collider/products"),
                    scratch: scratch.removingLastComponent().lastComponent.map {
                        "\($0)/\(name)"
                    } ?? name,
                    files: files))
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

private func verificationScratches(
    under root: FilePath,
    depth: Int,
    files: FileManager
) -> [FilePath] {
    guard depth > 0,
        let entries = try? files.contentsOfDirectory(atPath: root.string)
    else { return [] }
    var found: [FilePath] = []
    for entry in entries.sorted() {
        let path = root.appending(entry)
        guard
            (try? files.attributesOfItem(atPath: path.string))?[.type]
                as? FileAttributeType == .typeDirectory
        else { continue }
        if entry.hasSuffix(verificationScratchSuffix) {
            found.append(path)
        } else {
            found += verificationScratches(under: path, depth: depth - 1, files: files)
        }
    }
    return found
}
