import Glibc
import Testing
import WaylandClient
import WaylandClientC
import WaylandClientDispatch

private final class RegistryEventReceiver: WlRegistryEvents {
  func global(
    _ proxy: WaylandBorrowedProxy<WlRegistryClient>,
    name: UInt32,
    interface: String,
    version: UInt32
  ) {}

  func globalRemove(
    _ proxy: WaylandBorrowedProxy<WlRegistryClient>,
    name: UInt32
  ) {}
}

private enum ClientFixtureError: Error {
  case connection
  case registry
}

@MainActor
private func makeOwnedRegistryProxy(
  fd: Int32
) throws -> (
  proxy: WaylandProxy<WlRegistryClient>,
  displayDescriptor: Int32
) {
  guard let connection = WaylandConnection(fd: fd) else {
    throw ClientFixtureError.connection
  }
  guard let registry = try? connection.getRegistry() else {
    throw ClientFixtureError.registry
  }
  return (registry, connection.fd)
}

// Proves the ergonomic client layer imports under C++ interop and its lifecycle is sound. No
// compositor runs in the test env, so a connection to a bogus socket must fail cleanly (nil), and a
// DesiredGlobal must expose the interface's wire name for registry matching.
@MainActor
@Suite struct WaylandClientTests {
  @Test func connectToMissingCompositorFailsCleanly() {
    // A socket name that cannot exist → wl_display_connect fails → init? returns nil.
    #expect(WaylandConnection(socket: "swift-wayland-nonexistent-socket") == nil)
  }

  @MainActor
  @Test func desiredGlobalExposesInterfaceName() {
    let want = DesiredGlobal<WlCompositorClient>(
      maximumVersion: 6)
    #expect(want.wireInterfaceName == "wl_compositor")
    #expect(want.acceptsMultiple == false)
  }

  @Test func cancelledPreparedReadLeavesConnectionReusable() throws {
    var sockets: [Int32] = [0, 0]
    let socketResult = unsafe socketpair(
      AF_UNIX,
      Int32(SOCK_STREAM.rawValue),
      0,
      &sockets)
    try #require(socketResult == 0)
    defer { close(sockets[0]) }
    let connection = try #require(WaylandConnection(fd: sockets[1]))

    let first = try #require(connection.prepareRead())
    first.read.cancel()

    let second = try #require(connection.prepareRead())
    #expect(second.dispatchedEventCount == 0)
    #expect(second.read.complete(readable: false) == 0)
  }

  @Test func typedEventArrayViewCopiesAlignedValues() {
    var array = unsafe wl_array()
    unsafe wl_array_init(&array)
    defer { unsafe wl_array_release(&array) }
    let storage = unsafe wl_array_add(
      &array, 2 * MemoryLayout<UInt16>.stride)
    #expect(unsafe storage != nil)
    unsafe storage?.storeBytes(of: UInt16(7), as: UInt16.self)
    unsafe storage?.advanced(by: MemoryLayout<UInt16>.stride)
      .storeBytes(of: UInt16(11), as: UInt16.self)

    let view = unsafe WaylandClientArrayView(&array)
    #expect(view.byteCount == 2 * MemoryLayout<UInt16>.stride)
    #expect(view.copiedElements(of: UInt16.self) == [7, 11])
  }

  @Test func requestArrayArgumentCopiesBytesForTheCall() {
    let source: [UInt8] = [2, 3, 5, 7, 11]
    let argument = WaylandClientArrayArgument(source)

    unsafe argument.withNativeArray { array in
      let count = unsafe array.pointee.size
      let copied = unsafe Array(
        UnsafeRawBufferPointer(
          start: array.pointee.data,
          count: count))
      #expect(count == source.count)
      #expect(copied == source)
    }
  }

  @Test func typedEventDescriptorClosesUnlessTaken() throws {
    var descriptors: [Int32] = [0, 0]
    try #require(unsafe pipe(&descriptors) == 0)
    defer { _ = close(descriptors[1]) }
    let raw = descriptors[0]

    consumeWithoutTaking(raw)

    #expect(fcntl(raw, F_GETFD) == -1)
    #expect(errno == EBADF)
  }

