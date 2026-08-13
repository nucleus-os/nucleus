import WaylandProtocolTypes
import WaylandServer
import WaylandServerDispatch

@MainActor
@safe final class TabletManager: ZwpTabletManagerV2Requests {
    unowned let host: RouterHost
    private unowned let seat: WlSeat
    private var bindings = WeakObjectList<TabletSeatBinding>()
    private var tablets: [TabletDeviceID: TabletDeviceDescriptor] = [:]
    private var pads: [TabletDeviceID: TabletPadDescriptor] = [:]
    private var tools: [TabletToolID: (TabletDeviceID, TabletToolDescriptor)] = [:]

    init(host: RouterHost, seat: WlSeat) {
        self.host = host
        self.seat = seat
    }

    var activeBindingCount: Int {
        bindings.count
    }

    func getTabletSeat(
        _ request: WaylandRequest<ZwpTabletManagerV2Server>,
        tablet_seat: WlNewId<ZwpTabletSeatV2Server>,
        seat borrowedSeat: WaylandBorrowedObject<WlSeatServer>
    ) {
        guard borrowedSeat.clientID == tablet_seat.clientID,
            borrowedSeat.owner(as: SeatBinding.self)?.seat === seat
        else { return }
        _ = tablet_seat.create(
            owner: { handle in
                TabletSeatBinding(resource: handle, manager: self)
            },
            installed: { binding in
                self.bindings.append(binding)
                for tablet in self.tablets.values.sorted(by: { $0.id < $1.id }) {
                    binding.addTablet(tablet)
                }
                for (_, tool) in self.tools.values.sorted(by: { $0.1.id < $1.1.id }) {
                    binding.addTool(tool)
                }
                for pad in self.pads.values.sorted(by: { $0.device.id < $1.device.id }) {
                    binding.addPad(pad)
                }
            })
    }

    func addTablet(_ descriptor: TabletDeviceDescriptor) {
        guard tablets.updateValue(descriptor, forKey: descriptor.id) == nil else { return }
        bindings.forEach { $0.addTablet(descriptor) }
    }

    func addPad(_ descriptor: TabletPadDescriptor) {
        guard pads.updateValue(descriptor, forKey: descriptor.device.id) == nil else { return }
        bindings.forEach { $0.addPad(descriptor) }
    }

    func removeDevice(_ deviceID: TabletDeviceID) {
        let removedToolIDs = tools.compactMap { id, entry in
            entry.0 == deviceID ? id : nil
        }.sorted()
        for toolID in removedToolIDs {
            tools.removeValue(forKey: toolID)
            bindings.forEach { $0.removeTool(toolID) }
        }
        if pads.removeValue(forKey: deviceID) != nil {
            bindings.forEach { $0.removePad(deviceID) }
        }
        if tablets.removeValue(forKey: deviceID) != nil {
            bindings.forEach { $0.removeTablet(deviceID) }
        }
    }

    func handle(_ event: NormalizedTabletEvent) {
        handle(event, resolveTarget: target(for:))
    }

