// zwlr_output_management_unstable_v1 — the protocol display tools speak.
//
// This is what wlr-randr, kanshi, and any settings panel talk to. Without it
// there is no way to arrange monitors from outside the compositor's own
// configuration file.
//
// Two honesty constraints shape the implementation.
//
// Each head advertises exactly one mode: the one it is currently running.
// Nucleus takes its mode from the renderer's own enumeration and cannot switch
// it, so listing modes it could not select would fill a display panel with
// entries that fail when chosen. One true mode beats a menu of lies.
//
// A configuration is atomic — the protocol says so, and `succeeded`/`failed`
// exist precisely to say which happened. Scale, position, and adaptive sync are
// applied through the topology reconciler; anything else (a different mode, a custom mode, a
// rotation, disabling an output) fails the *whole* configuration
// rather than being partially honored. Rejecting inside the protocol contract
// is not a shortfall; silently applying half of an atomic request would be.

import WaylandServer
import WaylandServerDispatch
import WaylandProtocolTypes

/// One head's requested state, after validation.
package struct OutputConfigurationRequest: Equatable, Sendable {
    package var outputID: UInt64
    package var scale: Double?
    package var positionX: Int32?
    package var positionY: Int32?
    package var adaptiveSync: Bool?
}

/// Where an applied configuration goes.
@MainActor
package protocol OutputManagementDelegate: AnyObject {
    /// Apply atomically. Returning false fails the whole configuration.
    ///
    /// The compositor applies this to live state only; persistence belongs to
    /// the client, which is why kanshi re-applies on hotplug. A configuration
    /// file reload therefore overwrites what a tool applied, matching how
    /// every other compositor behaves.
    func applyOutputConfiguration(
        _ requests: [OutputConfigurationRequest]
    ) -> Bool
}

/// Why a requested change cannot be honored. Carried so the reason can be
/// logged; the client only ever sees `failed`, as the protocol specifies.
package enum OutputConfigurationRejection: Equatable, Sendable {
    case modeChangeUnsupported
    case customModeUnsupported
    case transformUnsupported
    case disableUnsupported
    case unknownHead

    package var reason: String {
        switch self {
        case .modeChangeUnsupported:
            "mode selection is not supported"
        case .customModeUnsupported:
            "custom modes are not supported"
        case .transformUnsupported:
            "output transforms are not supported"
        case .disableUnsupported:
            "disabling an output is not supported"
        case .unknownHead:
            "head is no longer attached"
        }
    }
}

@MainActor
@safe final class OutputManagement {
    package weak var delegate: (any OutputManagementDelegate)?
    private unowned let compositor: WlCompositor
    private var managers = WeakObjectList<OutputManagementClient>()
    /// Bumped whenever advertised head state changes. A configuration built
    /// against an older serial is `cancelled` rather than applied, because the
    /// client was reasoning about a layout that no longer exists.
    private(set) var serial: UInt32 = 0

    init(compositor: WlCompositor) {
        self.compositor = compositor
    }

    /// Current advertised state, one entry per live output.
    func heads() -> [OutputInfo] {
        compositor.outputs.map(\.info)
    }

    func register(_ client: OutputManagementClient) {
        managers.append(client)
        client.publish(heads: heads(), serial: serial)
    }

    /// Re-advertise every head. Called whenever output topology or geometry
    /// changes, which is also what invalidates outstanding configurations.
    func outputsChanged() {
        serial &+= 1
        let snapshot = heads()
        for client in managers.liveValues() {
            client.republish(heads: snapshot, serial: serial)
        }
    }

    func apply(
        _ requests: [OutputConfigurationRequest]
    ) -> Bool {
        delegate?.applyOutputConfiguration(requests) ?? false
    }
}