  private func consumeWithoutTaking(_ descriptor: Int32) {
    let owned = WaylandClientOwnedFileDescriptor(descriptor)
    #expect(fcntl(owned.rawValue, F_GETFD) >= 0)
  }

  @Test func transferredRequestDescriptorClosesAfterMarshalling() throws {
    var descriptors: [Int32] = [0, 0]
    try #require(unsafe pipe(&descriptors) == 0)
    defer { _ = close(descriptors[1]) }
    let raw = descriptors[0]

    consumeAsGeneratedRequestArgument(
      WaylandClientOwnedFileDescriptor(raw))

    #expect(fcntl(raw, F_GETFD) == -1)
    #expect(errno == EBADF)
  }

  private func consumeAsGeneratedRequestArgument(
    _ descriptor: consuming WaylandClientOwnedFileDescriptor
  ) {
    let raw = descriptor.take()
    WaylandClientOwnedFileDescriptor.closeTransferred(raw)
  }

  @Test
  func ownedProxyRetainsConnectionAndRejectsUseAfterDestroy() throws {
    var sockets: [Int32] = [0, 0]
    try #require(
      unsafe socketpair(
        AF_UNIX,
        Int32(SOCK_STREAM.rawValue),
        0,
        &sockets) == 0)
    defer { _ = close(sockets[0]) }

    var registry: WaylandProxy<WlRegistryClient>?
    var displayDescriptor: Int32 = -1
    do {
      let created = try makeOwnedRegistryProxy(fd: sockets[1])
      registry = created.proxy
      displayDescriptor = created.displayDescriptor
    }

    #expect(fcntl(displayDescriptor, F_GETFD) >= 0)
    #expect(registry?.isLive == true)

    try registry?.destroyLocally()
    #expect(registry?.isLive == false)
    #expect(throws: WaylandProxyError.destroyed) {
      try registry?.destroyLocally()
    }
    #expect(throws: WaylandProxyError.destroyed) {
      _ = try unsafe registry?.withUnsafeNativeProxy { _ in 0 }
    }

    registry = nil
    #expect(fcntl(displayDescriptor, F_GETFD) == -1)
    #expect(errno == EBADF)
  }

  @Test
  func proxyScopedListenerDoesNotRetainOwner() throws {
    var sockets: [Int32] = [0, 0]
    try #require(
      unsafe socketpair(
        AF_UNIX,
        Int32(SOCK_STREAM.rawValue),
        0,
        &sockets) == 0)
    defer { _ = close(sockets[0]) }
    let (registry, _) = try makeOwnedRegistryProxy(fd: sockets[1])

    var receiver: RegistryEventReceiver? = RegistryEventReceiver()
    weak let retainedReceiver = receiver
    try registry.installListener(try #require(receiver))
    receiver = nil
    #expect(retainedReceiver == nil)

    #expect(throws: WaylandProxyError.listenerAlreadyInstalled) {
      try registry.installListener(RegistryEventReceiver())
    }

    try registry.destroyLocally()
  }

  @Test
  func protocolDestructorInvalidatesWithoutDoubleDestroy() throws {
    var sockets: [Int32] = [0, 0]
    try #require(
      unsafe socketpair(
        AF_UNIX,
        Int32(SOCK_STREAM.rawValue),
        0,
        &sockets) == 0)
    defer { _ = close(sockets[0]) }
    let (registry, _) = try makeOwnedRegistryProxy(fd: sockets[1])

    try unsafe registry.withUnsafeNativeProxy {
      unsafe wl_registry_destroy($0)
    }
    try unsafe registry.invalidateAfterProtocolDestructor()

    #expect(registry.isLive == false)
    #expect(throws: WaylandProxyError.destroyed) {
      try registry.destroyLocally()
    }
  }
}