    func handle(
        _ event: NormalizedTabletEvent,
        resolveTarget: (TabletAxes) -> Target?
    ) {
        switch event {
        case .proximityIn(let deviceID, let tool, let timestampNs, let axes):
            guard let tablet = tablets[deviceID],
                let target = resolveTarget(axes)
            else { return }
            if tools.updateValue((deviceID, tool), forKey: tool.id) == nil {
                bindings.forEach { $0.addTool(tool) }
            }
            bindings.forEach {
                $0.proximityIn(
                    toolID: tool.id, tabletID: tablet.id,
                    groupID: tablet.groupID, target: target,
                    timestampMs: Self.timestampMs(timestampNs), axes: axes)
            }

        case .axes(let deviceID, let toolID, let timestampNs, let axes):
            guard let tablet = tablets[deviceID] else { return }
            let target = resolveTarget(axes)
            bindings.forEach {
                $0.axes(
                    toolID: toolID, tabletID: tablet.id,
                    groupID: tablet.groupID, target: target,
                    timestampMs: Self.timestampMs(timestampNs), axes: axes)
            }

        case .tip(_, let toolID, let timestampNs, let down, let axes):
            bindings.forEach {
                $0.tip(
                    toolID: toolID, timestampMs: Self.timestampMs(timestampNs),
                    down: down, axes: axes)
            }

        case .toolButton(_, let toolID, let timestampNs, let button, let down, let axes):
            bindings.forEach {
                $0.toolButton(
                    toolID: toolID, timestampMs: Self.timestampMs(timestampNs),
                    button: button, down: down, axes: axes)
            }

        case .proximityOut(_, let toolID, let timestampNs):
            bindings.forEach {
                $0.proximityOut(
                    toolID: toolID, timestampMs: Self.timestampMs(timestampNs))
            }

        case .padButton(
            let deviceID, let timestampNs, let button, let down, let group, let mode):
            bindings.forEach {
                $0.padButton(
                    deviceID: deviceID, timestampMs: Self.timestampMs(timestampNs),
                    button: button, down: down, group: group, mode: mode)
            }
        case .padRing(
            let deviceID, let timestampNs, let ring, let position, let source,
            let group, let mode):
            bindings.forEach {
                $0.padRing(
                    deviceID: deviceID, timestampMs: Self.timestampMs(timestampNs),
                    ring: ring, position: position, source: source,
                    group: group, mode: mode)
            }
        case .padStrip(
            let deviceID, let timestampNs, let strip, let position, let source,
            let group, let mode):
            bindings.forEach {
                $0.padStrip(
                    deviceID: deviceID, timestampMs: Self.timestampMs(timestampNs),
                    strip: strip, position: position, source: source,
                    group: group, mode: mode)
            }
        case .padDial(
            let deviceID, let timestampNs, let dial, let deltaV120, let group, let mode):
            bindings.forEach {
                $0.padDial(
                    deviceID: deviceID, timestampMs: Self.timestampMs(timestampNs),
                    dial: dial, deltaV120: deltaV120, group: group, mode: mode)
            }
        }
    }

    func cancelAll(timestampMs: UInt32 = 0) {
        bindings.forEach { $0.cancelAll(timestampMs: timestampMs) }
    }

    func nextSerial() -> UInt32 {
        seat.nextTabletSerial()
    }

    struct Target {
        let surface: WlSurface
        let localX: Double
        let localY: Double
    }

    private func target(for axes: TabletAxes) -> Target? {
        guard let x = axes.x, let y = axes.y else { return nil }
        let hit = routerHitTest(host: host, sx: x, sy: y)
        guard hit.surfaceId != 0,
            let surface = host.runtime?.compositor.surface(id: UInt32(hit.surfaceId))
        else { return nil }
        return Target(surface: surface, localX: hit.localX, localY: hit.localY)
    }

    private static func timestampMs(_ timestampNs: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: timestampNs / 1_000_000)
    }
}

@MainActor
@safe final class TabletSeatBinding: ZwpTabletSeatV2Requests {
    private let resource: WaylandResourceHandle<ZwpTabletSeatV2Server>
    private weak var manager: TabletManager?
    private var tablets = WeakObjectMap<TabletDeviceID, TabletResource>()
    private var tools = WeakObjectMap<TabletToolID, TabletToolResource>()
    private var pads = WeakObjectMap<TabletDeviceID, TabletPadResource>()
    private var groupByActiveTool: [TabletToolID: UInt64] = [:]
    private var focusedToolByGroup: [UInt64: TabletToolID] = [:]

    init(
        resource: WaylandResourceHandle<ZwpTabletSeatV2Server>,
        manager: TabletManager
    ) {
        self.resource = resource
        self.manager = manager
    }

    func addTablet(_ descriptor: TabletDeviceDescriptor) {
        guard tablets.value(forKey: descriptor.id) == nil else { return }
        _ = resource.createTabletAdded(
            owner: { TabletResource(resource: $0, descriptor: descriptor) },
            installed: {
                self.tablets.insert($0, forKey: descriptor.id)
                $0.publishMetadata()
            })
    }

    func addTool(_ descriptor: TabletToolDescriptor) {
        guard tools.value(forKey: descriptor.id) == nil else { return }
        _ = resource.createToolAdded(
            owner: {
                TabletToolResource(resource: $0, descriptor: descriptor, manager: self.manager)
            },
            installed: {
                self.tools.insert($0, forKey: descriptor.id)
                $0.publishMetadata()
            })
    }

    func addPad(_ descriptor: TabletPadDescriptor) {
        guard pads.value(forKey: descriptor.device.id) == nil else { return }
        _ = resource.createPadAdded(
            owner: {
                TabletPadResource(resource: $0, descriptor: descriptor, manager: self.manager)
            },
            installed: {
                self.pads.insert($0, forKey: descriptor.device.id)
                $0.publishMetadata()
            })
    }

