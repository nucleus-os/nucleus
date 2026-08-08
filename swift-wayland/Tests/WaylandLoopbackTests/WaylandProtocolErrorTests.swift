import Glibc
import Testing
import WaylandProtocolTypes
import WaylandServerC
import WaylandServerDispatch

@testable import WaylandServer

private struct PostedProtocolError: Equatable {
    let objectID: UInt32
    let code: UInt32
}

@MainActor
private final class NoMemoryChildOwner {}

private func littleEndianUInt32(
    _ bytes: [UInt8],
    at offset: Int
) -> UInt32 {
    UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

@MainActor
@unsafe
private func captureProtocolError<
    Interface: WaylandServerInterface
>(
    interface: Interface.Type,
    objectID: UInt32,
    post: (WaylandResourceHandle<Interface>) -> Bool
) throws -> PostedProtocolError {
    let display = try #require(WaylandDisplay(), "wl_display_create")
    var sockets: [Int32] = [0, 0]
    try #require(
        unsafe socketpair(
            AF_UNIX,
            Int32(SOCK_STREAM.rawValue),
            0,
            &sockets) == 0,
        "socketpair")
    defer { _ = close(sockets[1]) }

    let createdClient = unsafe display.createClient(fd: sockets[0])
    try #require(unsafe createdClient != nil, "wl_client_create")
    let client = unsafe createdClient!
    let createdResource = unsafe wl_resource_create(
        client,
        Interface.descriptor.nativeInterface,
        Interface.maximumVersion,
        objectID)
    try #require(
        unsafe createdResource != nil,
        "wl_resource_create")
    let nativeResource = unsafe createdResource!
    let createdHandle =
        unsafe WaylandResourceHandle<Interface>(nativeResource)
    try #require(
        createdHandle != nil,
        "WaylandResourceHandle")
    let handle = createdHandle!

    let didPost = post(handle)
    #expect(didPost)
    display.flushClients()

    var bytes = [UInt8](repeating: 0, count: 512)
    let count = unsafe recv(
        sockets[1],
        &bytes,
        bytes.count,
        Int32(MSG_DONTWAIT))
    try #require(count >= 16, "wl_display.error wire message")

    let displayObjectID = littleEndianUInt32(bytes, at: 0)
    let sizeAndOpcode = littleEndianUInt32(bytes, at: 4)
    #expect(displayObjectID == 1)
    #expect(UInt16(truncatingIfNeeded: sizeAndOpcode) == 0)
    #expect(Int(sizeAndOpcode >> 16) <= count)

    return PostedProtocolError(
        objectID: littleEndianUInt32(bytes, at: 8),
        code: littleEndianUInt32(bytes, at: 12))
}

