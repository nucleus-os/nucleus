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

internal import NucleusCompositorServer
import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

@MainActor
final class ExtWorkspaceManager {
    private unowned let compositor: WlCompositor
    fileprivate unowned let server: NucleusCompositorServer

    init(compositor: WlCompositor, server: NucleusCompositorServer) {
        self.compositor = compositor
        self.server = server
    }

    fileprivate func outputResource(
        forClient client: WaylandClientID?,
        displayID: UInt64
    ) -> WaylandResourceHandle<WlOutputServer>? {
        compositor.output(id: displayID)?
            .resources(forClient: client).first
    }

}

/// A single client's pager projection (Rule 9: owned by its manager wl_resource).
@MainActor
@safe final class ExtWorkspaceClient: DesktopModelObserver {
    fileprivate unowned let manager: ExtWorkspaceManager
    fileprivate let version: Int32
    private let resource: WaylandResourceHandle<ExtWorkspaceManagerV1Server>

    /// group_capabilities: create_workspace = 1.
    private static let groupCaps: UInt32 = 1
    /// workspace_capabilities: activate (1) | remove (4). No deactivate (single active
    /// per output) and no assign (workspaces are output-bound).
    private static let workspaceCaps: UInt32 = 1 | 4
    private static let stateActive: UInt32 = 1

    private var groups = WeakObjectMap<DisplayID, ExtWorkspaceGroup>()
    private var workspaces = WeakObjectMap<SpaceID, ExtWorkspaceHandle>()

    fileprivate enum PendingRequest {
        case activate(space: SpaceID, output: DisplayID)
        case createWorkspace(output: DisplayID)
        case remove(space: SpaceID)
    }
    private var pending: [PendingRequest] = []
    private var finished = false

    init(
        resource: WaylandResourceHandle<ExtWorkspaceManagerV1Server>,
        manager: ExtWorkspaceManager
    ) {
        self.resource = resource
        self.manager = manager
        version = resource.version ?? 1
    }
    func start() { manager.server.addObserver(self) }

    private var spaces: Spaces { manager.server.spaces }

    private func group(_ outputID: DisplayID) -> ExtWorkspaceGroup? {
        groups.value(forKey: outputID)
    }
    private func workspace(_ spaceID: SpaceID) -> ExtWorkspaceHandle? {
        workspaces.value(forKey: spaceID)
    }

    // MARK: DesktopModelObserver

    func desktopModelDidChange(_ changes: [DesktopChange]) {
        guard !finished else { return }
        var touched = false
        for change in changes {
            switch change {
            case .spaceAdded(let id): touched = reconcileWorkspace(id) || touched
            case .spaceChanged(let id): touched = reconcileWorkspace(id) || touched
            case .spaceRemoved(let id): touched = dropWorkspace(id) || touched
            case .spaceActivated(let output, _):
                touched = refreshActive(forOutput: output) || touched
            default: break  // window changes belong to foreign-toplevel
            }
        }
        if touched { resource.sendDone() }
    }

    private func reconcileWorkspace(_ spaceID: SpaceID) -> Bool {
        guard resource.isLive,
            let space = spaces.spaces.first(where: { $0.id == spaceID })
        else {
            return dropWorkspace(spaceID)
        }
        let active = spaces.activeSpace(forDisplay: space.outputID) == spaceID
        let group = ensureGroup(forOutput: space.outputID)

        if workspace(spaceID) == nil {
            guard
                resource.createWorkspace(
                    owner: { handle in
                        ExtWorkspaceHandle(
                            resource: handle,
                            client: self,
                            spaceID: spaceID,
                            outputID: space.outputID)
                    },
                    installed: { handleObj in
                        handleObj.active = active
                        self.workspaces.insert(handleObj, forKey: spaceID)
                        if let group {
                            group.resource.sendWorkspaceEnter(
                                workspace: handleObj.resource)
                        }
                        handleObj.resource.sendName(name: space.name)
                        handleObj.resource.sendCapabilities(
                            capabilities: ExtWorkspaceHandleV1WorkspaceCapabilities(
                                rawValue: Self.workspaceCaps))
                        handleObj.resource.sendState(
                            state: ExtWorkspaceHandleV1State(
                                rawValue: active ? Self.stateActive : 0))
                    }) != nil
            else { return false }
            return true
        }

        guard let handle = workspace(spaceID) else { return false }
        var emitted = false
        if handle.name != space.name {
            handle.name = space.name
            handle.resource.sendName(name: space.name)
            emitted = true
        }
        if handle.active != active {
            handle.active = active
            handle.resource.sendState(
                state: ExtWorkspaceHandleV1State(
                    rawValue: active ? Self.stateActive : 0))
            emitted = true
        }
        return emitted
    }

    /// Get-or-create the wire group for an output, retrying the (possibly deferred)
    /// output_enter each call.
    private func ensureGroup(forOutput outputID: DisplayID) -> ExtWorkspaceGroup? {
        guard resource.isLive else { return nil }
        if group(outputID) == nil {
            guard
                resource.createWorkspaceGroup(
                    owner: { handle in
                        ExtWorkspaceGroup(
                            resource: handle,
                            client: self,
                            outputID: outputID)
                    },
                    installed: { groupObj in
                        self.groups.insert(groupObj, forKey: outputID)
                        groupObj.resource.sendCapabilities(
                            capabilities: ExtWorkspaceGroupHandleV1GroupCapabilities(
                                rawValue: Self.groupCaps))
                    }) != nil
            else { return nil }
        }
        guard let group = group(outputID) else { return nil }
        if !group.outputAdvertised,
            let output = manager.outputResource(
                forClient: resource.clientID,
                displayID: outputID)
        {
            group.resource.sendOutputEnter(output: output)
            group.outputAdvertised = true
        }
        return group
    }