    func removeTablet(_ id: TabletDeviceID) {
        tablets.removeValue(forKey: id)?.removed()
    }

    func removeTool(_ id: TabletToolID) {
        proximityOut(toolID: id, timestampMs: 0)
        tools.removeValue(forKey: id)?.removed()
    }

    func removePad(_ id: TabletDeviceID) {
        pads.removeValue(forKey: id)?.removed()
    }

    func proximityIn(
        toolID: TabletToolID, tabletID: TabletDeviceID, groupID: UInt64,
        target: TabletManager.Target, timestampMs: UInt32, axes: TabletAxes
    ) {
        guard let tablet = tablets.value(forKey: tabletID),
            let tool = tools.value(forKey: toolID)
        else { return }
        tool.proximityIn(
            tablet: tablet, target: target, timestampMs: timestampMs, axes: axes)
        guard tool.isActive else { return }
        focusPads(
            for: toolID, groupID: groupID, tablet: tablet,
            surface: target.surface)
    }

    func axes(
        toolID: TabletToolID, tabletID: TabletDeviceID, groupID: UInt64,
        target: TabletManager.Target?, timestampMs: UInt32, axes: TabletAxes
    ) {
        guard let tablet = tablets.value(forKey: tabletID),
            let tool = tools.value(forKey: toolID)
        else { return }
        let priorSurface = tool.activeSurface
        if let target {
            tool.moveFocus(
                tablet: tablet, target: target, timestampMs: timestampMs, axes: axes)
        } else {
            tool.proximityOut(timestampMs: timestampMs)
        }
        guard priorSurface !== tool.activeSurface else { return }
        if let surface = tool.activeSurface {
            focusPads(
                for: toolID, groupID: groupID, tablet: tablet,
                surface: surface)
        } else {
            clearPadFocus(for: toolID)
        }
    }

    func tip(toolID: TabletToolID, timestampMs: UInt32, down: Bool, axes: TabletAxes) {
        tools.value(forKey: toolID)?.tip(down: down, axes: axes, timestampMs: timestampMs)
    }

    func toolButton(
        toolID: TabletToolID, timestampMs: UInt32, button: UInt32,
        down: Bool, axes: TabletAxes
    ) {
        tools.value(forKey: toolID)?.button(
            button, down: down, axes: axes, timestampMs: timestampMs)
    }

    func proximityOut(toolID: TabletToolID, timestampMs: UInt32) {
        guard let tool = tools.value(forKey: toolID) else { return }
        let oldSurface = tool.activeSurface
        tool.proximityOut(timestampMs: timestampMs)
        guard oldSurface != nil else { return }
        clearPadFocus(for: toolID)
    }

    func padButton(
        deviceID: TabletDeviceID, timestampMs: UInt32, button: UInt32,
        down: Bool, group: UInt32, mode: UInt32
    ) {
        pads.value(forKey: deviceID)?.button(
            button, down: down, group: group, mode: mode, timestampMs: timestampMs)
    }

    func padRing(
        deviceID: TabletDeviceID, timestampMs: UInt32, ring: UInt32,
        position: Double?, source: TabletPadControlSource, group: UInt32, mode: UInt32
    ) {
        pads.value(forKey: deviceID)?.ring(
            ring, position: position, source: source,
            group: group, mode: mode, timestampMs: timestampMs)
    }

    func padStrip(
        deviceID: TabletDeviceID, timestampMs: UInt32, strip: UInt32,
        position: Double?, source: TabletPadControlSource, group: UInt32, mode: UInt32
    ) {
        pads.value(forKey: deviceID)?.strip(
            strip, position: position, source: source,
            group: group, mode: mode, timestampMs: timestampMs)
    }

    func padDial(
        deviceID: TabletDeviceID, timestampMs: UInt32, dial: UInt32,
        deltaV120: Int32, group: UInt32, mode: UInt32
    ) {
        pads.value(forKey: deviceID)?.dial(
            dial, deltaV120: deltaV120, group: group, mode: mode,
            timestampMs: timestampMs)
    }

    func cancelAll(timestampMs: UInt32) {
        tools.liveValues().forEach { $0.proximityOut(timestampMs: timestampMs) }
        pads.liveValues().forEach { $0.leave() }
        groupByActiveTool.removeAll(keepingCapacity: true)
        focusedToolByGroup.removeAll(keepingCapacity: true)
    }

