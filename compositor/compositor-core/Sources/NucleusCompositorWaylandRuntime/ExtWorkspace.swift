// ext_workspace_v1 on the router — the workspace / virtual-desktop pager protocol,
// served as a thin projection of the Spaces model.
//
// The manager is the only global. Each bind creates a per-client projection that
// registers as a `DesktopModelObserver`; the snapshot replay enumerates the current
// spaces through the same `desktopModelDidChange` path the live stream uses. The
// model is per-output (niri-like): each output owns a dynamic set of workspaces
// switched independently — so the projection emits one group per output (carrying it
// via output_enter) and one workspace per Space (entering its output's group,
// carrying name + the active-state bit). A workspace is `active` iff it is its
// output's active space.
//
// Atomicity: every per-handle event a single change batch emits is followed by one
// manager `done`. Inbound requests buffer until the client's `commit`, then apply in
// order to the Swift Spaces model.
// Ported from the legacy NucleusWaylandRouter/Workspace.swift.

import WaylandServerC
internal import NucleusCompositorServer
import WaylandServer
import WaylandServerDispatch

@MainActor
final class ExtWorkspaceManager {
    private unowned let compositor: WlCompositor
    fileprivate unowned let server: NucleusCompositorServer

    init(compositor: WlCompositor, server: NucleusCompositorServer) {
        self.compositor = compositor
        self.server = server
    }

    func register(in router: NucleusWaylandRouter) {
        router.addGlobal(
            interface: swift_wayland_iface_ext_workspace_manager_v1(), version: 1, impl: self, bind: Self.bind)
    }

    fileprivate func outputResource(
        forClient client: OpaquePointer, displayID: UInt64
    ) -> UnsafeMutablePointer<wl_resource>? {
        compositor.output(id: displayID)?.resources(forClient: client).first
    }

    private static let bind: @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32
    ) -> Void = { client, data, version, id in
        guard let client else { return }
        let clientBits = UInt(bitPattern: UnsafeRawPointer(client))
        let dataBits = UInt(bitPattern: data)
        MainActor.assumeIsolated {
            guard let clientRaw = UnsafeRawPointer(bitPattern: clientBits),
                let dataRaw = UnsafeMutableRawPointer(bitPattern: dataBits),
                let me = NucleusWaylandRouter.impl(dataRaw, as: ExtWorkspaceManager.self)
            else { return }
            let projection = ExtWorkspaceClient(manager: me, version: version)
            guard let res = WaylandResource.create(
                client: OpaquePointer(clientRaw), interface: swift_wayland_iface_ext_workspace_manager_v1(),
                version: Int32(version), id: id, vtable: ExtWorkspaceManagerV1Server.vtable,
                owner: projection) else { return }
            projection.bind(res)
            projection.start()
        }
    }
}

private final class WeakGroup {
    weak var group: ExtWorkspaceGroup?
    init(_ group: ExtWorkspaceGroup) { self.group = group }
}
private final class WeakWorkspace {
    weak var workspace: ExtWorkspaceHandle?
    init(_ workspace: ExtWorkspaceHandle) { self.workspace = workspace }
}

/// A single client's pager projection (Rule 9: owned by its manager wl_resource).
@MainActor
final class ExtWorkspaceClient: DesktopModelObserver {
    fileprivate unowned let manager: ExtWorkspaceManager
    fileprivate let version: Int32
    private var resource: UnsafeMutablePointer<wl_resource>?

    /// group_capabilities: create_workspace = 1.
    private static let groupCaps: UInt32 = 1
    /// workspace_capabilities: activate (1) | remove (4). No deactivate (single active
    /// per output) and no assign (workspaces are output-bound).
    private static let workspaceCaps: UInt32 = 1 | 4
    private static let stateActive: UInt32 = 1

    private var groups: [DisplayID: WeakGroup] = [:]
    private var workspaces: [SpaceID: WeakWorkspace] = [:]

    fileprivate enum PendingRequest {
        case activate(space: SpaceID, output: DisplayID)
        case createWorkspace(output: DisplayID)
        case remove(space: SpaceID)
    }
    private var pending: [PendingRequest] = []
    private var finished = false

