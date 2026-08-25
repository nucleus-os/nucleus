import ColliderCore
import Foundation
import SystemPackage

/// What a container sees at the root of the Swift package it builds.
///
/// A build mounts the directories its manifest declares rather than the
/// checkout those directories sit in. The package root itself cannot be one of
/// those mounts: a bind mount source must be a directory, and `Package.swift`
/// and `Package.resolved` are files directly inside a root whose other
/// contents are what declaring the set exists to keep out.
///
/// The view is that root — copies of the files the invocation reads, and an
/// empty directory for every mount nested inside it. The empty directories are
/// required rather than tidy: a nested bind target that its parent does not
/// contain fails to mount, because the runtime tries to create it and the
/// parent is read-only. Mounting the parent writable instead is not available,
/// because overlapping mounts are permitted only when both are read-only.
package struct PackageRootViewRequest: Hashable, Sendable {
    package let identifier: String
    package let root: FilePath
    package let view: FilePath
    package let files: [FilePath]
    package let nestedDirectories: [FilePath]

    package init(
        identifier: String,
        root: FilePath,
        view: FilePath,
        files: [FilePath],
        nestedDirectories: [FilePath]
    ) {
        self.identifier = identifier
        self.root = root
        self.view = view
        self.files = files.sorted { $0.string < $1.string }
        self.nestedDirectories = nestedDirectories.sorted { $0.string < $1.string }
    }

    /// Each path relative to the root it is declared under. The view mirrors
    /// this shape, so a mount nested at `<root>/a/b` finds `a/b` inside it.
    fileprivate func relative(_ path: FilePath) -> String {
        String(path.string.dropFirst(root.string.count + 1))
    }
}

struct MaterializePackageRootViewAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let request: PackageRootViewRequest

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(request.identifier)
            encoder.append(path: request.root)
            encoder.append(path: request.view)
            encoder.appendSequence(request.files) { fileEncoder, file in
                fileEncoder.append(path: file)
            }
            encoder.appendSequence(request.nestedDirectories) { directoryEncoder, directory in
                directoryEncoder.append(path: directory)
            }
        }
    }

    static let kind: ActionKind = "native.materialize-package-root-view"

    let identity: Identity

    init(request: PackageRootViewRequest) {
        identity = Identity(request: request)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.readWrite, scope: .output(identity.request.view))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let request = identity.request
        let files = context.files
        // Rebuilt rather than updated: the view is a projection of the
        // declared set, and a directory left behind by a previous shape would
        // be a mount point this build never asked for.
        try files.remove(request.view)
        try files.createDirectory(request.view)
        for directory in request.nestedDirectories {
            try files.createDirectory(
                request.view.appending(request.relative(directory)))
        }
        for file in request.files {
            let destination = request.view.appending(request.relative(file))
            try files.createDirectory(destination.removingLastComponent())
            try files.copy(from: file, to: destination)
        }
    }

    func validateOutputs(using files: ActionFileSystem) throws {
        let request = identity.request
        for file in request.files {
            let destination = request.view.appending(request.relative(file))
            guard try files.metadata(for: destination)?.type == .regular else {
                throw PackageRootViewFailure(
                    "package root view is missing \(request.relative(file))")
            }
        }
        for directory in request.nestedDirectories {
            let destination = request.view.appending(request.relative(directory))
            guard try files.metadata(for: destination)?.type == .directory else {
                throw PackageRootViewFailure(
                    "package root view is missing the mount point "
                        + request.relative(directory))
            }
        }
    }
}

private struct PackageRootViewFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