    private func focusPads(
        for toolID: TabletToolID, groupID: UInt64, tablet: TabletResource,
        surface: WlSurface
    ) {
        if let oldGroup = groupByActiveTool.updateValue(groupID, forKey: toolID),
            oldGroup != groupID,
            focusedToolByGroup[oldGroup] == toolID
        {
            focusedToolByGroup.removeValue(forKey: oldGroup)
            leavePads(in: oldGroup)
        }
        focusedToolByGroup[groupID] = toolID
        for pad in pads.liveValues() where pad.descriptor.device.groupID == groupID {
            pad.enter(tablet: tablet, surface: surface)
        }
    }

    private func clearPadFocus(for toolID: TabletToolID) {
        guard let groupID = groupByActiveTool.removeValue(forKey: toolID),
            focusedToolByGroup[groupID] == toolID
        else { return }
        focusedToolByGroup.removeValue(forKey: groupID)
        leavePads(in: groupID)
    }

    private func leavePads(in groupID: UInt64) {
        for pad in pads.liveValues() where pad.descriptor.device.groupID == groupID {
            pad.leave()
        }
    }
}

@MainActor
@safe final class TabletResource: ZwpTabletV2Requests {
    let resource: WaylandResourceHandle<ZwpTabletV2Server>
    let descriptor: TabletDeviceDescriptor

    init(
        resource: WaylandResourceHandle<ZwpTabletV2Server>,
        descriptor: TabletDeviceDescriptor
    ) {
        self.resource = resource
        self.descriptor = descriptor
    }

    func publishMetadata() {
        _ = resource.sendName(name: descriptor.name)
        _ = resource.sendId(vid: descriptor.vendorID, pid: descriptor.productID)
        _ = resource.sendPath(path: descriptor.path)
        _ = resource.sendDone()
    }

    func removed() {
        _ = resource.sendRemoved()
    }

}

@MainActor
@safe final class TabletToolResource: ZwpTabletToolV2Requests, CursorShapeAuthorizationSource {
    let resource: WaylandResourceHandle<ZwpTabletToolV2Server>
    let descriptor: TabletToolDescriptor
    private weak var manager: TabletManager?
    private(set) weak var activeSurface: WlSurface?
    private var enterSerial: UInt32 = 0
    private var down = false

    init(
        resource: WaylandResourceHandle<ZwpTabletToolV2Server>,
        descriptor: TabletToolDescriptor,
        manager: TabletManager?
    ) {
        self.resource = resource
        self.descriptor = descriptor
        self.manager = manager
    }

    var isActive: Bool { activeSurface != nil }

    func publishMetadata() {
        _ = resource.sendType(tool_type: descriptor.kind.protocolType)
        _ = resource.sendHardwareSerial(
            hardware_serial_hi: UInt32(truncatingIfNeeded: descriptor.serial >> 32),
            hardware_serial_lo: UInt32(truncatingIfNeeded: descriptor.serial))
        _ = resource.sendHardwareIdWacom(
            hardware_id_hi: UInt32(truncatingIfNeeded: descriptor.hardwareID >> 32),
            hardware_id_lo: UInt32(truncatingIfNeeded: descriptor.hardwareID))
        for (capability, protocolCapability) in TabletToolCapabilities.protocolCapabilities
        where descriptor.capabilities.contains(capability) {
            _ = resource.sendCapability(capability: protocolCapability)
        }
        _ = resource.sendDone()
    }

    func proximityIn(
        tablet: TabletResource, target: TabletManager.Target,
        timestampMs: UInt32, axes: TabletAxes
    ) {
        guard resource.clientID == target.surface.protocolResource?.clientID,
            let surface = target.surface.protocolResource,
            let manager
        else { return }
        proximityOut(timestampMs: timestampMs)
        let serial = manager.nextSerial()
        guard
            resource.sendProximityIn(
                serial: serial, tablet: tablet.resource, surface: surface)
        else { return }
        activeSurface = target.surface
        enterSerial = serial
        var localAxes = axes
        localAxes.x = target.localX
        localAxes.y = target.localY
        sendAxes(localAxes)
        _ = resource.sendFrame(time: timestampMs)
    }

