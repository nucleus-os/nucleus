import ColliderCore
import SystemPackage

struct GraphOutputPathIndex {
    private var roots: [PathRoot: PathNode] = [:]

    mutating func insert(
        _ path: FilePath,
        owner task: TaskID,
        ordinal: Int
    ) -> TaskID? {
        let path = IndexedPath(path)
        let root =
            roots[path.root]
            ?? {
                let node = PathNode()
                roots[path.root] = node
                return node
            }()
        let owner = OutputOwner(task: task, ordinal: ordinal)
        var nodes = [root]
        var node = root
        var conflict = node.terminal.earliest(excluding: task)

        for component in path.components {
            let child =
                node.children[component]
                ?? {
                    let child = PathNode()
                    node.children[component] = child
                    return child
                }()
            node = child
            nodes.append(node)
            conflict = earlier(
                conflict,
                node.terminal.earliest(excluding: task))
        }

        // Previous outputs below this node overlap when the new output owns
        // one of their ancestors. This also covers an exact duplicate.
        conflict = earlier(
            conflict,
            node.subtree.earliest(excluding: task))
        if let conflict { return conflict.task }

        node.terminal.record(owner)
        for node in nodes {
            node.subtree.record(owner)
        }
        return nil
    }

    func firstProducer(
        containing path: FilePath,
        excluding task: TaskID
    ) -> TaskID? {
        let path = IndexedPath(path)
        guard var node = roots[path.root] else { return nil }
        var owner = node.terminal.earliest(excluding: task)
        for component in path.components {
            guard let child = node.children[component] else { break }
            node = child
            owner = earlier(
                owner,
                node.terminal.earliest(excluding: task))
        }
        return owner?.task
    }
}

private enum PathRoot: Hashable {
    case relative
    case absolute(FilePath.Root)
}

private struct IndexedPath {
    let root: PathRoot
    let components: [FilePath.Component]

    init(_ path: FilePath) {
        let normalized = path.normalizedForComparison()
        root = normalized.root.map(PathRoot.absolute) ?? .relative
        components = Array(normalized.components)
    }
}

private final class PathNode {
    var children: [FilePath.Component: PathNode] = [:]
    var terminal = OwnerSummary()
    var subtree = OwnerSummary()
}

private struct OutputOwner {
    let task: TaskID
    let ordinal: Int
}

/// The two earliest owners from distinct tasks are sufficient to answer
/// "earliest owner other than this task" without retaining every owner at
/// every ancestor node.
private struct OwnerSummary {
    private var first: OutputOwner?
    private var second: OutputOwner?

    mutating func record(_ owner: OutputOwner) {
        if first?.task == owner.task || second?.task == owner.task {
            return
        }
        guard let first else {
            self.first = owner
            return
        }
        if owner.ordinal < first.ordinal {
            second = first
            self.first = owner
        } else if let second {
            if owner.ordinal < second.ordinal {
                self.second = owner
            }
        } else {
            second = owner
        }
    }

    func earliest(excluding task: TaskID) -> OutputOwner? {
        guard first?.task == task else { return first }
        return second
    }
}

private func earlier(
    _ left: OutputOwner?,
    _ right: OutputOwner?
) -> OutputOwner? {
    switch (left, right) {
    case (.none, _): right
    case (_, .none): left
    case (.some(let left), .some(let right)):
        left.ordinal <= right.ordinal ? left : right
    }
}