/// One bound zwlr_output_manager_v1: the heads it published, and the serial
/// they were published at.
@MainActor
@safe final class OutputManagementClient: ZwlrOutputManagerV1Requests {
    private let resource: WaylandResourceHandle<ZwlrOutputManagerV1Server>
    private unowned let manager: OutputManagement
    /// Published heads keyed by output, so a configuration can resolve a head
    /// object back to the output it stands for.
    private(set) var heads: [ObjectIdentifier: UInt64] = [:]
    private var headOwners: [OutputHead] = []
    private(set) var publishedSerial: UInt32 = 0
    private var stopped = false

    init(
        resource: WaylandResourceHandle<ZwlrOutputManagerV1Server>,
        manager: OutputManagement
    ) {
        self.resource = resource
        self.manager = manager
    }

    func publish(heads infos: [OutputInfo], serial: UInt32) {
        guard !stopped else { return }
        for info in infos {
            guard let head = resource.createHead(owner: { handle in
                OutputHead(resource: handle, outputID: info.outputId)
            }) else { continue }
            head.send(info)
            heads[ObjectIdentifier(head)] = info.outputId
            headOwners.append(head)
        }
        publishedSerial = serial
        _ = resource.sendDone(serial: serial)
    }

    /// Retire the previous head set and publish a fresh one.
    ///
    /// The protocol has no way to mutate a head in place beyond re-sending its
    /// state, and a head whose output is gone must be finished so the client
    /// stops reasoning about it.
    func republish(heads infos: [OutputInfo], serial: UInt32) {
        guard !stopped else { return }
        for head in headOwners { head.finish() }
        headOwners.removeAll()
        heads.removeAll()
        publish(heads: infos, serial: serial)
    }

    func outputID(forHead head: OutputHead) -> UInt64? {
        heads[ObjectIdentifier(head)]
    }

    func createConfiguration(
        _ request: WaylandRequest<ZwlrOutputManagerV1Server>,
        id: WlNewId<ZwlrOutputConfigurationV1Server>,
        serial: UInt32
    ) {
        _ = id.create(owner: { handle in
            OutputConfiguration(
                resource: handle,
                manager: manager,
                client: self,
                // A stale serial does not error: the client raced a topology
                // change, which is ordinary, so the configuration is created
                // and immediately cancelled.
                isStale: serial != self.publishedSerial)
        })
    }

    func stop(_ request: WaylandRequest<ZwlrOutputManagerV1Server>) {
        stopped = true
        _ = resource.sendFinished()
    }
}

/// One published head.
@MainActor
@safe final class OutputHead: ZwlrOutputHeadV1Requests {
    private let resource: WaylandResourceHandle<ZwlrOutputHeadV1Server>
    let outputID: UInt64
    private var mode: OutputMode?

    init(
        resource: WaylandResourceHandle<ZwlrOutputHeadV1Server>,
        outputID: UInt64
    ) {
        self.resource = resource
        self.outputID = outputID
    }

    func send(_ info: OutputInfo) {
        _ = resource.sendName(name: info.name)
        _ = resource.sendDescription(description: info.description)
        _ = resource.sendMake(make: info.make)
        _ = resource.sendModel(model: info.model)
        if info.physicalWidthMm > 0 || info.physicalHeightMm > 0 {
            _ = resource.sendPhysicalSize(
                width: info.physicalWidthMm, height: info.physicalHeightMm)
        }
        // Exactly one mode: the one actually running. See the file comment.
        if let mode = resource.createMode(owner: { handle in
            OutputMode(resource: handle)
        }) {
            mode.send(
                width: info.pixelWidth,
                height: info.pixelHeight,
                refreshMillihertz: info.refreshMhz)
            self.mode = mode
            _ = resource.sendCurrentMode(mode: mode.handle)
        }
        _ = resource.sendEnabled(enabled: 1)
        _ = resource.sendPosition(x: info.x, y: info.y)
        _ = resource.sendTransform(transform: .normal)
        _ = resource.sendScale(
            scale: info.fractionalScale > 0
                ? info.fractionalScale : Double(info.scale))
        // Reported so a display tool shows the state it can actually change,
        // rather than a value the compositor never confirms.
        _ = resource.sendAdaptiveSync(
            state: info.adaptiveSyncEnabled ? .enabled : .disabled)
    }