    func moveFocus(
        tablet: TabletResource, target: TabletManager.Target,
        timestampMs: UInt32, axes: TabletAxes
    ) {
        guard activeSurface !== target.surface else {
            var localAxes = axes
            localAxes.x = target.localX
            localAxes.y = target.localY
            self.axes(localAxes, timestampMs: timestampMs)
            return
        }
        proximityOut(timestampMs: timestampMs)
        proximityIn(tablet: tablet, target: target, timestampMs: timestampMs, axes: axes)
    }

    func axes(_ axes: TabletAxes, timestampMs: UInt32) {
        guard isActive else { return }
        sendAxes(axes)
        _ = resource.sendFrame(time: timestampMs)
    }

    func tip(down: Bool, axes: TabletAxes, timestampMs: UInt32) {
        guard isActive, self.down != down else { return }
        sendAxes(axes)
        self.down = down
        if down, let manager {
            _ = resource.sendDown(serial: manager.nextSerial())
        } else {
            _ = resource.sendUp()
        }
        _ = resource.sendFrame(time: timestampMs)
    }

    func button(
        _ button: UInt32, down: Bool, axes: TabletAxes, timestampMs: UInt32
    ) {
        guard isActive, let manager else { return }
        sendAxes(axes)
        _ = resource.sendButton(
            serial: manager.nextSerial(), button: button,
            state: down ? .pressed : .released)
        _ = resource.sendFrame(time: timestampMs)
    }

    func proximityOut(timestampMs: UInt32) {
        guard activeSurface != nil else { return }
        if down {
            down = false
            _ = resource.sendUp()
        }
        _ = resource.sendProximityOut()
        _ = resource.sendFrame(time: timestampMs)
        activeSurface = nil
        enterSerial = 0
    }

    func removed() {
        proximityOut(timestampMs: 0)
        _ = resource.sendRemoved()
    }

    func authorizesCursor(serial: UInt32) -> Bool {
        serial == enterSerial
            && resource.clientID == activeSurface?.protocolResource?.clientID
    }

    func setCursor(
        _ request: WaylandRequest<ZwpTabletToolV2Server>, serial: UInt32,
        surface: WaylandBorrowedObject<WlSurfaceServer>?, hotspot_x: Int32, hotspot_y: Int32
    ) {
        guard authorizesCursor(serial: serial),
            let manager
        else { return }
        guard let surfaceObject = surface?.owner(as: WlSurface.self) else {
            RenderBridge.requestCursorFrame(server: manager.host.server)
            manager.host.pointerCursorSurface.clear()
            manager.host.server.cursor.hide()
            return
        }
        guard surface?.clientID == resource.clientID else { return }
        guard surfaceObject.claimCursorRole() else {
            request.postError(.role, message: "cursor surface already has an incompatible role")
            return
        }
        manager.host.pointerCursorSurface.bind(
            surfaceId: surfaceObject.objectId, hotspotX: hotspot_x, hotspotY: hotspot_y)
        manager.host.pointerCursorSurface.applyCommittedImage(surfaceObject)
        RenderBridge.requestCursorFrame(server: manager.host.server)
    }

    private func sendAxes(_ axes: TabletAxes) {
        if let x = axes.x, let y = axes.y { _ = resource.sendMotion(x: x, y: y) }
        if let pressure = axes.pressure {
            _ = resource.sendPressure(pressure: Self.unsignedAxis(pressure))
        }
        if let distance = axes.distance {
            _ = resource.sendDistance(distance: Self.unsignedAxis(distance))
        }
        if let tiltX = axes.tiltX, let tiltY = axes.tiltY {
            _ = resource.sendTilt(tilt_x: tiltX, tilt_y: tiltY)
        }
        if let rotation = axes.rotationDegrees { _ = resource.sendRotation(degrees: rotation) }
        if let slider = axes.slider {
            _ = resource.sendSlider(
                position: Int32((slider.clamped(to: -1...1) * 65_535).rounded()))
        }
        if let degrees = axes.wheelDegrees, let clicks = axes.wheelClicks {
            _ = resource.sendWheel(degrees: degrees, clicks: clicks)
        }
    }

    private static func unsignedAxis(_ value: Double) -> UInt32 {
        UInt32((value.clamped(to: 0...1) * 65_535).rounded())
    }
}

@MainActor
@safe final class TabletPadResource: ZwpTabletPadV2Requests {
    let resource: WaylandResourceHandle<ZwpTabletPadV2Server>
    let descriptor: TabletPadDescriptor
    private weak var manager: TabletManager?
    private var groups: [UInt32: TabletPadGroupResource] = [:]
    private weak var activeSurface: WlSurface?

