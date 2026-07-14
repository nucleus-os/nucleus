// The `Scene` half of the SwiftUI-shaped entry vocabulary. A `Scene` is a declarative
// description of one or more windows; an `App`'s `body` is a `Scene`. Scenes compose:
// a custom `Scene`'s `body` is another `Scene`, walked until a *primitive* scene
// (`WindowGroup`, `_SceneList`, `EmptyScene`) is reached, which materializes onto the
// platform host. This mirrors SwiftUI: primitives set `Body = Never` and don't implement
// `body` (a `where Body == Never` default traps), and are recognized structurally
// (`_PrimitiveScene`) rather than by having their `body` evaluated.

import NucleusUI

/// A part of an app's window content. Conform a `struct` and describe your windows in
/// `body`; compose scenes by returning them from another scene's `body`.
@MainActor
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
}

extension Scene where Body == Never {
    /// Primitive scenes (`Body == Never`) never have `body` evaluated — the walk
    /// recognizes them via `_PrimitiveScene` first. This default satisfies the
    /// requirement without each primitive re-declaring the trap, and (being a
    /// protocol-extension default, not a conforming-type witness) is not subject to the
    /// `@SceneBuilder` transform.
    public var body: Never { fatalError("a primitive Scene has no body") }
}

/// A primitive scene materializes directly onto the host instead of recursing through a
/// `body`. Internal: the vocabulary's leaves conform, and the walk recognizes them.
@MainActor
protocol _PrimitiveScene {
    func _materializePrimitive(into host: any PlatformAppHost) throws
}

extension Scene {
    /// Walk to primitives and materialize. A primitive materializes itself; any other
    /// scene recurses into its `body`. Recursion terminates because every user scene's
    /// `body` eventually resolves to a primitive.
    func _materialize(into host: any PlatformAppHost) throws {
        if let primitive = self as? any _PrimitiveScene {
            try primitive._materializePrimitive(into: host)
        } else {
            try body._materialize(into: host)
        }
    }
}

/// `Never` terminates the `Body` chain for primitive scenes. Its `body` comes from the
/// `where Body == Never` default and is never evaluated.
extension Never: Scene {
    public typealias Body = Never
}

/// An empty scene — the result of an empty `@SceneBuilder` block. Materializes nothing.
public struct EmptyScene: Scene, _PrimitiveScene {
    public typealias Body = Never
    public init() {}
    func _materializePrimitive(into host: any PlatformAppHost) throws {}
}

/// An ordered group of scenes — the result of a multi-statement `@SceneBuilder` block.
/// Materializes each child in order. The `_`-prefix marks it builder-internal: apps write
/// several scenes in a body and never name this type.
public struct _SceneList: Scene, _PrimitiveScene {
    public typealias Body = Never
    let scenes: [any Scene]
    init(_ scenes: [any Scene]) { self.scenes = scenes }
    func _materializePrimitive(into host: any PlatformAppHost) throws {
        for scene in scenes {
            try scene._materialize(into: host)
        }
    }
}

/// Result builder for scene bodies (`@SceneBuilder var body`). Normalizes each scene to an
/// existential and collects a block into a `_SceneList`, with the usual optional / either /
/// array forms so `if`, `if/else`, and `for` work in a body. `@MainActor` because the
/// scenes it constructs are main-actor-isolated (`Scene` is `@MainActor`).
@resultBuilder
@MainActor
public enum SceneBuilder {
    public static func buildExpression<S: Scene>(_ scene: S) -> any Scene { scene }
    public static func buildBlock(_ scenes: any Scene...) -> _SceneList { _SceneList(scenes) }
    public static func buildOptional(_ scenes: _SceneList?) -> _SceneList { scenes ?? _SceneList([]) }
    public static func buildEither(first scenes: _SceneList) -> _SceneList { scenes }
    public static func buildEither(second scenes: _SceneList) -> _SceneList { scenes }
    public static func buildArray(_ lists: [_SceneList]) -> _SceneList {
        _SceneList(lists.flatMap { $0.scenes })
    }
}