@MainActor
@Suite
struct WaylandProtocolErrorTests {
    @Test
    func parentScopedAllocationFailurePostsNoMemory() throws {
        let display = try #require(
            WaylandDisplay(),
            "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue),
                0,
                &sockets) == 0,
            "socketpair")
        defer { _ = close(sockets[1]) }
        let createdClient =
            unsafe display.createClient(fd: sockets[0])
        try #require(
            unsafe createdClient != nil,
            "wl_client_create")
        let client = unsafe createdClient!
        let createdParent = unsafe wl_resource_create(
            client,
            WlCallbackServer.descriptor.nativeInterface,
            1,
            2)
        try #require(
            unsafe createdParent != nil,
            "wl_resource_create")
        let parent = try #require(
            unsafe WaylandResourceHandle<WlCallbackServer>(
                createdParent))

        let child: NoMemoryChildOwner? =
            unsafe WaylandResource.createChild(
                parent: parent,
                interface: WlCallbackServer.self,
                version: 1,
                owner: { _ in NoMemoryChildOwner() },
                handler: { $0 },
                installed: { _ in },
                publish: { _ in true },
                using: { _, _, _, _ in nil })
        #expect(child == nil)

        display.flushClients()
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = unsafe recv(
            sockets[1],
            &bytes,
            bytes.count,
            Int32(MSG_DONTWAIT))
        try #require(
            count >= 16,
            "wl_display.error wire message")
        #expect(littleEndianUInt32(bytes, at: 0) == 1)
        #expect(littleEndianUInt32(bytes, at: 8) == 1)
        #expect(
            littleEndianUInt32(bytes, at: 12)
                == WlDisplayError.noMemory.rawValue)
    }

    @Test
    func sameInterfaceErrorCarriesResourceIDAndCode() throws {
        let posted = try unsafe captureProtocolError(
            interface: WlSurfaceServer.self,
            objectID: 2
        ) {
            $0.postError(
                .invalidScale,
                message: "invalid surface scale")
        }

        #expect(
            posted
                == PostedProtocolError(
                    objectID: 2,
                    code: WlSurfaceError.invalidScale.rawValue))
    }

    @Test
    func decorationManagerExceptionCarriesDecorationErrorCode()
        throws
    {
        let posted = try unsafe captureProtocolError(
            interface: ZxdgDecorationManagerV1Server.self,
            objectID: 2
        ) {
            $0.postToplevelDecorationAlreadyConstructedError(
                message: "decoration already exists")
        }

        #expect(
            posted
                == PostedProtocolError(
                    objectID: 2,
                    code: ZxdgToplevelDecorationV1Error
                        .alreadyConstructed.rawValue))
    }

    @Test
    func layerSurfaceExceptionCarriesLayerShellErrorCode()
        throws
    {
        let posted = try unsafe captureProtocolError(
            interface: ZwlrLayerSurfaceV1Server.self,
            objectID: 2
        ) {
            $0.postLayerShellInvalidLayerError(
                message: "layer is out of range")
        }

        #expect(
            posted
                == PostedProtocolError(
                    objectID: 2,
                    code: ZwlrLayerShellV1Error.invalidLayer.rawValue))
    }

    @Test
    func errorPostingRejectsDestroyedResources() throws {
        let display = try #require(
            WaylandDisplay(),
            "wl_display_create")
        var sockets: [Int32] = [0, 0]
        try #require(
            unsafe socketpair(
                AF_UNIX,
                Int32(SOCK_STREAM.rawValue),
                0,
                &sockets) == 0,
            "socketpair")
        defer { _ = close(sockets[1]) }
        let createdClient =
            unsafe display.createClient(fd: sockets[0])
        try #require(
            unsafe createdClient != nil,
            "wl_client_create")
        let client = unsafe createdClient!

        let createdDecorationResource =
            unsafe wl_resource_create(
                client,
                ZxdgDecorationManagerV1Server.descriptor.nativeInterface,
                1,
                2)
        try #require(unsafe createdDecorationResource != nil)
        let decorationResource =
            unsafe createdDecorationResource!
        let createdDecoration =
            unsafe WaylandResourceHandle<
                ZxdgDecorationManagerV1Server
            >(decorationResource)
        try #require(createdDecoration != nil)
        let decoration = createdDecoration!
        unsafe wl_resource_destroy(decorationResource)
        #expect(
            !decoration
                .postToplevelDecorationAlreadyConstructedError(
                    message: "must not post"))

        let createdLayerResource =
            unsafe wl_resource_create(
                client,
                ZwlrLayerSurfaceV1Server.descriptor.nativeInterface,
                1,
                3)
        try #require(unsafe createdLayerResource != nil)
        let layerResource = unsafe createdLayerResource!
        let createdLayer =
            unsafe WaylandResourceHandle<
                ZwlrLayerSurfaceV1Server
            >(layerResource)
        try #require(createdLayer != nil)
        let layer = createdLayer!
        unsafe wl_resource_destroy(layerResource)
        #expect(
            !layer.postLayerShellInvalidLayerError(
                message: "must not post"))

        display.flushClients()
        var byte: UInt8 = 0
        #expect(
            unsafe recv(
                sockets[1],
                &byte,
                1,
                Int32(MSG_DONTWAIT)) == -1)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
    }
}