    init(manager: ExtWorkspaceManager, version: UInt32) {
        self.manager = manager
        self.version = Int32(version)
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
    fileprivate func start() { manager.server.addObserver(self) }

    private var spaces: Spaces { manager.server.spaces }

    private func group(_ outputID: DisplayID) -> ExtWorkspaceGroup? {
        guard let box = groups[outputID] else { return nil }
        guard let g = box.group else { groups[outputID] = nil; return nil }
        return g
    }
    private func workspace(_ spaceID: SpaceID) -> ExtWorkspaceHandle? {
        guard let box = workspaces[spaceID] else { return nil }
        guard let w = box.workspace else { workspaces[spaceID] = nil; return nil }
        return w
    }

    // MARK: DesktopModelObserver

    func desktopModelDidChange(_ changes: [DesktopChange]) {
        guard !finished, let resource else { return }
        var touched = false
        for change in changes {
            switch change {
            case let .spaceAdded(id): touched = reconcileWorkspace(id) || touched
            case let .spaceChanged(id): touched = reconcileWorkspace(id) || touched
            case let .spaceRemoved(id): touched = dropWorkspace(id) || touched
            case let .spaceActivated(output, _): touched = refreshActive(forOutput: output) || touched
            default: break  // window changes belong to foreign-toplevel
            }
        }
        if touched { ext_workspace_manager_v1_send_done(resource) }
    }

    private func reconcileWorkspace(_ spaceID: SpaceID) -> Bool {
        guard let resource, let space = spaces.spaces.first(where: { $0.id == spaceID }) else {
            return dropWorkspace(spaceID)
        }
        let active = spaces.activeSpace(forDisplay: space.outputID) == spaceID
        let group = ensureGroup(forOutput: space.outputID)

        if workspace(spaceID) == nil {
            guard let client = wl_resource_get_client(resource) else { return false }
            let handleObj = ExtWorkspaceHandle(
                client: self, spaceID: spaceID, outputID: space.outputID)
            guard let wsRes = WaylandResource.create(
                client: client, interface: swift_wayland_iface_ext_workspace_handle_v1(),
                version: version, id: 0, vtable: ExtWorkspaceHandleV1Server.vtable,
                owner: handleObj) else { return false }
            handleObj.bind(wsRes)
            handleObj.active = active
            workspaces[spaceID] = WeakWorkspace(handleObj)
            ext_workspace_manager_v1_send_workspace(resource, wsRes)
            if let group { ext_workspace_group_handle_v1_send_workspace_enter(group.resource, wsRes) }
            space.name.withCString { ext_workspace_handle_v1_send_name(wsRes, $0) }
            ext_workspace_handle_v1_send_capabilities(wsRes, Self.workspaceCaps)
            ext_workspace_handle_v1_send_state(wsRes, active ? Self.stateActive : 0)
            return true
        }

        guard let handle = workspace(spaceID) else { return false }
        var emitted = false
        if handle.name != space.name {
            handle.name = space.name
            space.name.withCString { ext_workspace_handle_v1_send_name(handle.resource, $0) }
            emitted = true
        }
        if handle.active != active {
            handle.active = active
            ext_workspace_handle_v1_send_state(handle.resource, active ? Self.stateActive : 0)
            emitted = true
        }
        return emitted
    }

    /// Get-or-create the wire group for an output, retrying the (possibly deferred)
    /// output_enter each call.
    private func ensureGroup(forOutput outputID: DisplayID) -> ExtWorkspaceGroup? {
        guard let resource, let client = wl_resource_get_client(resource) else { return nil }
        if group(outputID) == nil {
            let groupObj = ExtWorkspaceGroup(client: self, outputID: outputID)
            guard let groupRes = WaylandResource.create(
                client: client, interface: swift_wayland_iface_ext_workspace_group_handle_v1(),
                version: version, id: 0, vtable: ExtWorkspaceGroupHandleV1Server.vtable,
                owner: groupObj) else { return nil }
            groupObj.bind(groupRes)
            groups[outputID] = WeakGroup(groupObj)
            ext_workspace_manager_v1_send_workspace_group(resource, groupRes)
            ext_workspace_group_handle_v1_send_capabilities(groupRes, Self.groupCaps)
        }
        guard let group = group(outputID) else { return nil }
        if !group.outputAdvertised,
            let outputRes = manager.outputResource(forClient: client, displayID: outputID)
        {
            ext_workspace_group_handle_v1_send_output_enter(group.resource, outputRes)
            group.outputAdvertised = true
        }
        return group
    }

    private func dropWorkspace(_ spaceID: SpaceID) -> Bool {
        guard let handle = workspace(spaceID) else { return false }
        if let group = group(handle.outputID) {
            ext_workspace_group_handle_v1_send_workspace_leave(group.resource, handle.resource)
        }
        ext_workspace_handle_v1_send_removed(handle.resource)
        let outputID = handle.outputID
        workspaces[spaceID] = nil
        // An output keeps ≥1 workspace unless the output itself is gone, so a now-empty
        // group means the output was removed.
        if !workspaces.values.contains(where: { $0.workspace?.outputID == outputID }) {
            if let group = group(outputID) {
                ext_workspace_group_handle_v1_send_removed(group.resource)
                groups[outputID] = nil
            }
        }
        return true
    }

    private func refreshActive(forOutput outputID: DisplayID) -> Bool {
        let activeID = spaces.activeSpace(forDisplay: outputID)
        var emitted = false
        for spaceID in Array(workspaces.keys) {
            guard let handle = workspace(spaceID), handle.outputID == outputID else { continue }
            let active = (spaceID == activeID)
            guard handle.active != active else { continue }
            handle.active = active
            ext_workspace_handle_v1_send_state(handle.resource, active ? Self.stateActive : 0)
            emitted = true
        }
        return emitted
    }

    // MARK: inbound request buffering (applied on commit)

    fileprivate func enqueueActivate(space: SpaceID, output: DisplayID) {
        pending.append(.activate(space: space, output: output))
    }
    fileprivate func enqueueCreateWorkspace(output: DisplayID) {
        pending.append(.createWorkspace(output: output))
    }
    fileprivate func enqueueRemove(space: SpaceID) { pending.append(.remove(space: space)) }

    private func applyPending() {
        let requests = pending
        pending.removeAll(keepingCapacity: true)
        let spaces = manager.server.spaces
        for request in requests {
            switch request {
            case let .activate(space, output):
                if spaces.setActiveSpace(space, forDisplay: output) {
                    RenderBridge.requestFrame(server: manager.server, outputId: output)
                }
            case let .createWorkspace(output):
                if spaces.appendWorkspace(onOutput: output) != 0 {
                    RenderBridge.requestFrame(server: manager.server, outputId: output)
                }
            case let .remove(space):
                let output = spaces.spaces.first {
                    $0.id == space
                }?.outputID ?? 0
                if spaces.removeSpace(space) {
                    RenderBridge.requestFrame(server: manager.server, outputId: output)
                }
            }
        }
    }

    fileprivate func commitRequests() { applyPending() }
    fileprivate func stopProjection() {
        finished = true
        pending.removeAll()
        manager.server.removeObserver(self)
        if let resource { ext_workspace_manager_v1_send_finished(resource) }
    }

}

// The generated dispatch is nonisolated; the router only drives it on the compositor
// main actor, so each handler reasserts that with `assumeIsolated`.
extension ExtWorkspaceClient: ExtWorkspaceManagerV1Requests {
    nonisolated func commit(_ resource: UnsafeMutablePointer<wl_resource>) {
        MainActor.assumeIsolated { self.commitRequests() }
    }
    nonisolated func stop(_ resource: UnsafeMutablePointer<wl_resource>) {
        MainActor.assumeIsolated { self.stopProjection() }
    }
}

/// ext_workspace_group_handle_v1 owner (Rule 9): one output's wire group.
@MainActor
final class ExtWorkspaceGroup {
    private unowned let client: ExtWorkspaceClient
    let outputID: DisplayID
    private(set) var resource: UnsafeMutablePointer<wl_resource>! = nil
    var outputAdvertised = false