    /// Is `candidate` the mode this head is currently running?
    func isCurrentMode(_ candidate: OutputMode) -> Bool {
        mode === candidate
    }

    func finish() {
        mode?.finish()
        mode = nil
        _ = resource.sendFinished()
    }
}

@MainActor
@safe final class OutputMode: ZwlrOutputModeV1Requests {
    let handle: WaylandResourceHandle<ZwlrOutputModeV1Server>

    init(resource: WaylandResourceHandle<ZwlrOutputModeV1Server>) {
        self.handle = resource
    }

    func send(width: Int32, height: Int32, refreshMillihertz: Int32) {
        _ = handle.sendSize(width: width, height: height)
        _ = handle.sendRefresh(refresh: refreshMillihertz)
        // The only mode offered is by definition the preferred one.
        _ = handle.sendPreferred()
    }

    func finish() {
        _ = handle.sendFinished()
    }
}

/// One in-flight configuration.
@MainActor
@safe final class OutputConfiguration: ZwlrOutputConfigurationV1Requests {
    private let resource: WaylandResourceHandle<ZwlrOutputConfigurationV1Server>
    private unowned let manager: OutputManagement
    private unowned let client: OutputManagementClient
    private let isStale: Bool
    private var configured: [UInt64: OutputConfigurationHead] = [:]
    private var rejections: [OutputConfigurationRejection] = []
    private var used = false

    init(
        resource: WaylandResourceHandle<ZwlrOutputConfigurationV1Server>,
        manager: OutputManagement,
        client: OutputManagementClient,
        isStale: Bool
    ) {
        self.resource = resource
        self.manager = manager
        self.client = client
        self.isStale = isStale
    }

    func enableHead(
        _ request: WaylandRequest<ZwlrOutputConfigurationV1Server>,
        id: WlNewId<ZwlrOutputConfigurationHeadV1Server>,
        head: WaylandBorrowedObject<ZwlrOutputHeadV1Server>
    ) {
        guard guardUnused(request) else { return }
        guard let head = head.owner(as: OutputHead.self),
            let outputID = client.outputID(forHead: head)
        else {
            rejections.append(.unknownHead)
            _ = id.create(owner: { handle in
                OutputConfigurationHead(
                    resource: handle, configuration: self, head: nil)
            })
            return
        }
        guard configured[outputID] == nil else {
            request.postError(
                .alreadyConfiguredHead,
                message: "head configured twice in one configuration")
            return
        }
        let entry = id.create(owner: { handle in
            OutputConfigurationHead(
                resource: handle, configuration: self, head: head)
        })
        if let entry { configured[outputID] = entry }
    }

    func disableHead(
        _ request: WaylandRequest<ZwlrOutputConfigurationV1Server>,
        head: WaylandBorrowedObject<ZwlrOutputHeadV1Server>
    ) {
        guard guardUnused(request) else { return }
        // Nucleus cannot bring an output down and back up through the topology
        // reconciler yet, so this fails the configuration rather than silently
        // leaving the output on.
        rejections.append(.disableUnsupported)
    }

    fileprivate func reject(_ rejection: OutputConfigurationRejection) {
        rejections.append(rejection)
    }

    func apply(_ request: WaylandRequest<ZwlrOutputConfigurationV1Server>) {
        guard guardUnused(request) else { return }
        used = true
        guard !isStale else {
            _ = resource.sendCancelled()
            return
        }
        guard rejections.isEmpty else {
            _ = resource.sendFailed()
            return
        }
        // Every head the client did not mention keeps its current state, which
        // is what "enable_head" without "disable_head" means.
        let requests = configured.map { outputID, entry in
            OutputConfigurationRequest(
                outputID: outputID,
                scale: entry.scale,
                positionX: entry.positionX,
                positionY: entry.positionY,
                adaptiveSync: entry.adaptiveSync)
        }
        if manager.apply(requests) {
            _ = resource.sendSucceeded()
        } else {
            _ = resource.sendFailed()
        }
    }

