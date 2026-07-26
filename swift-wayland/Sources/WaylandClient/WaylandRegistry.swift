// Typed registry binding for Wayland client globals.

public import WaylandClientDispatch

/// The type-erased storage accepted by `WaylandRegistry`.
///
/// Consumers construct the generic `DesiredGlobal<Interface>` subclass. Erasure
/// exists only so requirements for different interfaces can share one array; the
/// bind closure has already captured and checked the concrete interface type.
@MainActor
@safe public class AnyDesiredGlobal {
  fileprivate let interfaceName: String
  fileprivate let interfaceID: ObjectIdentifier
  fileprivate let allowsMultiple: Bool
  fileprivate let bind:
    (
      WaylandProxy<WlRegistryClient>,
      UInt32,
      UInt32
    ) throws(WaylandProxyError) -> AnyBoundGlobal

  fileprivate init(
    interfaceName: String,
    interfaceID: ObjectIdentifier,
    allowsMultiple: Bool,
    bind:
      @escaping (
        WaylandProxy<WlRegistryClient>,
        UInt32,
        UInt32
      ) throws(WaylandProxyError) -> AnyBoundGlobal
  ) {
    self.interfaceName = interfaceName
    self.interfaceID = interfaceID
    self.allowsMultiple = allowsMultiple
    self.bind = bind
  }

  public var wireInterfaceName: String {
    interfaceName
  }

  public var acceptsMultiple: Bool {
    allowsMultiple
  }
}

/// A typed registry-global requirement and its lifecycle callbacks.
@MainActor
@safe
public final class DesiredGlobal<
  Interface: WaylandClientInterface
>: AnyDesiredGlobal {
  public init(
    maximumVersion: UInt32 = Interface.maximumVersion,
    allowsMultiple: Bool = false,
    onBind: @escaping (BoundGlobal<Interface>) -> Void = { _ in },
    onRemove: @escaping (BoundGlobal<Interface>) -> Void = { _ in }
  ) {
    precondition(
      maximumVersion <= Interface.maximumVersion,
      "consumer maximum exceeds the generated protocol maximum")
    let name = Interface.descriptor.wireName
    super.init(
      interfaceName: name,
      interfaceID: ObjectIdentifier(Interface.self),
      allowsMultiple: allowsMultiple,
      bind: {
        (
          registry: WaylandProxy<WlRegistryClient>,
          name: UInt32,
          advertisedVersion: UInt32
        ) throws(WaylandProxyError) -> AnyBoundGlobal in
        let version = min(advertisedVersion, maximumVersion)
        let proxy = try registry.bind(
          name: name,
          version: version,
          as: Interface.self)
        let bound = BoundGlobal(
          name: name,
          proxy: proxy,
          version: version)
        return AnyBoundGlobal(
          interfaceType: Interface.self,
          value: bound,
          proxy: proxy,
          onRemove: { onRemove(bound) },
          onBind: { onBind(bound) })
      })
  }
}

/// One interface-typed registry binding.
@safe
public struct BoundGlobal<
  Interface: WaylandClientInterface
> {
  public let name: UInt32
  public let proxy: WaylandProxy<Interface>
  public let version: UInt32
}

@MainActor
@safe private final class AnyBoundGlobal {
  let interfaceID: ObjectIdentifier
  let value: Any
  let proxy: AnyObject
  let onRemove: () -> Void
  let onBind: () -> Void

  init<Interface: WaylandClientInterface>(
    interfaceType: Interface.Type,
    value: BoundGlobal<Interface>,
    proxy: WaylandProxy<Interface>,
    onRemove: @escaping () -> Void,
    onBind: @escaping () -> Void
  ) {
    interfaceID = ObjectIdentifier(interfaceType)
    self.value = value
    self.proxy = proxy
    self.onRemove = onRemove
    self.onBind = onBind
  }
}

/// Owns the registry proxy and exposes only interface-typed bound proxies.
@MainActor
@safe public final class WaylandRegistry {
  private let registry: WaylandProxy<WlRegistryClient>
  private let wanted: [String: AnyDesiredGlobal]
  private var bound: [UInt32: AnyBoundGlobal] = [:]

  public init?(
    _ connection: WaylandConnection,
    wanting requirements: [AnyDesiredGlobal]
  ) {
    guard let registry = try? connection.getRegistry() else {
      return nil
    }
    self.registry = registry
    var wanted: [String: AnyDesiredGlobal] = [:]
    for requirement in requirements {
      precondition(
        wanted[requirement.interfaceName] == nil,
        "duplicate desired Wayland interface \(requirement.interfaceName)")
      wanted[requirement.interfaceName] = requirement
    }
    self.wanted = wanted
    do {
      try registry.installListener(self)
    } catch {
      return nil
    }
  }

  isolated deinit {
    try? registry.destroyLocally()
  }

  public func singleton<Interface: WaylandClientInterface>(
    _ interface: Interface.Type
  ) -> WaylandProxy<Interface>? {
    binding(interface)?.proxy
  }

  public func instances<Interface: WaylandClientInterface>(
    _ interface: Interface.Type
  ) -> [WaylandProxy<Interface>] {
    bindings(interface).map(\.proxy)
  }

  public func binding<Interface: WaylandClientInterface>(
    _ interface: Interface.Type
  ) -> BoundGlobal<Interface>? {
    bindings(interface).first
  }

  public func bindings<Interface: WaylandClientInterface>(
    _ interface: Interface.Type
  ) -> [BoundGlobal<Interface>] {
    let interfaceID = ObjectIdentifier(interface)
    return bound.values.compactMap { entry in
      guard entry.interfaceID == interfaceID else {
        return nil
      }
      return entry.value as? BoundGlobal<Interface>
    }
  }

  private func bindGlobal(
    name: UInt32,
    interfaceName: String,
    version: UInt32
  ) {
    guard let requirement = wanted[interfaceName] else {
      return
    }
    if !requirement.allowsMultiple,
      bound.values.contains(where: {
        $0.interfaceID == requirement.interfaceID
      })
    {
      return
    }
    guard
      let global = try? requirement.bind(
        registry,
        name,
        version)
    else {
      return
    }
    bound[name] = global
    global.onBind()
  }

  private func removeGlobal(name: UInt32) {
    guard let removed = bound.removeValue(forKey: name) else {
      return
    }
    removed.onRemove()
  }
}

extension WaylandRegistry: WlRegistryEvents {
  public func global(
    _ proxy: WaylandBorrowedProxy<WlRegistryClient>,
    name: UInt32,
    interface: String,
    version: UInt32
  ) {
    bindGlobal(
      name: name,
      interfaceName: interface,
      version: version)
  }

  public func globalRemove(
    _ proxy: WaylandBorrowedProxy<WlRegistryClient>,
    name: UInt32
  ) {
    removeGlobal(name: name)
  }
}