    init(
        resource: WaylandResourceHandle<ZwpTabletPadV2Server>,
        descriptor: TabletPadDescriptor,
        manager: TabletManager?
    ) {
        self.resource = resource
        self.descriptor = descriptor
        self.manager = manager
    }

    func publishMetadata() {
        _ = resource.sendPath(path: descriptor.device.path)
        _ = resource.sendButtons(buttons: descriptor.buttonCount)
        for groupDescriptor in descriptor.groups {
            _ = resource.createGroup(
                owner: {
                    TabletPadGroupResource(resource: $0, descriptor: groupDescriptor)
                },
                installed: {
                    self.groups[groupDescriptor.index] = $0
                    $0.publishMetadata()
                })
        }
        _ = resource.sendDone()
    }

    func enter(tablet: TabletResource, surface: WlSurface) {
        guard activeSurface !== surface,
            resource.clientID == surface.protocolResource?.clientID,
            let surfaceResource = surface.protocolResource,
            let manager
        else { return }
        leave()
        guard
            resource.sendEnter(
                serial: manager.nextSerial(), tablet: tablet.resource, surface: surfaceResource)
        else { return }
        activeSurface = surface
    }

    func leave() {
        guard let activeSurface, let surface = activeSurface.protocolResource,
            let manager
        else { return }
        _ = resource.sendLeave(serial: manager.nextSerial(), surface: surface)
        self.activeSurface = nil
    }

    func button(
        _ button: UInt32, down: Bool, group: UInt32, mode: UInt32,
        timestampMs: UInt32
    ) {
        guard activeSurface != nil else { return }
        groups[group]?.modeChanged(mode, timestampMs: timestampMs, manager: manager)
        _ = resource.sendButton(
            time: timestampMs, button: button,
            state: down ? .pressed : .released)
    }

    func ring(
        _ ring: UInt32, position: Double?, source: TabletPadControlSource,
        group: UInt32, mode: UInt32, timestampMs: UInt32
    ) {
        guard activeSurface != nil else { return }
        groups[group]?.modeChanged(mode, timestampMs: timestampMs, manager: manager)
        groups[group]?.ring(ring, position: position, source: source, timestampMs: timestampMs)
    }

    func strip(
        _ strip: UInt32, position: Double?, source: TabletPadControlSource,
        group: UInt32, mode: UInt32, timestampMs: UInt32
    ) {
        guard activeSurface != nil else { return }
        groups[group]?.modeChanged(mode, timestampMs: timestampMs, manager: manager)
        groups[group]?.strip(strip, position: position, source: source, timestampMs: timestampMs)
    }

    func dial(
        _ dial: UInt32, deltaV120: Int32, group: UInt32, mode: UInt32,
        timestampMs: UInt32
    ) {
        guard activeSurface != nil else { return }
        groups[group]?.modeChanged(mode, timestampMs: timestampMs, manager: manager)
        groups[group]?.dial(dial, deltaV120: deltaV120, timestampMs: timestampMs)
    }

    func removed() {
        leave()
        _ = resource.sendRemoved()
    }

    func setFeedback(
        _ request: WaylandRequest<ZwpTabletPadV2Server>, button: UInt32,
        description: String, serial: UInt32
    ) {}
}

@MainActor
@safe final class TabletPadGroupResource: ZwpTabletPadGroupV2Requests {
    private let resource: WaylandResourceHandle<ZwpTabletPadGroupV2Server>
    private let descriptor: TabletPadGroupDescriptor
    private var rings: [UInt32: TabletPadRingResource] = [:]
    private var strips: [UInt32: TabletPadStripResource] = [:]
    private var dials: [UInt32: TabletPadDialResource] = [:]
    private var mode: UInt32 = 0

    init(
        resource: WaylandResourceHandle<ZwpTabletPadGroupV2Server>,
        descriptor: TabletPadGroupDescriptor
    ) {
        self.resource = resource
        self.descriptor = descriptor
    }