    private func dropWorkspace(_ spaceID: SpaceID) -> Bool {
        guard let handle = workspace(spaceID) else { return false }
        if let group = group(handle.outputID) {
            group.resource.sendWorkspaceLeave(workspace: handle.resource)
        }
        handle.resource.sendRemoved()
        let outputID = handle.outputID
        workspaces.removeValue(forKey: spaceID)
        // An output keeps ≥1 workspace unless the output itself is gone, so a now-empty
        // group means the output was removed.
        if !workspaces.liveValues().contains(where: { $0.outputID == outputID }) {
            if let group = group(outputID) {
                group.resource.sendRemoved()
                groups.removeValue(forKey: outputID)
            }
        }
        return true
    }

    private func refreshActive(forOutput outputID: DisplayID) -> Bool {
        let activeID = spaces.activeSpace(forDisplay: outputID)
        var emitted = false
        for (spaceID, handle) in workspaces.liveEntries()
        where handle.outputID == outputID {
            let active = (spaceID == activeID)
            guard handle.active != active else { continue }
            handle.active = active
            handle.resource.sendState(
                state: ExtWorkspaceHandleV1State(
                    rawValue: active ? Self.stateActive : 0))
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
            case .activate(let space, let output):
                if spaces.setActiveSpace(space, forDisplay: output) {
                    RenderBridge.requestFrame(server: manager.server, outputId: output)
                }
            case .createWorkspace(let output):
                if spaces.appendWorkspace(onOutput: output) != 0 {
                    RenderBridge.requestFrame(server: manager.server, outputId: output)
                }
            case .remove(let space):
                let output =
                    spaces.spaces.first {
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
        resource.sendFinished()
    }

}

extension ExtWorkspaceClient: ExtWorkspaceManagerV1Requests {
    func commit(_ request: WaylandRequest<ExtWorkspaceManagerV1Server>) {
        commitRequests()
    }
    func stop(_ request: WaylandRequest<ExtWorkspaceManagerV1Server>) {
        stopProjection()
    }
}

/// ext_workspace_group_handle_v1 owner (Rule 9): one output's wire group.
@MainActor
@safe final class ExtWorkspaceGroup {
    private unowned let client: ExtWorkspaceClient
    let outputID: DisplayID
    fileprivate let resource: WaylandResourceHandle<ExtWorkspaceGroupHandleV1Server>
    var outputAdvertised = false

    init(
        resource: WaylandResourceHandle<ExtWorkspaceGroupHandleV1Server>,
        client: ExtWorkspaceClient,
        outputID: DisplayID
    ) {
        self.resource = resource
        self.client = client
        self.outputID = outputID
    }
}

extension ExtWorkspaceGroup: ExtWorkspaceGroupHandleV1Requests {
    func createWorkspace(
        _ request: WaylandRequest<ExtWorkspaceGroupHandleV1Server>,
        workspace: String
    ) {
        // The requested name is advisory; the model numbers workspaces. Buffered.
        client.enqueueCreateWorkspace(output: outputID)
    }
}

/// ext_workspace_handle_v1 owner (Rule 9): one Space's wire workspace.
@MainActor
@safe final class ExtWorkspaceHandle {
    private unowned let client: ExtWorkspaceClient
    let spaceID: SpaceID
    let outputID: DisplayID
    fileprivate let resource: WaylandResourceHandle<ExtWorkspaceHandleV1Server>
    var name: String = ""
    var active: Bool = false

    init(
        resource: WaylandResourceHandle<ExtWorkspaceHandleV1Server>,
        client: ExtWorkspaceClient,
        spaceID: SpaceID,
        outputID: DisplayID
    ) {
        self.resource = resource
        self.client = client
        self.spaceID = spaceID
        self.outputID = outputID
    }

    fileprivate func act(_ body: (ExtWorkspaceClient, ExtWorkspaceHandle) -> Void) {
        body(client, self)
    }
}

extension ExtWorkspaceHandle: ExtWorkspaceHandleV1Requests {
    func activate(_ request: WaylandRequest<ExtWorkspaceHandleV1Server>) {
        act { $0.enqueueActivate(space: $1.spaceID, output: $1.outputID) }
    }
    // deactivate: not advertised (the active workspace is implicitly replaced, never
    // cleared); assign: not advertised (workspaces are output-bound). Both no-op.
    func deactivate(_ request: WaylandRequest<ExtWorkspaceHandleV1Server>) {}
    func assign(
        _ request: WaylandRequest<ExtWorkspaceHandleV1Server>,
        workspace_group: WaylandBorrowedObject<ExtWorkspaceGroupHandleV1Server>
    ) {}
    func remove(_ request: WaylandRequest<ExtWorkspaceHandleV1Server>) {
        act { client, me in client.enqueueRemove(space: me.spaceID) }
    }
}