    init(client: ExtWorkspaceClient, outputID: DisplayID) {
        self.client = client
        self.outputID = outputID
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }
}

extension ExtWorkspaceGroup: ExtWorkspaceGroupHandleV1Requests {
    nonisolated func createWorkspace(_ resource: UnsafeMutablePointer<wl_resource>,
                                     workspace: UnsafePointer<CChar>?) {
        // The requested name is advisory; the model numbers workspaces. Buffered.
        MainActor.assumeIsolated {
            self.client.enqueueCreateWorkspace(output: self.outputID)
        }
    }
}

/// ext_workspace_handle_v1 owner (Rule 9): one Space's wire workspace.
@MainActor
final class ExtWorkspaceHandle {
    private unowned let client: ExtWorkspaceClient
    let spaceID: SpaceID
    let outputID: DisplayID
    private(set) var resource: UnsafeMutablePointer<wl_resource>! = nil
    var name: String = ""
    var active: Bool = false

    init(client: ExtWorkspaceClient, spaceID: SpaceID, outputID: DisplayID) {
        self.client = client
        self.spaceID = spaceID
        self.outputID = outputID
    }
    fileprivate func bind(_ resource: UnsafeMutablePointer<wl_resource>) { self.resource = resource }

    fileprivate nonisolated func act(_ body: @escaping @MainActor (ExtWorkspaceClient, ExtWorkspaceHandle) -> Void) {
        MainActor.assumeIsolated { body(self.client, self) }
    }
}

// The generated dispatch is nonisolated; reassert the compositor main actor.
extension ExtWorkspaceHandle: ExtWorkspaceHandleV1Requests {
    nonisolated func activate(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { $0.enqueueActivate(space: $1.spaceID, output: $1.outputID) }
    }
    // deactivate: not advertised (the active workspace is implicitly replaced, never
    // cleared); assign: not advertised (workspaces are output-bound). Both no-op.
    nonisolated func deactivate(_ resource: UnsafeMutablePointer<wl_resource>) {}
    nonisolated func assign(_ resource: UnsafeMutablePointer<wl_resource>,
                            workspace_group: UnsafeMutablePointer<wl_resource>?) {}
    nonisolated func remove(_ resource: UnsafeMutablePointer<wl_resource>) {
        act { client, me in client.enqueueRemove(space: me.spaceID) }
    }
}