    func publishMetadata() {
        _ = resource.sendButtons(buttons: descriptor.buttons)
        for index in descriptor.rings {
            _ = resource.createRing(
                owner: { TabletPadRingResource(resource: $0) },
                installed: { self.rings[index] = $0 })
        }
        for index in descriptor.strips {
            _ = resource.createStrip(
                owner: { TabletPadStripResource(resource: $0) },
                installed: { self.strips[index] = $0 })
        }
        if resource.supportsDial {
            for index in descriptor.dials {
                _ = resource.createDial(
                    owner: { TabletPadDialResource(resource: $0) },
                    installed: { self.dials[index] = $0 })
            }
        }
        _ = resource.sendModes(modes: descriptor.modeCount)
        _ = resource.sendDone()
    }

    func modeChanged(_ mode: UInt32, timestampMs: UInt32, manager: TabletManager?) {
        guard mode != self.mode, let manager else { return }
        self.mode = mode
        _ = resource.sendModeSwitch(
            time: timestampMs, serial: manager.nextSerial(), mode: mode)
    }

    func ring(
        _ index: UInt32, position: Double?, source: TabletPadControlSource,
        timestampMs: UInt32
    ) {
        rings[index]?.send(position: position, source: source, timestampMs: timestampMs)
    }

    func strip(
        _ index: UInt32, position: Double?, source: TabletPadControlSource,
        timestampMs: UInt32
    ) {
        strips[index]?.send(position: position, source: source, timestampMs: timestampMs)
    }

    func dial(_ index: UInt32, deltaV120: Int32, timestampMs: UInt32) {
        dials[index]?.send(deltaV120: deltaV120, timestampMs: timestampMs)
    }
}

@MainActor
@safe final class TabletPadRingResource: ZwpTabletPadRingV2Requests {
    private let resource: WaylandResourceHandle<ZwpTabletPadRingV2Server>
    init(resource: WaylandResourceHandle<ZwpTabletPadRingV2Server>) { self.resource = resource }

    func send(position: Double?, source: TabletPadControlSource, timestampMs: UInt32) {
        if source == .finger { _ = resource.sendSource(source: .finger) }
        if let position {
            _ = resource.sendAngle(degrees: position)
        } else {
            _ = resource.sendStop()
        }
        _ = resource.sendFrame(time: timestampMs)
    }

    func setFeedback(
        _ request: WaylandRequest<ZwpTabletPadRingV2Server>, description: String, serial: UInt32
    ) {}
}

@MainActor
@safe final class TabletPadStripResource: ZwpTabletPadStripV2Requests {
    private let resource: WaylandResourceHandle<ZwpTabletPadStripV2Server>
    init(resource: WaylandResourceHandle<ZwpTabletPadStripV2Server>) { self.resource = resource }

    func send(position: Double?, source: TabletPadControlSource, timestampMs: UInt32) {
        if source == .finger { _ = resource.sendSource(source: .finger) }
        if let position {
            let value = UInt32((position.clamped(to: 0...1) * 65_535).rounded())
            _ = resource.sendPosition(position: value)
        } else {
            _ = resource.sendStop()
        }
        _ = resource.sendFrame(time: timestampMs)
    }

    func setFeedback(
        _ request: WaylandRequest<ZwpTabletPadStripV2Server>, description: String, serial: UInt32
    ) {}
}

@MainActor
@safe final class TabletPadDialResource: ZwpTabletPadDialV2Requests {
    private let resource: WaylandResourceHandle<ZwpTabletPadDialV2Server>
    init(resource: WaylandResourceHandle<ZwpTabletPadDialV2Server>) { self.resource = resource }

    func send(deltaV120: Int32, timestampMs: UInt32) {
        _ = resource.sendDelta(value120: deltaV120)
        _ = resource.sendFrame(time: timestampMs)
    }

    func setFeedback(
        _ request: WaylandRequest<ZwpTabletPadDialV2Server>, description: String, serial: UInt32
    ) {}
}

extension TabletToolKind {
    fileprivate var protocolType: ZwpTabletToolV2Type {
        switch self {
        case .pen: .pen
        case .eraser: .eraser
        case .brush: .brush
        case .pencil: .pencil
        case .airbrush: .airbrush
        case .finger: .finger
        case .mouse: .mouse
        case .lens: .lens
        }
    }
}

extension TabletToolCapabilities {
    fileprivate static let protocolCapabilities: [(Self, ZwpTabletToolV2Capability)] = [
        (.pressure, .pressure),
        (.distance, .distance),
        (.tilt, .tilt),
        (.rotation, .rotation),
        (.slider, .slider),
        (.wheel, .wheel),
    ]
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