    func test(_ request: WaylandRequest<ZwlrOutputConfigurationV1Server>) {
        guard guardUnused(request) else { return }
        used = true
        guard !isStale else {
            _ = resource.sendCancelled()
            return
        }
        // A test answers whether apply *would* work without touching hardware,
        // so it reports the same validation apply performs and stops there.
        if rejections.isEmpty {
            _ = resource.sendSucceeded()
        } else {
            _ = resource.sendFailed()
        }
    }

    private func guardUnused(
        _ request: WaylandRequest<ZwlrOutputConfigurationV1Server>
    ) -> Bool {
        guard !used else {
            request.postError(
                .alreadyUsed,
                message: "configuration already applied or tested")
            return false
        }
        return true
    }
}

/// One head's requested settings inside a configuration.
@MainActor
@safe final class OutputConfigurationHead:
    ZwlrOutputConfigurationHeadV1Requests
{
    private unowned let configuration: OutputConfiguration
    private let head: OutputHead?
    private(set) var scale: Double?
    private(set) var positionX: Int32?
    private(set) var positionY: Int32?
    private(set) var adaptiveSync: Bool?
    private var setMode = false
    private var setTransform = false
    private var setAdaptiveSync = false

    init(
        resource: WaylandResourceHandle<ZwlrOutputConfigurationHeadV1Server>,
        configuration: OutputConfiguration,
        head: OutputHead?
    ) {
        self.configuration = configuration
        self.head = head
    }

    func setMode(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        mode: WaylandBorrowedObject<ZwlrOutputModeV1Server>
    ) {
        guard once(request, &setMode) else { return }
        // Selecting the mode already running is a no-op and succeeds; anything
        // else would need renderer-side mode setting.
        guard let mode = mode.owner(as: OutputMode.self),
            let head, head.isCurrentMode(mode)
        else {
            configuration.reject(.modeChangeUnsupported)
            return
        }
    }

    func setCustomMode(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        width: Int32, height: Int32, refresh: Int32
    ) {
        guard once(request, &setMode) else { return }
        configuration.reject(.customModeUnsupported)
    }

    func setPosition(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        x: Int32, y: Int32
    ) {
        guard positionX == nil else {
            request.postError(.alreadySet, message: "position already set")
            return
        }
        positionX = x
        positionY = y
    }

    func setTransform(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        transform: WlOutputTransform
    ) {
        guard once(request, &setTransform) else { return }
        // Only the identity transform is achievable today; the renderer does
        // not rotate scanout.
        if transform != .normal {
            configuration.reject(.transformUnsupported)
        }
    }

    func setScale(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        scale value: Double
    ) {
        guard scale == nil else {
            request.postError(.alreadySet, message: "scale already set")
            return
        }
        guard value > 0 else {
            request.postError(
                .invalidScale, message: "scale must be greater than zero")
            return
        }
        scale = value
    }

    func setAdaptiveSync(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        state: ZwlrOutputHeadV1AdaptiveSyncState
    ) {
        guard once(request, &setAdaptiveSync) else { return }
        // A capable connector drives VRR by default, so `enabled` is usually a
        // no-op; `disabled` is the request that actually changes something,
        // and the reason this is worth honoring rather than rejecting.
        adaptiveSync = state == .enabled
    }

    /// Each property may be set once per configuration head.
    private func once(
        _ request: WaylandRequest<ZwlrOutputConfigurationHeadV1Server>,
        _ flag: inout Bool
    ) -> Bool {
        guard !flag else {
            request.postError(.alreadySet, message: "property already set")
            return false
        }
        flag = true
        return true
    }
}
